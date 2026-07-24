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
    private let renderQueue = DispatchQueue(label: "com.beam.ios.audioplayer", qos: .userInteractive)

    // Remote audio format (updated by host control messages).
    private var playbackSampleRate: Double = 44_100
    private var playbackChannels: AVAudioChannelCount = 2
    private var outputFormat: AVAudioFormat?

    /// Thread-safe snapshot of the format above, so the AAC decoder can be built with a format
    /// that is byte-identical to the engine's without hopping onto renderQueue.
    private let formatLock = NSLock()
    private var snapshotSampleRate: Double = 44_100
    private var snapshotChannels: AVAudioChannelCount = 2

    var currentSampleRate: Double {
        formatLock.lock(); defer { formatLock.unlock() }
        return snapshotSampleRate
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

    // MARK: - Lifecycle

    func start() {
        renderQueue.async { [weak self] in
            self?.setupAudioSession()
            self?.setupEngine()
        }
    }

    func stop() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            resetSyncState()
            self.engine?.stop()
            self.playerNode?.stop()
            self.engine = nil
            self.playerNode = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("AudioPlayer stopped")
        }
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
            try session.setActive(true)
            let route = session.currentRoute.outputs.map { $0.portName }.joined(separator: ",")
            DiagnosticLogger.shared.log("Audio session active — route: [\(route)]", category: "Audio")
        } catch {
            logger.error("Failed to configure audio session: \(error)")
            DiagnosticLogger.shared.log("Audio session setup failed: \(error)", category: "Audio")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
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
            if shouldResume {
                renderQueue.async { [weak self] in
                    try? self?.engine?.start()
                    self?.playerNode?.play()
                }
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
            logger.info("AudioPlayer engine started")
            DiagnosticLogger.shared.log(
                "Audio engine started (\(String(format: "%.0f", playbackSampleRate))Hz \(playbackChannels)ch)",
                category: "Audio"
            )
        } catch {
            logger.error("Failed to start audio engine: \(error)")
            DiagnosticLogger.shared.log("Audio engine start failed: \(error)", category: "Audio")
        }
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
        guard let node = self.playerNode else { return }

        // Starvation recovery. Deliberately ahead of every sync guard below, because the
        // whole point is to recover no matter WHICH of them has been silently dropping
        // audio — a stopped node, a stale anchor, a video clock that never came back.
        // Re-anchors on the current packet so normal synced scheduling resumes after.
        let startedAt = self.hostNowSeconds()
        if self.lastScheduledAt > 0, startedAt - self.lastScheduledAt > self.audioStarvationSeconds {
            DiagnosticLogger.shared.log(
                "Audio starvation recovery after \(String(format: "%.1f", startedAt - self.lastScheduledAt))s silence",
                category: "Audio"
            )
            if !node.isPlaying { node.play() }
            self.nextScheduledAudioSeconds = nil
            self.syncAnchorRemotePTSUs = remotePresentationTimestampUs
            self.syncAnchorLocalSeconds = startedAt
            node.scheduleBuffer(buffer, completionHandler: nil)
            self.lastScheduledAt = startedAt
            return
        }
        let session = AVAudioSession.sharedInstance()
        let shouldApplySync = session.outputVolume > 0.001
        if !shouldApplySync {
            nextScheduledAudioSeconds = nil
            if !node.isPlaying { node.play() }
            node.scheduleBuffer(buffer, completionHandler: nil)
            lastScheduledAt = hostNowSeconds()
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

                if abs(avErrorSeconds) > hardAudioResyncThresholdSeconds,
                   now - lastHardResyncAt >= minSecondsBetweenHardResyncs {
                    lastHardResyncAt = now
                    // Severe discontinuity: clear queued audio and reset anchor.
                    node.reset()
                    // reset() clears the scheduled queue AND leaves the node stopped.
                    // Without this play(), every buffer scheduled afterwards is silently
                    // discarded and audio never returns for the rest of the session —
                    // which is exactly what happened after a stall-induced resync burst:
                    // reconnecting was the only way to get sound back.
                    node.play()
                    syncAnchorRemotePTSUs = remotePresentationTimestampUs
                    syncAnchorLocalSeconds = now
                    DiagnosticLogger.shared.log(
                        "Hard A/V resync (drift=\(String(format: "%.2f", avErrorSeconds))s)",
                        category: "Audio"
                    )
                }
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
            if !node.isPlaying { node.play() }
            node.scheduleBuffer(buffer, completionHandler: nil)
            lastScheduledAt = now
            return
        }

        let hostTime = AVAudioTime.hostTime(forSeconds: targetPlayTime)
        let when = AVAudioTime(hostTime: hostTime)
        if !node.isPlaying { node.play() }
        node.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
        lastScheduledAt = now
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
