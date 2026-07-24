// AudioPlayer.swift
// AVAudioEngine playback for host-streamed Float32 interleaved PCM.

import AVFoundation
import CoreMedia
import OSLog
import Darwin

private let logger = Logger(subsystem: "com.beam.ios", category: "AudioPlayer")

final class AudioPlayer {

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    /// PROCESS-WIDE, not per instance. Every auto-reconnect builds a fresh ConnectionManager and
    /// therefore a fresh AudioPlayer while the outgoing one is still alive. With per-instance
    /// queues the outgoing player's `stop()` (which deactivates the shared AVAudioSession) and
    /// the incoming player's `start()` (which activates it and starts an engine) ran on
    /// independent queues with no ordering — so a late teardown could deactivate the session
    /// under a freshly started engine. One serial queue makes that strictly impossible, and
    /// costs nothing because only one player is ever streaming.
    private static let renderQueue = DispatchQueue(label: "com.beam.ios.audioplayer", qos: .userInteractive)
    private var renderQueue: DispatchQueue { Self.renderQueue }

    /// Which AudioPlayer currently owns the shared AVAudioSession. Only the owner may
    /// deactivate it, so a stale instance's teardown can never mute the live one.
    private static var sessionOwnerGeneration: UInt64 = 0
    private var myGeneration: UInt64 = 0

    // Remote audio format (updated by host control messages).
    /// Default 48kHz, matching what the host actually sends and what iPhone hardware runs at
    /// natively. It used to be 44100, which was wrong in both directions: the engine and the
    /// audio session were built at 44100 before the host's real format arrived, so the first
    /// moments of every session played 48kHz audio at 44.1kHz (pitch-shifted down, audibly
    /// "bass boosted"), and then the whole chain was torn down and rebuilt a few milliseconds
    /// later once audioFormatChanged landed. Starting at the right rate removes the mismatch
    /// window rather than correcting it after the fact.
    private var playbackSampleRate: Double = 48_000
    private var playbackChannels: AVAudioChannelCount = 2
    private var outputFormat: AVAudioFormat?

    /// Thread-safe snapshot of the format above, so the AAC decoder can be built with a format
    /// that is byte-identical to the engine's without hopping onto renderQueue.
    private let formatLock = NSLock()
    private var snapshotSampleRate: Double = 48_000
    private var snapshotChannels: AVAudioChannelCount = 2
    private var didReceiveRemoteFormat = false

    var currentSampleRate: Double {
        formatLock.lock(); defer { formatLock.unlock() }
        return snapshotSampleRate
    }

    /// True once the host has told us its real audio format. Until then the snapshot holds
    /// a default that may not match the encoder.
    var hasRemoteFormat: Bool {
        formatLock.lock(); defer { formatLock.unlock() }
        return didReceiveRemoteFormat
    }

    var currentChannels: AVAudioChannelCount {
        formatLock.lock(); defer { formatLock.unlock() }
        return snapshotChannels
    }

    // Sync state (renderQueue-only).
    // Video is the master clock; audio is scheduled slightly ahead on that timeline.
    private var syncAnchorRemotePTSUs: Int64?
    private var syncAnchorLocalSeconds: Double?
    private var lastVideoRemotePTSUs: Int64?
    private var lastVideoLocalSeconds: Double?
    private var nextScheduledAudioSeconds: Double?

    private let targetAudioLeadSeconds: Double = 0.10
    private let maxAudioLeadSeconds: Double = 0.45
    private let lateAudioCatchupThresholdSeconds: Double = 0.30
    private let hardAudioResyncThresholdSeconds: Double = 0.85
    /// Above this the timeline is genuinely broken (reconnect, seek, clock jump) rather than
    /// merely offset, and the queued audio really is meaningless. Below it, a large but stable
    /// drift is just the link's audio/video latency difference and must be absorbed, not
    /// corrected by deleting audio.
    private let catastrophicResyncThresholdSeconds: Double = 6.0
    /// Minimum gap between hard resyncs. A stall leaves a backlog of buffers that each
    /// recompute the same large drift before the new anchor has any effect, so without this
    /// they all resync in a burst — the logs showed five in 6ms — and each one dumps the
    /// queue, turning one recoverable glitch into a long audible dropout.
    private let minSecondsBetweenHardResyncs: Double = 0.5
    private var lastHardResyncAt: Double = -.greatestFiniteMagnitude
    /// Wall-clock time of the last buffer actually handed to the player node.
    /// Several paths in enqueue() can decline to schedule (no video clock yet, no usable
    /// sync anchor, unplayable mapping). Any of them persisting means permanent silence
    /// while audio packets keep arriving, which is invisible without this.
    private var lastScheduledAt: Double = 0
    /// If audio is still arriving but nothing has been scheduled for this long, give up on
    /// synchronising it and just play it. Continuity beats lip-sync: a small A/V offset is
    /// far less bad than silence for the rest of the session.
    private let audioStarvationSeconds: Double = 2.0
    private let clockResetThresholdSeconds: Double = 1.5

    // MARK: - Last-resort audio watchdog (BEAM-24)
    //
    // This bug has been "fixed" three times and come back, because every previous safety net
    // lived DOWNSTREAM of the thing that was broken:
    //   - starvation recovery lives inside schedule(), so a nil player node (one throwing
    //     engine.start()) returned before ever reaching it;
    //   - `lastScheduledAt` was stamped when scheduleBuffer was CALLED, so a stopped engine —
    //     which still accepts buffers happily — kept the watchdog permanently disarmed while
    //     rendering nothing;
    //   - the decoder rebuild lives inside StreamReceiver, so it cannot see a dead engine;
    //   - the connection watchdog keys off "any media packet", so audio-only death is invisible.
    //
    // The net below is deliberately anchored at the two ends that CANNOT be bypassed:
    //   ARRIVAL  — stamped in ConnectionManager the instant an .audio packet is read off the
    //              socket, before the codec check, the reorder guard, the decoder, everything.
    //   RENDERED — stamped from the player node's `.dataPlayedBack` completion, which only ever
    //              fires when a sample has actually left the engine.
    // If audio is arriving and nothing has rendered for `hardRebuildSilenceSeconds`, the ENTIRE
    // chain (decoder + session + engine + player node + sync anchors) is torn down and rebuilt,
    // and it will keep doing so, forever, until audio is audible again.
    private let arrivalLock = NSLock()
    private var lastAudioArrivedAt: Double = 0          // arrivalLock
    private var lastRenderedAt: Double = 0              // renderQueue
    /// When the current engine/player node was brought up. Used as the liveness floor before
    /// anything has rendered, so a chain that has NEVER produced sound is still recoverable.
    private var audioChainActiveSince: Double = 0       // renderQueue
    private var watchdogTimer: DispatchSourceTimer?     // renderQueue
    private let hardRebuildSilenceSeconds: Double = 5.0
    /// Audio counts as "arriving" if a packet landed within this window.
    private let arrivalFreshnessSeconds: Double = 2.0
    private var forcedRebuildCount = 0

    /// Consecutive rebuilds that did not restore audio, and the ceiling before we stop.
    ///
    /// A rebuild that does not work is not free: it stops the engine, deactivates and
    /// re-takes the audio session, and discards queued buffers. Repeating that every ~6s
    /// forever is strictly worse than leaving the chain alone — Kevin's log showed exactly
    /// that, hard-rebuild #8 through #11 back to back with audio dead throughout. If several
    /// rebuilds in a row fail to produce a single rendered buffer, the fault is not something
    /// a rebuild can fix, so stop and say so loudly rather than thrash.
    private var consecutiveFailedRebuilds = 0
    private let maxConsecutiveFailedRebuilds = 3
    private var rebuildsSuspended = false
    private var lastEngineRestoreAt: Double = -.greatestFiniteMagnitude
    private var didRegisterObservers = false

    /// Called on the render queue when the whole audio chain is rebuilt, so the AAC decoder
    /// upstream is discarded too. Wired by ConnectionManager to `streamReceiver.resetAudioDecoder()`.
    var onForceRebuild: (() -> Void)?

    // MARK: - Lifecycle

    func start() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            Self.sessionOwnerGeneration &+= 1
            self.myGeneration = Self.sessionOwnerGeneration
            self.setupAudioSession()
            self.setupEngine()
            self.startWatchdog()
        }
    }

    func stop() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
            resetSyncState()
            self.engine?.stop()
            self.playerNode?.stop()
            self.engine = nil
            self.playerNode = nil
            self.audioChainActiveSince = 0
            self.lastRenderedAt = 0
            self.arrivalLock.lock(); self.lastAudioArrivedAt = 0; self.arrivalLock.unlock()
            // Only the current session owner may deactivate the shared singleton; a stale
            // player tearing down after a reconnect must not mute the live one.
            if self.myGeneration == Self.sessionOwnerGeneration {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            logger.info("AudioPlayer stopped")
        }
    }

    /// Stamped the moment an audio packet is read off the socket — upstream of the codec check,
    /// the reorder guard, the decoder and the player. Cheap enough to call per packet.
    func noteAudioPacketArrived() {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        arrivalLock.lock()
        lastAudioArrivedAt = now
        arrivalLock.unlock()
    }

    func resetSync() {
        renderQueue.async { [weak self] in
            self?.resetSyncState()
        }
    }

    func updateRemoteFormat(sampleRate: Double, channels: Int) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            let normalizedRate = sampleRate.clamped(to: 8_000...96_000)
            let normalizedChannels = AVAudioChannelCount(max(1, min(channels, 8)))
            // Set BEFORE the early-out below: when the host's format happens to equal our
            // default, nothing "changes" and we'd return without ever recording that the
            // format is now confirmed — leaving the AAC decoder gate closed forever.
            formatLock.lock(); didReceiveRemoteFormat = true; formatLock.unlock()
            let sampleRateChanged = abs(normalizedRate - playbackSampleRate) > 1
            let channelsChanged = normalizedChannels != playbackChannels
            guard sampleRateChanged || channelsChanged else { return }

            playbackSampleRate = normalizedRate
            playbackChannels = normalizedChannels
            formatLock.lock()
            snapshotSampleRate = normalizedRate
            snapshotChannels = normalizedChannels
            formatLock.unlock()
            rebuildAudioEngineForFormatChange()
            logger.info("AudioPlayer format updated: \(normalizedRate, format: .fixed(precision: 0)) Hz, \(normalizedChannels)ch")
        }
    }

    // MARK: - Setup

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback keeps audio active in background (required for PiP) and lets AVKit
            // know this session is media-playback-eligible so isPictureInPicturePossible
            // becomes true as soon as the stream starts. .mixWithOthers lets other audio
            // (music, podcasts) continue alongside the stream.
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            // Ask the hardware to run at the SAME rate as the stream.
            //
            // Without this the session runs at whatever rate the hardware happened to
            // negotiate — which depends on the route and on whatever other app touched audio
            // last, so it differs between launches. When it disagrees with the stream rate,
            // every buffer is resampled underneath a scheduler that computes buffer durations
            // from the stream rate, and the error accumulates into evenly spaced dropouts:
            // audio that gaps on a fixed cadence rather than randomly. That matches the
            // "periodic cutouts, different every session, even on LAN" report exactly.
            //
            // Both ends are 48kHz now (ScreenCaptureKit delivers it, iPhone hardware is native
            // at it), so this should normally be a no-op that simply prevents the mismatch.
            // Preferred rates are advisory: verify against the actual rate below rather than
            // assuming it took.
            try? session.setPreferredSampleRate(playbackSampleRate)
            try session.setActive(true)
            let route = session.currentRoute.outputs.map { $0.portName }.joined(separator: ",")
            let actualRate = session.sampleRate
            if abs(actualRate - playbackSampleRate) > 1 {
                DiagnosticLogger.shared.log(
                    "Audio rate MISMATCH: hardware \(Int(actualRate))Hz vs stream \(Int(playbackSampleRate))Hz — resampling, expect periodic gaps",
                    category: "Audio"
                )
            }
            DiagnosticLogger.shared.log(
                "Audio session active — route: [\(route)], hardware \(Int(actualRate))Hz",
                category: "Audio"
            )
        } catch {
            logger.error("Failed to configure audio session: \(error)")
            DiagnosticLogger.shared.log("Audio session setup failed: \(error)", category: "Audio")
        }

        // Register once per instance. These used to be re-added on every start() and never
        // removed (no deinit), so stale players from previous reconnects kept receiving
        // callbacks and touching the shared session.
        guard !didRegisterObservers else { return }
        didRegisterObservers = true
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        // AVAudioEngine tears down its own connections on a configuration change and STOPS.
        // Nothing observed this, and a stopped engine still accepts scheduled buffers, so the
        // session went permanently silent with no error anywhere.
        center.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleEngineConfigurationChange(_ note: Notification) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            DiagnosticLogger.shared.log(
                "RECOVERY[engine-config-change]: AVAudioEngine reconfigured — rebuilding audio chain",
                category: "Audio"
            )
            self.forceRebuildAudioChain(reason: "AVAudioEngineConfigurationChange")
        }
    }

    @objc private func handleMediaServicesReset(_ note: Notification) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            DiagnosticLogger.shared.log(
                "RECOVERY[media-services-reset]: audio server restarted — rebuilding audio chain",
                category: "Audio"
            )
            self.setupAudioSession()
            self.forceRebuildAudioChain(reason: "mediaServicesWereReset")
        }
    }

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            DiagnosticLogger.shared.log("Audio session interrupted (began) — PiP/stream may drop", category: "Audio")
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            DiagnosticLogger.shared.log("Audio interruption ended (shouldResume=\(shouldResume))", category: "Audio")
            // Always attempt to resume, regardless of .shouldResume. iOS does not reliably set
            // that flag, and a restart we didn't need is harmless while a restart we skipped is
            // permanent silence.
            renderQueue.async { [weak self] in
                guard let self else { return }
                DiagnosticLogger.shared.log(
                    "RECOVERY[interruption-ended]: restarting engine",
                    category: "Audio"
                )
                try? AVAudioSession.sharedInstance().setActive(true)
                self.restoreEngineIfNeeded(at: self.hostNowSeconds(), force: true)
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portName }.joined(separator: ",")
        DiagnosticLogger.shared.log("Audio route changed (\(reason.name)) → [\(route)]", category: "Audio")
    }

    private func setupEngine() {
        guard engine == nil, playerNode == nil else { return }
        guard let format = makeOutputFormat() else {
            logger.error("Failed to create output format for audio engine")
            return
        }
        outputFormat = format
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            node.play()
            self.engine = engine
            self.playerNode = node
            self.audioChainActiveSince = hostNowSeconds()
            self.lastRenderedAt = 0
            logger.info("AudioPlayer engine started")
            DiagnosticLogger.shared.log(
                "Audio engine started (\(String(format: "%.0f", playbackSampleRate))Hz \(playbackChannels)ch)",
                category: "Audio"
            )
        } catch {
            logger.error("Failed to start audio engine: \(error)")
            // A throw here used to be terminal: engine and playerNode stayed nil forever and
            // nothing ever retried, so every subsequent packet returned at the nil-node guard.
            // The watchdog retries it — record the attempt time so it can see the chain is dead.
            self.audioChainActiveSince = hostNowSeconds()
            self.lastRenderedAt = 0
            DiagnosticLogger.shared.log("Audio engine start failed: \(error) — watchdog will retry", category: "Audio")
        }
    }

    // MARK: - Recovery

    private func startWatchdog() {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: Self.renderQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdogTimer = timer
    }

    /// renderQueue only. The last-resort guarantee: audio cannot stay dead while it is arriving.
    private func watchdogTick() {
        let now = hostNowSeconds()
        arrivalLock.lock()
        let arrivedAt = lastAudioArrivedAt
        arrivalLock.unlock()

        // Nothing arriving ⇒ nothing to guarantee. (This is also why a LAN session never enters
        // any of this: audio arrives AND renders continuously.)
        guard arrivedAt > 0, now - arrivedAt < arrivalFreshnessSeconds else { return }

        // Liveness floor: the later of "a sample was actually played back" and "the current
        // chain came up". A chain that has never rendered anything is still covered.
        let lastGood = max(lastRenderedAt, audioChainActiveSince)
        guard lastGood > 0, now - lastGood > hardRebuildSilenceSeconds else { return }

        forceRebuildAudioChain(
            reason: String(format: "no rendered audio for %.1fs while packets were still arriving", now - lastGood)
        )
    }

    /// renderQueue only. Tears down and rebuilds EVERYTHING: session, engine, player node,
    /// sync anchors, and (via `onForceRebuild`) the upstream AAC decoder. Never latches — the
    /// watchdog will simply run it again in another `hardRebuildSilenceSeconds` if it did not
    /// take, so no state anywhere can make audio permanently dead.
    private func forceRebuildAudioChain(reason: String) {
        // If audio rendered at any point since the last rebuild, the previous one worked and
        // this is a fresh fault; otherwise they are failing back to back.
        if lastRenderedAt > 0 {
            consecutiveFailedRebuilds = 0
        } else {
            consecutiveFailedRebuilds += 1
        }

        guard consecutiveFailedRebuilds <= maxConsecutiveFailedRebuilds else {
            if !rebuildsSuspended {
                rebuildsSuspended = true
                DiagnosticLogger.shared.log(
                    "RECOVERY[suspended]: \(maxConsecutiveFailedRebuilds) rebuilds in a row produced no audio — stopping, the fault is not one a rebuild can fix. Reconnect to reset.",
                    category: "Audio"
                )
                logger.error("Audio rebuild loop suspended after \(self.maxConsecutiveFailedRebuilds) failures")
            }
            return
        }

        forcedRebuildCount += 1
        DiagnosticLogger.shared.log(
            "RECOVERY[hard-rebuild #\(forcedRebuildCount)]: \(reason) — rebuilding decoder + session + engine + player node",
            category: "Audio"
        )
        logger.error("Forcing audio chain rebuild: \(reason)")

        engine?.stop()
        playerNode?.stop()
        engine = nil
        playerNode = nil
        outputFormat = nil
        resetSyncState()
        lastScheduledAt = 0
        lastRenderedAt = 0
        lastHardResyncAt = -.greatestFiniteMagnitude

        // Re-take ownership of the shared session; it may have been deactivated by an
        // interruption, a media-services reset or a stale player from a previous reconnect.
        Self.sessionOwnerGeneration &+= 1
        myGeneration = Self.sessionOwnerGeneration
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DiagnosticLogger.shared.log("Audio session re-activation failed: \(error)", category: "Audio")
        }

        setupEngine()
        // Mark the new chain as "just started" even if setupEngine failed, so the next
        // watchdog trip is a full interval away rather than immediate.
        audioChainActiveSince = hostNowSeconds()

        // Discard the AAC decoder too — a wedged decoder is one of the ways the chain can be
        // silent, and it lives upstream of everything above.
        onForceRebuild?()

        if watchdogTimer == nil { startWatchdog() }
    }

    /// renderQueue only. Cheap per-packet health assertion ahead of scheduling. Rate limited so
    /// a persistently broken engine cannot spin, but never gives up.
    private func restoreEngineIfNeeded(at now: Double, force: Bool = false) {
        if engine != nil, playerNode != nil, engine?.isRunning == true, !force { return }
        guard force || now - lastEngineRestoreAt > 1.0 else { return }
        lastEngineRestoreAt = now

        if engine == nil || playerNode == nil {
            DiagnosticLogger.shared.log(
                "RECOVERY[engine-missing]: no audio engine while packets are arriving — recreating",
                category: "Audio"
            )
            outputFormat = nil
            setupEngine()
            return
        }
        if engine?.isRunning != true {
            DiagnosticLogger.shared.log(
                "RECOVERY[engine-stopped]: engine not running — restarting",
                category: "Audio"
            )
            do {
                try engine?.start()
                playerNode?.play()
                audioChainActiveSince = now
            } catch {
                forceRebuildAudioChain(reason: "engine.start() threw during restart: \(error)")
            }
        } else if playerNode?.isPlaying != true {
            playerNode?.play()
        }
    }

    /// Hands a buffer to the node and records liveness from the RENDER side, not the call side.
    /// `.dataPlayedBack` only fires once the samples have actually left the engine, so a
    /// stopped/deaf engine can no longer masquerade as healthy and disarm the watchdog.
    private func scheduleTracked(
        _ node: AVAudioPlayerNode,
        _ buffer: AVAudioPCMBuffer,
        at when: AVAudioTime?,
        now: Double
    ) {
        if !node.isPlaying { node.play() }
        let completion: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
            guard let self else { return }
            let playedAt = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            Self.renderQueue.async {
                self.lastRenderedAt = max(self.lastRenderedAt, playedAt)
            }
        }
        if let when {
            node.scheduleBuffer(buffer, at: when, options: [], completionCallbackType: .dataPlayedBack, completionHandler: completion)
        } else {
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: completion)
        }
        lastScheduledAt = now
    }

    // MARK: - Enqueue

    func updateVideoClock(remotePresentationTimestampUs: Int64) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            ingestVideoClock(remotePresentationTimestampUs: remotePresentationTimestampUs)
        }
    }

    /// Legacy Float32 interleaved PCM entry point. Converts to a non-interleaved buffer and
    /// hands off to the shared scheduling path below — behaviour is unchanged.
    func enqueue(_ pcmData: Data, remotePresentationTimestampUs: Int64) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let buffer = self.makePCMBuffer(fromInterleavedFloat32: pcmData) else { return }
            self.schedule(buffer: buffer, remotePresentationTimestampUs: remotePresentationTimestampUs)
        }
    }

    /// Entry point for already-decoded PCM (AAC path). The buffer's format MUST match the
    /// engine's output format; it is dropped otherwise (a format change is in flight and
    /// `audio_format_changed` will rebuild the engine within a few packets).
    func enqueue(buffer: AVAudioPCMBuffer, remotePresentationTimestampUs: Int64) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            guard buffer.format.sampleRate == self.playbackSampleRate,
                  buffer.format.channelCount == self.playbackChannels else {
                logger.debug("Dropping decoded audio buffer with mismatched format")
                return
            }
            self.schedule(buffer: buffer, remotePresentationTimestampUs: remotePresentationTimestampUs)
        }
    }

    /// Shared scheduling / A/V-sync path. renderQueue-only.
    private func schedule(buffer: AVAudioPCMBuffer, remotePresentationTimestampUs: Int64) {
        // Engine health FIRST, ahead of the nil-node guard. A missing or stopped engine used to
        // return here silently and unreachably — the starvation net lived below this guard, so
        // once the node was nil nothing could ever bring audio back for the rest of the session.
        let startedAt = self.hostNowSeconds()
        restoreEngineIfNeeded(at: startedAt)
        guard let node = self.playerNode, self.engine?.isRunning == true else { return }

        // Starvation recovery. Deliberately ahead of every sync guard below, because the
        // whole point is to recover no matter WHICH of them has been silently dropping
        // audio — a stopped node, a stale anchor, a video clock that never came back.
        // Re-anchors on the current packet so normal synced scheduling resumes after.
        if self.lastScheduledAt > 0, startedAt - self.lastScheduledAt > self.audioStarvationSeconds {
            DiagnosticLogger.shared.log(
                "RECOVERY[starvation]: nothing scheduled for \(String(format: "%.1f", startedAt - self.lastScheduledAt))s — abandoning sync and playing immediately",
                category: "Audio"
            )
            self.nextScheduledAudioSeconds = nil
            self.syncAnchorRemotePTSUs = remotePresentationTimestampUs
            self.syncAnchorLocalSeconds = startedAt
            scheduleTracked(node, buffer, at: nil, now: startedAt)
            return
        }
        let session = AVAudioSession.sharedInstance()
        let shouldApplySync = session.outputVolume > 0.001
        if !shouldApplySync {
            nextScheduledAudioSeconds = nil
            scheduleTracked(node, buffer, at: nil, now: hostNowSeconds())
            return
        }
        guard lastVideoRemotePTSUs != nil else {
            // Video drives sync; ignore pre-roll audio until first video clock sample arrives.
            return
        }

        let now = hostNowSeconds()
        guard let mappedTime = mappedLocalSeconds(forRemotePTSUs: remotePresentationTimestampUs) else { return }
        var targetPlayTime = mappedTime + targetAudioLeadSeconds

        var shouldForceImmediateSchedule = false
        if let videoNowRemotePTSUs = estimatedRemoteVideoPTSUs(atLocalSeconds: now) {
            let desiredAudioPTSUs = videoNowRemotePTSUs + Int64(targetAudioLeadSeconds * 1_000_000.0)
            let avErrorSeconds = Double(remotePresentationTimestampUs - desiredAudioPTSUs) / 1_000_000.0

            if avErrorSeconds < -lateAudioCatchupThresholdSeconds {
                // Instead of dropping late audio (audible clicks/gaps), force immediate catch-up.
                shouldForceImmediateSchedule = true
                nextScheduledAudioSeconds = nil
                targetPlayTime = now + 0.004

                // Only dump the queue for a genuine DISCONTINUITY, never for a steady offset.
                //
                // Over a remote path audio consistently arrives later than the video clock
                // expects, because the two have different end-to-end latency. That shows up
                // as a persistent negative drift in a narrow band — Kevin's log sat between
                // -1.3s and -3.3s for minutes. Treating that as an error to correct meant
                // calling node.reset() every 2-3 seconds, and reset() DISCARDS all queued
                // audio: we were deleting the audio ourselves, over and over, which is what
                // "constantly buggy over Tailscale" actually was.
                //
                // Re-anchoring cannot fix it either, because the error is measured against
                // the video clock, so the same offset reappears immediately. A constant
                // offset is not correctable at this layer; it is a property of the link. So
                // absorb it into the anchor and keep playing. Slightly late audio that is
                // CONTINUOUS beats perfectly-timed audio that is repeatedly deleted.
                let isDiscontinuity = abs(avErrorSeconds) > catastrophicResyncThresholdSeconds
                if abs(avErrorSeconds) > hardAudioResyncThresholdSeconds,
                   now - lastHardResyncAt >= minSecondsBetweenHardResyncs {
                    lastHardResyncAt = now
                    if isDiscontinuity {
                        // Genuinely broken timeline (reconnect, seek, clock jump): the queued
                        // audio is meaningless, so clearing it is correct.
                        node.reset()
                        // reset() clears the scheduled queue AND leaves the node stopped.
                        // Without this play(), every buffer scheduled afterwards is silently
                        // discarded and audio never returns for the rest of the session.
                        node.play()
                    }
                    syncAnchorRemotePTSUs = remotePresentationTimestampUs
                    syncAnchorLocalSeconds = now
                    DiagnosticLogger.shared.log(
                        "RECOVERY[hard-resync]: A/V drift \(String(format: "%.2f", avErrorSeconds))s — queue dumped, anchor reset",
                        category: "Audio"
                    )
                }
            } else if avErrorSeconds > hardAudioResyncThresholdSeconds,
                      now - lastHardResyncAt >= minSecondsBetweenHardResyncs {
                // Symmetric counterpart. Audio EARLY was previously only clamped, never
                // re-anchored, so after a post-stall burst the node's real queue could stay
                // seconds deeper than the scheduler's model with no exit.
                lastHardResyncAt = now
                nextScheduledAudioSeconds = nil
                syncAnchorRemotePTSUs = remotePresentationTimestampUs
                syncAnchorLocalSeconds = now
                DiagnosticLogger.shared.log(
                    "RECOVERY[hard-resync-early]: audio \(String(format: "%.2f", avErrorSeconds))s ahead — anchor reset",
                    category: "Audio"
                )
            }
            if avErrorSeconds > maxAudioLeadSeconds {
                // Keep audio lead bounded; avoid excessive queueing.
                targetPlayTime = min(targetPlayTime, now + maxAudioLeadSeconds)
            }
        }

        if !shouldForceImmediateSchedule, let queuedAudioTime = nextScheduledAudioSeconds {
            targetPlayTime = max(targetPlayTime, queuedAudioTime)
        }
        targetPlayTime = max(targetPlayTime, now)
        targetPlayTime = min(targetPlayTime, now + maxAudioLeadSeconds)

        let durationSeconds = Double(buffer.frameLength) / playbackSampleRate
        nextScheduledAudioSeconds = targetPlayTime + durationSeconds

        if targetPlayTime <= now + 0.003 {
            scheduleTracked(node, buffer, at: nil, now: now)
            return
        }

        let hostTime = AVAudioTime.hostTime(forSeconds: targetPlayTime)
        scheduleTracked(node, buffer, at: AVAudioTime(hostTime: hostTime), now: now)
    }

    private func makePCMBuffer(fromInterleavedFloat32 data: Data) -> AVAudioPCMBuffer? {
        guard let format = outputFormat else { return nil }
        let channelCount = Int(playbackChannels)
        let bytesPerFrame = channelCount * MemoryLayout<Float32>.size
        guard bytesPerFrame > 0 else { return nil }

        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let floatChannels = buffer.floatChannelData else { return nil }
        data.withUnsafeBytes { srcRaw in
            let src = srcRaw.baseAddress!.assumingMemoryBound(to: Float32.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    floatChannels[channel][frame] = src[(frame * channelCount) + channel]
                }
            }
        }
        return buffer
    }

    private func ingestVideoClock(remotePresentationTimestampUs: Int64) {
        let now = hostNowSeconds()

        if let previousRemote = lastVideoRemotePTSUs,
           remotePresentationTimestampUs + 100_000 < previousRemote {
            // Stream timestamp discontinuity (seek/restart) - reset mapping.
            resetSyncState()
        }

        if syncAnchorRemotePTSUs == nil || syncAnchorLocalSeconds == nil {
            syncAnchorRemotePTSUs = remotePresentationTimestampUs
            syncAnchorLocalSeconds = now
        }

        lastVideoRemotePTSUs = remotePresentationTimestampUs
        lastVideoLocalSeconds = now

        if let mappedNow = mappedLocalSeconds(forRemotePTSUs: remotePresentationTimestampUs),
           abs(mappedNow - now) > clockResetThresholdSeconds {
            syncAnchorRemotePTSUs = remotePresentationTimestampUs
            syncAnchorLocalSeconds = now
        }

        if let queuedAudioTime = nextScheduledAudioSeconds, queuedAudioTime < now {
            nextScheduledAudioSeconds = nil
        }
    }

    private func mappedLocalSeconds(forRemotePTSUs remotePTSUs: Int64) -> Double? {
        guard let anchorRemote = syncAnchorRemotePTSUs, let anchorLocal = syncAnchorLocalSeconds else { return nil }
        let deltaSeconds = Double(remotePTSUs - anchorRemote) / 1_000_000.0
        return anchorLocal + deltaSeconds
    }

    private func estimatedRemoteVideoPTSUs(atLocalSeconds localSeconds: Double) -> Int64? {
        guard let videoPTS = lastVideoRemotePTSUs, let videoLocal = lastVideoLocalSeconds else { return nil }
        let elapsedSeconds = localSeconds - videoLocal
        return videoPTS + Int64(elapsedSeconds * 1_000_000.0)
    }

    private func hostNowSeconds() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    private func resetSyncState() {
        syncAnchorRemotePTSUs = nil
        syncAnchorLocalSeconds = nil
        lastVideoRemotePTSUs = nil
        lastVideoLocalSeconds = nil
        nextScheduledAudioSeconds = nil
    }

    private func rebuildAudioEngineForFormatChange() {
        let shouldRestartImmediately = engine != nil || playerNode != nil
        engine?.stop()
        playerNode?.stop()
        engine = nil
        playerNode = nil
        outputFormat = nil
        resetSyncState()
        lastScheduledAt = 0
        lastRenderedAt = 0
        audioChainActiveSince = hostNowSeconds()
        if shouldRestartImmediately {
            setupEngine()
        }
    }

    private func makeOutputFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: playbackSampleRate,
            channels: playbackChannels,
            interleaved: false
        )
    }
}

private extension AVAudioSession.RouteChangeReason {
    var name: String {
        switch self {
        case .newDeviceAvailable:       return "newDevice"
        case .oldDeviceUnavailable:     return "deviceRemoved"
        case .categoryChange:           return "categoryChange"
        case .override:                 return "override"
        case .wakeFromSleep:            return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "routeConfigChanged"
        case .unknown:                  return "unknown"
        @unknown default:               return "unknown(\(rawValue))"
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
