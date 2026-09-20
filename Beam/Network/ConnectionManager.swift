// ConnectionManager.swift
// Manages the TCP connection lifecycle from iOS to macOS.
// Handles authentication, receives stream packets, and dispatches to StreamReceiver.

import Network
import Phoros
import PhorosInput
import PhorosNetwork
import PhorosSession
import PhorosCore
import OSLog
import AVFoundation
import UIKit

private let logger = Logger(subsystem: "com.beam.ios", category: "ConnectionManager")

final class ConnectionManager {

    let host: DiscoveredHost
    let pairedMac: PairedMac
    private weak var appState: BeamAppState?

    private var transport: PhorosLegacyTransport?

    // MARK: rtc2 (experimental, BEAM-54)
    //
    // A Beacon built with the Phoros 2 spike offers a second transport after auth: ICE,
    // DTLS and RTP over UDP through PhorosCore. Accept it when the Debug toggle is on;
    // media then arrives from the peer and controller input goes on its realtime channel,
    // while control stays on TCP. Off, the offer is ignored and nothing changes.
    static let rtcDefaultsKey = "beam.debug.rtc2"
    static var rtcEnabled: Bool { UserDefaults.standard.bool(forKey: rtcDefaultsKey) }
    private var rtcPeer: RealtimePeer?
    private var rtcTransport: PhorosPeerTransport?
    private var rtcReady = false

    private func acceptRTC(_ offer: TransportOffer) {
        guard Self.rtcEnabled, offer.kind == "rtc2", rtcPeer == nil else { return }
        // Bind on the interface we reached the host on; port 0 is not usable here because the
        // answer must name the port, so pick one the host is not using.
        var local = "0.0.0.0"
        if let path = transport?.link.connection.currentPath, let endpoint = path.localEndpoint, case .hostPort(let h, _) = endpoint {
            local = "\(h)".split(separator: "%").first.map(String.init) ?? local
        }
        let address = "\(local):7982"
        guard let peer = RealtimePeer(isHost: false, localAddress: address) else {
            DiagnosticLogger.shared.log("rtc2: peer creation failed", category: "Connection"); return
        }
        let media = PhorosPeerTransport(peer: peer)
        media.onReady = { [weak self] in
            self?.rtcReady = true
            DiagnosticLogger.shared.log("rtc2 connected: media over UDP", category: "Connection")
        }
        media.onInbound = { [weak self] inbound in self?.handleInbound(inbound) }
        media.onEnd = { [weak self] _ in
            self?.rtcReady = false
            DiagnosticLogger.shared.log("rtc2 ended, media back on TCP", category: "Connection")
        }
        // Through a radio stall the peer stays alive and reconnects; input rides TCP meanwhile.
        media.onLinkStateChange = { [weak self] up in
            guard let self, self.rtcReady != up else { return }
            self.rtcReady = up
            DiagnosticLogger.shared.log(up ? "rtc2 link up" : "rtc2 link down, input on TCP", category: "Connection")
        }
        rtcPeer = peer
        rtcTransport = media
        guard peer.runOwnSocket() == 0 else {
            DiagnosticLogger.shared.log("rtc2: bind \(address) failed", category: "Connection"); rtcPeer = nil; rtcTransport = nil; return
        }
        peer.setRemote(info: offer.info, address: offer.address, nowMicros: 0)
        sendControl(.transportAnswer(TransportOffer(kind: "rtc2", address: address, info: peer.localInfo)))
        DiagnosticLogger.shared.log("rtc2 answered \(offer.address) from \(address)", category: "Connection")
    }
    private var isDisconnecting = false

    // Stream components
    let streamReceiver = StreamReceiver()
    let audioPlayer = AudioPlayer()
    /// Samples the iPhone-paired game controller into `.input` packets (PhorosInput).
    let controllerInput = ControllerSampler()

    private var receiveBuffer = Data()

    // Connection quality tracking
    private var lastPacketReceivedAt: Date = Date()
    private var lastMediaPacketReceivedAt: Date = Date()
    private var qualityTimer: DispatchSourceTimer?

    // MARK: Clock sync (frame age meter)
    //
    // The host stamps every frame with its capture time on its own clock. Four probes a
    // second give the offset between the two clocks (PhorosSession.ClockSync keeps the one
    // from the shortest round trip), and then each frame's age at arrival is one subtraction.
    // That number is what "how far behind the Mac am I" means, measured on the device.
    private var clockTimer: DispatchSourceTimer?
    private var clock = ClockSync()
    private let clockLock = NSLock()
    private var hostSupportsClockSync = false

    private static func nowMicros() -> Int64 {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        return Int64(Double(t.value) * 1_000_000 / Double(t.timescale))
    }

    private func startClockProbes() {
        clockTimer?.cancel()
        clockLock.lock(); clock.reset(); clockLock.unlock()
        streamReceiver.clock = nil
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.3, repeating: 0.25, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.clockLock.lock()
            let probe = self.clock.probe(now: Self.nowMicros())
            self.clockLock.unlock()
            self.sendControl(.clockProbe(probe))
        }
        timer.resume()
        clockTimer = timer
    }

    /// Frame ages over the last half second at two points (arrival on the assembly queue,
    /// and the hand-off to the display layer), published as p50/p95 for the meter.
    enum FrameAgePoint { case arrival, enqueue }
    private var frameAges: [FrameAgePoint: [TimeInterval]] = [:]
    private var frameAgesPublishedAt = Date.distantPast
    private let frameAgesLock = NSLock()
    func recordFrameAge(_ age: TimeInterval, at point: FrameAgePoint) {
        frameAgesLock.lock(); defer { frameAgesLock.unlock() }
        frameAges[point, default: []].append(age)
        let now = Date()
        guard now.timeIntervalSince(frameAgesPublishedAt) >= 0.5, (frameAges[.arrival]?.count ?? 0) >= 5 else { return }
        frameAgesPublishedAt = now
        func percentiles(_ values: [TimeInterval]) -> (TimeInterval, TimeInterval)? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        }
        let arrival = percentiles(frameAges[.arrival] ?? [])
        let enqueue = percentiles(frameAges[.enqueue] ?? [])
        frameAges.removeAll(keepingCapacity: true)
        guard let arrival else { return }
        let age = BeamAppState.FrameAge(arrivalP50: arrival.0, arrivalP95: arrival.1, enqueueP50: enqueue?.0, enqueueP95: enqueue?.1)
        Task { @MainActor in self.appState?.frameAge = age }
    }

    private func stopClockProbes() {
        clockTimer?.cancel()
        clockTimer = nil
        streamReceiver.clock = nil
    }
    private let controlInactivityTimeout: TimeInterval = 20
    private let mediaInactivityTimeoutForeground: TimeInterval = 8
    private let mediaInactivityTimeoutBackground: TimeInterval = 22
    private var streamStartedAt: Date? = nil

    /// Set to true while PiP is active so timeouts are relaxed for background operation.
    var isPiPActive: Bool = false

    /// Called when the connection drops due to inactivity / unexpected error (not user-initiated).
    /// Set by BeamAppState to trigger auto-reconnect.
    var onUnexpectedDisconnect: (() -> Void)?

    private var pathMonitor: NWPathMonitor?
    private var keepStreamViewOpen = false
    private var waitingSince: Date?
    private var waitingRecheck: Task<Void, Never>?
    private static let maxWaitingBeforeFailure: TimeInterval = 5

    // MARK: - Link RTT (BEAM-23)
    //
    // Over Tailscale the same "connected" state covers two wildly different links: a direct
    // WireGuard path (~100ms, carries 1080p60 fine) and a DERP-relayed one (measured at
    // 2200ms with 10% loss, which cannot carry video at all). Tailscale always STARTS relayed
    // and upgrades in the background, so the first seconds of a remote session are the bad
    // case even when the good one is moments away. The app can't query Tailscale, but RTT
    // separates the two cleanly, and the host already answers .ping with .pong.
    private var probe = RoundTripProbe()
    private var smoothedRTT: TimeInterval?

    // MARK: - Connection warmup (BEAM-33)
    //
    // Tailscale always starts DERP-relayed and upgrades to a direct path using small discovery
    // packets. Streaming megabits of video immediately starves those packets, so the upgrade
    // never completes and we are stuck on the 2.2s-RTT path we created ourselves. Measured:
    // `tailscale ping` established direct in seconds while the data plane, busy with video,
    // stayed relayed indefinitely.
    //
    // Three phases, only on remote connections. LAN needs none of this and must not pay for it.
    //   0. probe   - control packets only, no media. Cheap, and if RTT already says direct we
    //                skip straight to full quality at no cost.
    //   1. audio   - audio only (~96kbps) if still relay-like. The user hears the stream while
    //                the link stays quiet enough for the upgrade to land. Audio previously
    //                lagged because it competed with video for a saturated link; alone, neither
    //                head-of-line blocking nor video's frame-dropping asymmetry applies.
    //   2. full    - video resumes once RTT says direct, or the cap expires. The cap matters:
    //                some networks never get a direct path, and a degraded stream beats none.
    private enum WarmupPhase { case probing, audioOnly, full }
    private var warmupPhase: WarmupPhase = .full

    /// Whether this host restarts video correctly after a warmup hold (BEAM-21). Set from the
    /// authSuccess message; false for hosts that predate the fix, which never recover the
    /// picture once video has been held.
    private var hostSupportsVideoHold = false

    /// UserDefaults key for the "Stream audio" preference (BEAM-34). Absent = on.
    static let streamAudioDefaultsKey = "beam.streamAudio"
    static var streamAudioPreference: Bool {
        UserDefaults.standard.object(forKey: streamAudioDefaultsKey) as? Bool ?? true
    }

    /// Whether this session wants audio. Seeded from the preference at connect; flipped by
    /// `setAudioEnabled`. When false, incoming audio packets are dropped before the player
    /// regardless of what the host does, so an old Beacon that keeps sending is still silent.
    private(set) var isAudioEnabled = ConnectionManager.streamAudioPreference
    /// True once the host confirmed it honours `wantsAudio` (BEAM-34). On an older Beacon the
    /// toggle still mutes, it just can't save the bandwidth.
    private(set) var hostSupportsAudioToggle = false
    private(set) var hostSupportsWindowSelection = false
    /// True when the host said it replays controller input into a virtual gamepad (Beacon 1.5+).
    private(set) var hostSupportsControllerInput = false
    private var warmupStartedAt: Date?
    private var warmupTimer: DispatchSourceTimer?

    private static let probeSeconds: TimeInterval = 1.5
    private static let directRTT: TimeInterval = 0.25
    private static let warmupCapFresh: TimeInterval = 8.0
    private static let warmupCapFailover: TimeInterval = 4.0

    init(host: DiscoveredHost, pairedMac: PairedMac, appState: BeamAppState) {
        self.host = host
        self.pairedMac = pairedMac
        self.appState = appState
        self.streamReceiver.audioPlayer = self.audioPlayer
        self.streamReceiver.onVideoDimensionsChanged = { [weak self] size in
            Task { @MainActor in self?.appState?.videoAspect = size.width / size.height }
        }
        self.streamReceiver.onFrameAge = { [weak self] age in self?.recordFrameAge(age, at: .arrival) }
        // When AudioPlayer's watchdog rebuilds the playback chain, the AAC decoder upstream
        // must go with it — it is one of the ways the chain can be silent while packets arrive.
        self.audioPlayer.onForceRebuild = { [weak self] in
            self?.streamReceiver.resetAudioDecoder()
        }
    }

    // MARK: - Connect

    @MainActor
    func connect() async {
        isDisconnecting = false
        lastPacketReceivedAt = Date()
        lastMediaPacketReceivedAt = Date()
        streamReceiver.reset()
        DiagnosticLogger.shared.log("Connecting to \(host.name)", category: "Connection")
        let transport = PhorosLegacyTransport(to: host.endpoint, queue: .global(qos: .userInteractive))
        self.transport = transport
        transport.onReady = { [weak self] in
            Task { @MainActor in self?.handleConnectionState(.ready) }
        }
        transport.link.onWaiting = { [weak self] error in
            Task { @MainActor in self?.handleConnectionState(.waiting(error)) }
        }
        transport.onInbound = { [weak self] inbound in self?.handleInbound(inbound) }
        transport.onEnd = { [weak self] reason in
            guard let self else { return }
            switch reason as? PhorosConnectionEnd {
            case .transportFailed(let error):
                logger.error("Connection failed: \(error)")
                DiagnosticLogger.shared.log("Connection failed: \(error)", category: "Connection")
                self.triggerUnexpectedDisconnect()
            case .closedByPeer, .none:
                DiagnosticLogger.shared.log("Connection closed by remote", category: "Connection")
                self.triggerUnexpectedDisconnect()
            case .protocolViolation(let violation):
                DiagnosticLogger.shared.log("Protocol violation from host: \(String(describing: violation))", category: "Connection")
                self.triggerUnexpectedDisconnect()
            case .cancelled:
                Task { @MainActor in self.appState?.isStreaming = false }
            }
        }
        transport.start()
        startQualityMonitor()
        startPathMonitor()
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            waitingSince = nil
            waitingRecheck?.cancel()
            logger.info("Connected to \(self.host.name)")
            DiagnosticLogger.shared.log("TCP connected to \(host.name)", category: "Connection")
            sendAuthRequest()
        case .waiting(let error):
            // .waiting means "no route right now" and NWConnection will sit here indefinitely
            // rather than failing. Left alone it stalls the reconnect loop: no callback, no
            // retry, no progress. Give it a short grace for a transient blip, then treat it as
            // a failure so the retry/backoff machinery actually advances.
            logger.warning("Connection waiting: \(error)")
            DiagnosticLogger.shared.log("Connection waiting: \(error)", category: "Connection")
            waitingSince = waitingSince ?? Date()
            let stalledFor = Date().timeIntervalSince(waitingSince ?? Date())
            if stalledFor > Self.maxWaitingBeforeFailure {
                DiagnosticLogger.shared.log("No route for \(Int(stalledFor))s, treating as failed", category: "Connection")
                triggerUnexpectedDisconnect()
            } else {
                scheduleWaitingRecheck()
            }
        default:
            break  // failures and cancellation arrive through transport.onEnd
        }
    }

    /// `.waiting` fires once, not repeatedly, so a stalled connection needs its own nudge to
    /// be re-evaluated after the grace period.
    private func scheduleWaitingRecheck() {
        waitingRecheck?.cancel()
        waitingRecheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.maxWaitingBeforeFailure + 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self, let since = self.waitingSince else { return }
            guard Date().timeIntervalSince(since) > Self.maxWaitingBeforeFailure else { return }
            DiagnosticLogger.shared.log("Still no route, treating as failed", category: "Connection")
            self.triggerUnexpectedDisconnect()
        }
    }

    // MARK: - Authentication

    private func sendAuthRequest() {
        guard let secret = SharedSecret(bytes: pairedMac.sharedSecret) else {
            DiagnosticLogger.shared.log("Stored secret is malformed; re-pair this Mac", category: "Connection")
            disconnect()
            return
        }
        let auth = clientCapabilities().authRequest(secret: secret)
        guard let data = try? JSONEncoder().encode(auth) else { return }
        transport?.sendMessage(data)
        logger.info("Sent auth request to \(self.host.name) (audio \(self.isAudioEnabled ? "on" : "off"))")
    }

    /// What this phone tells the host it can do. Shared with PairingManager so hello and
    /// authRequest never disagree.
    private func clientCapabilities() -> ClientCapabilities {
        ClientCapabilities(
            deviceName: UIDevice.current.name,
            deviceID: KeyStore.shared.stableDeviceID, // must match the ID sent during pairing
            audioCodecs: AudioCodecID.clientAdvertisedCodecs().compactMap(AudioCodecID.init(wireName:)),
            videoCodecs: VideoCodecID.clientAdvertisedCodecs().compactMap(VideoCodecID.init(wireName:)),
            // State our hardware rate up front so the host encodes to it and the format never
            // has to change mid-session (BEAM-29). AVAudioSession.sampleRate is the rate the
            // hardware is actually running at right now, which is the number that matters.
            preferredAudioSampleRate: AVAudioSession.sharedInstance().sampleRate,
            wantsAudio: isAudioEnabled,
            // Ask for frames at this screen's refresh rate. A Beacon that knows the field
            // captures that fast when its own display can; one that does not keeps the preset's
            // 60. Every frame the host adds is a fresher frame at our next refresh. Off, the
            // field is absent and nothing changes for the host.
            maximumFrameRate: Self.highFrameRateEnabled ? Double(Self.screenMaximumFramesPerSecond) : nil
        )
    }

    static let highFrameRateDefaultsKey = "beam.highFrameRate"
    static var highFrameRateEnabled: Bool {
        UserDefaults.standard.object(forKey: highFrameRateDefaultsKey) as? Bool ?? true
    }

    /// The refresh rate of the screen the app is on: 120 on ProMotion, 60 elsewhere.
    static var screenMaximumFramesPerSecond: Int {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return max(60, scenes.first?.screen.maximumFramesPerSecond ?? 60)
    }

    // MARK: - Send Control Commands

    /// `controlID` names a button of the host's advertised layout (BEAM-39); `key` is what an
    /// older host acts on and is only meaningful for the built-in layout.
    func sendMediaKey(_ key: MediaKeyCommand.Key, controlID: String? = nil, text: String? = nil,
                      keystroke: String? = nil, keystrokeModifiers: UInt32? = nil, click: Click? = nil) {
        sendControl(.mediaKey(MediaKeyCommand(
            key: key, controlID: controlID, text: text,
            keystroke: keystroke, keystrokeModifiers: keystrokeModifiers, click: click
        )))
    }

    func sendStreamStop() {
        sendControl(.streamStop)
    }

    /// Turns audio on or off for the live session (BEAM-34). Always takes effect locally; the
    /// host is told as well so a Beacon that understands the message stops encoding entirely.
    func setAudioEnabled(_ enabled: Bool) {
        guard enabled != isAudioEnabled else { return }
        isAudioEnabled = enabled
        if !enabled { audioPlayer.resetSync() }
        DiagnosticLogger.shared.log(
            "Audio \(enabled ? "enabled" : "disabled") (host \(hostSupportsAudioToggle ? "honours" : "ignores") the request)",
            category: "Audio"
        )
        sendControl(.audioEnableRequest(enabled: enabled))
    }

    /// Sends a binary controller state report (packet type .input).
    /// Unlike JSON control messages, these are framed with a PacketHeader so the
    /// host can cheaply distinguish them from JSON without attempting a decode.
    func sendControllerState(_ state: ControllerReport, connected: Bool) {
        if rtcReady, let rtcTransport { rtcTransport.sendInput(state, connected: connected) }
        else { transport?.sendInput(state, connected: connected) }
    }

    // MARK: - Disconnect

    /// `keepStreamViewOpen` is set on the unexpected path so the UI can hold the last frame
    /// under a reconnect overlay instead of dumping the user back to the home screen for what
    /// is usually a one-second blip (or a WiFi/Tailscale handover).
    func disconnect(keepStreamViewOpen: Bool = false) {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        self.keepStreamViewOpen = keepStreamViewOpen

        qualityTimer?.cancel()
        qualityTimer = nil
        stopClockProbes()
        Task { @MainActor in self.appState?.frameAge = nil }
        warmupTimer?.cancel()
        warmupTimer = nil

        pathMonitor?.cancel()
        pathMonitor = nil

        // Analytics: stream ended
        if let startedAt = streamStartedAt {
            let duration = Date().timeIntervalSince(startedAt)
            let isPurchased = appState?.isPurchased ?? false
            Analytics.streamEnded(durationSeconds: duration, isPurchased: isPurchased)
            streamStartedAt = nil
            ReviewManager.recordStreamCompleted()
        }

        controllerInput.stop()
        DiagnosticLogger.shared.log("Disconnected from \(host.name)", category: "Connection")
        SessionManager.shared.stopSession()
        sendStreamStop()
        transport?.cancel()
        transport = nil
        rtcTransport?.cancel()
        rtcTransport = nil
        rtcPeer = nil
        rtcReady = false
        streamReceiver.reset()
        audioPlayer.stop()
        let holdOpen = keepStreamViewOpen
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !holdOpen { self.appState?.isStreaming = false }
            self.appState?.connectionQuality = 1.0
            // Only clear the app's pointer if it still refers to THIS manager.
            //
            // startStream() calls connectionManager?.disconnect() and then immediately
            // assigns the replacement. Both run on the main actor, but this cleanup is a Task
            // hop, so it was enqueued during disconnect() and executed AFTER the new manager
            // had been installed — nilling it out and deallocating the only strong reference
            // to the fresh connection. Every automatic reconnect died this way, silently,
            // while a manual start from the home screen always worked because there was no
            // outgoing manager to schedule the clobber in the first place.
            if self.appState?.connectionManager === self {
                self.appState?.connectionManager = nil
            }
        }
        logger.info("Disconnected from \(self.host.name)")
    }

    /// Triggers the unexpected-disconnect path: tears down and calls back to allow reconnect.
    ///
    /// The callback is main-actor isolated (it's assigned inside `BeamAppState.startStream()`,
    /// which is `@MainActor`), but this method runs on whichever queue noticed the failure —
    /// usually the network receive queue. Invoking it directly from there runs main-actor code
    /// off the main thread and mutates @Published state from a background queue, which hangs
    /// the UI rather than crashing. Hop explicitly.
    private func triggerUnexpectedDisconnect() {
        let callback = onUnexpectedDisconnect
        disconnect(keepStreamViewOpen: callback != nil)
        guard let callback else { return }
        Task { @MainActor in callback() }
    }

    // MARK: - Receive

    private func handleInbound(_ inbound: RealtimeInbound) {
        lastPacketReceivedAt = Date()
        switch inbound {
        case .video(let frame):
            lastMediaPacketReceivedAt = Date()
            streamReceiver.receive(frame)

        case .videoParameterSets(let data, let codec):
            // The codec (H.264 vs HEVC) came from the packet's flags nibble; a legacy host
            // sends 0 = H.264. The transport already dropped an id this build does not know.
            streamReceiver.receiveParameterSets(data, codec: codec)

        case .audio(let header, let body, let codec):
            lastMediaPacketReceivedAt = Date()
            // Audio off: drop here, above the arrival stamp, so the player's watchdog sees
            // "nothing arriving" rather than "arriving but never rendered" (BEAM-34).
            guard isAudioEnabled else { return }
            // Stamp arrival BEFORE anything downstream can decline the chunk: reorder guard,
            // missing format, a nil decoder, a mismatched buffer format, a dead engine. This is
            // the only signal AudioPlayer's last-resort watchdog trusts to mean "audio is still
            // coming"; every previous safety net sat below one of those guards and could
            // therefore be starved by the very failure it existed to fix.
            audioPlayer.noteAudioPacketArrived()
            streamReceiver.receive(audioHeader: header, body: body, codec: codec, player: audioPlayer)

        case .message(let json):
            if let msg = try? JSONDecoder().decode(PairingMessage.self, from: json) {
                handlePairingMessage(msg)
            } else {
                DiagnosticLogger.shared.log("Undecodable message from host (\(json.count) B)", category: "Connection")
            }

        case .control(let message):
            handleControlMessage(message)

        case .unknownControl(let name):
            // A newer host. Ignoring is the contract; see Phoros docs/compatibility.md.
            DiagnosticLogger.shared.log("Ignoring unknown control message '\(name)' from a newer host", category: "Connection")

        case .heartbeat:
            sendControl(.pong)

        case .input:
            break  // outbound-only (iOS → macOS); the host never sends input packets
        }
    }

    // MARK: - Warmup

    /// Starts the probe phase on remote connections. LAN goes straight to full.
    private func beginWarmupIfRemote() {
        #if DEBUG
        // Diagnostic/screenshot only: `-beam.debug.skipWarmup YES` never pauses video, to
        // isolate whether a black remote stream is the pause/resume handshake or the pipeline.
        if UserDefaults.standard.bool(forKey: "beam.debug.skipWarmup") {
            warmupPhase = .full
            DiagnosticLogger.shared.log("Warmup skipped (debug setting)", category: "Connection")
            return
        }
        #endif
        guard appState?.usingRemoteHost == true else {
            warmupPhase = .full
            return
        }
        // An older Beacon accepts the hold and then never brings the picture back (BEAM-21).
        // Streaming immediately on a relayed link is worse than warmup, but it is not black.
        guard hostSupportsVideoHold else {
            warmupPhase = .full
            DiagnosticLogger.shared.log(
                "Warmup skipped — this Mac needs a Beacon update to hold video safely",
                category: "Connection"
            )
            return
        }
        warmupPhase = .probing
        warmupStartedAt = Date()
        // Hold video immediately: the whole point is to leave the relay quiet enough for
        // Tailscale's upgrade handshake to get through.
        sendControl(.videoPause)
        DiagnosticLogger.shared.log(
            "Warmup: probing link before sending video",
            category: "Connection"
        )

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.evaluateWarmup() }
        timer.resume()
        warmupTimer = timer
    }

    private func evaluateWarmup() {
        guard warmupPhase != .full, let startedAt = warmupStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        // A failover is already an interruption the user is watching, so it gets less patience.
        let cap = (appState?.isReconnecting == true) ? Self.warmupCapFailover : Self.warmupCapFresh
        let rtt = smoothedRTT

        // Probe frequently while warming up; the normal 2s cadence is too slow to notice an
        // upgrade that lands in a second.
        sendLinkPing()

        if let rtt, rtt < Self.directRTT {
            finishWarmup(reason: "direct path (RTT \(Int(rtt * 1000))ms)")
            return
        }
        if elapsed >= cap {
            finishWarmup(reason: "cap reached after \(String(format: "%.1f", elapsed))s, streaming anyway")
            return
        }
        // Still relay-like after the probe window: let audio through while we keep waiting.
        if warmupPhase == .probing, elapsed >= Self.probeSeconds {
            warmupPhase = .audioOnly
            DiagnosticLogger.shared.log(
                "Warmup: link still slow, audio only while the path settles",
                category: "Connection"
            )
        }
    }

    private func finishWarmup(reason: String) {
        guard warmupPhase != .full else { return }
        warmupPhase = .full
        warmupTimer?.cancel()
        warmupTimer = nil
        sendControl(.videoResume)
        DiagnosticLogger.shared.log("Warmup complete: \(reason)", category: "Connection")
    }

    /// Client control messages go bare, with no packet header. The host classifies each
    /// frame by the packet magic and treats anything else as JSON.
    private func sendControl(_ message: ControlMessage) {
        transport?.sendControl(message)
    }

    /// Sends a .ping and starts the RTT clock. RoundTripProbe abandons a probe whose reply
    /// never came, so one lost pong can never stop RTT from being measured again.
    private func sendLinkPing() {
        guard probe.shouldSend() else { return }
        sendControl(.ping)
    }

    private func handlePong() {
        guard let sample = probe.receivedPong() else { return }
        // Light smoothing: a single spike shouldn't flip the badge, but a genuine path
        // upgrade should show up within a few samples.
        smoothedRTT = smoothedRTT.map { $0 * 0.7 + sample * 0.3 } ?? sample
        let rtt = smoothedRTT ?? sample
        Task { @MainActor in self.appState?.linkRTT = rtt }
    }

    private func handleControlMessage(_ message: ControlMessage) {
        switch message {
        case .pong:
            handlePong()
        case .transportOffer(let offer):
            acceptRTC(offer)
        case .transportAnswer:
            break  // a client never receives answers
        case .clockReply(let reply):
            let now = Self.nowMicros()
            var updated: ClockSync?
            clockLock.lock()
            if clock.reply(reply, now: now) != nil { updated = clock }
            clockLock.unlock()
            if let updated { streamReceiver.clock = updated }
        case .qualityChanged(let preset):
            Task { @MainActor in
                self.appState?.currentQualityPreset = preset
            }
        case .audioFormatChanged(let format):
            audioPlayer.updateRemoteFormat(sampleRate: format.sampleRate, channels: format.channels)
            // The AAC decoder's format must equal the engine's; discard it so the next
            // AAC packet rebuilds it against the new rate/channel count.
            streamReceiver.resetAudioDecoder()
        case .windowList(let windows):
            Task { @MainActor in
                self.appState?.hostWindows = windows
                self.appState?.isLoadingHostWindows = false
            }
        case .captureModeChanged(let mode):
            DiagnosticLogger.shared.log(
                mode.windowMode ? "Host capturing window: \(mode.app ?? "") — \(mode.title ?? "")" : "Host capturing full display",
                category: "Capture"
            )
            Task { @MainActor in
                self.appState?.hostCaptureMode = mode
            }
        case .ping, .streamRequest, .streamStop, .qualityFeedback, .qualityRequest,
             .viewportLockRequest, .videoPause, .videoResume, .audioEnableRequest,
             .windowListRequest, .windowSelectRequest, .mediaKey, .clockProbe:
            // Client-to-host messages; a host never sends these.
            break
        }
    }

    // MARK: - Host window selection (BEAM-35)

    /// Ask the host for its current window list. The reply lands in `appState.hostWindows`.
    func requestWindowList() {
        guard hostSupportsWindowSelection else { return }
        Task { @MainActor in appState?.isLoadingHostWindows = true }
        sendControl(.windowListRequest)
    }

    /// Lock the host's capture to a window, or pass 0 to return to the full display. The host
    /// confirms with `capture_mode_changed`; nothing changes locally until it does.
    func selectHostWindow(_ windowID: UInt32) {
        guard hostSupportsWindowSelection else { return }
        sendControl(.windowSelectRequest(windowID: windowID))
    }

    private func handlePairingMessage(_ msg: PairingMessage) {
        switch msg.type {
        case .authSuccess:
            logger.info("Authenticated with \(self.host.name), stream starting")
            DiagnosticLogger.shared.log("Auth success, stream starting", category: "Connection")
            // Diagnostic only — the authority for how to decode any given audio packet is
            // always that packet's PacketHeader.flags, never this field.
            DiagnosticLogger.shared.log(
                "Host audio codec: \(msg.selectedAudioCodec ?? "pcm (legacy host)")",
                category: "Audio"
            )
            // Diagnostic only — the authority for how to decode video is the .parameterSets packet's
            // flags, never this field. A legacy host omits it and streams H.264.
            DiagnosticLogger.shared.log(
                "Host video codec: \(msg.selectedVideoCodec ?? "h264 (legacy host)")",
                category: "Video"
            )
            streamStartedAt = Date()
            // Read synchronously: beginWarmupIfRemote() below decides whether to hold video
            // based on this, so it cannot wait on a hop to the main actor.
            let peer = PeerCapabilities(msg)
            hostSupportsVideoHold = peer.supportsVideoHold
            hostSupportsAudioToggle = peer.supportsAudioToggle
            hostSupportsWindowSelection = peer.supportsWindowSelection
            hostSupportsControllerInput = peer.supportsControllerInput
            hostSupportsClockSync = peer.supportsClockSync
            if peer.supportsClockSync { startClockProbes() }
            let controls = Array(peer.controls.prefix(8))
            Task { @MainActor in
                appState?.hostSupportsWindowSelection = self.hostSupportsWindowSelection
                appState?.hostPhoneControls = controls
            }
            if !isAudioEnabled, !hostSupportsAudioToggle {
                DiagnosticLogger.shared.log("Audio off but host predates the audio toggle — muting locally only", category: "Audio")
            }
            // Refresh the host's remote (Tailscale) addresses on every successful auth, not
            // just at pairing — this is how the stored copy stays correct if the Mac's tailnet
            // address changes (BEAM-19). Runs while we're on the LAN, so away-from-home works
            // later without the user configuring anything.
            Task { @MainActor in
                appState?.updateRemoteHosts(msg.remoteHosts, hostSupportsRemote: msg.supportsRemoteAccess)
                // Reconnected: close the hold window and let the overlay fade.
                if appState?.isReconnecting == true { appState?.endReconnect(resumed: true) }
            }
            // Record first stream to start the 3-day free trial clock (no-op after first time)
            SessionManager.shared.recordFirstStream()
            let isPurchased = appState?.isPurchased ?? false
            let isInTrial = SessionManager.shared.isInTrial
            let quality = appState?.preferredQualityPreset.rawValue ?? "auto"
            Analytics.streamStarted(isPurchased: isPurchased, isInTrial: isInTrial, qualityPreset: quality)
            Task { @MainActor in
                appState?.isStreaming = true
                // Start free tier timer if not purchased and not in trial
                if !(appState?.isPurchased ?? false) {
                    SessionManager.shared.startSession()
                }
            }
            audioPlayer.start()
            // Start forwarding game controller input (no-op until a controller connects).
            // The host's word is the gate: Beacon 1.5+ advertises supportsControllerInput and
            // can replay the packets. The remote flag (BEAM-18) stays as the gate for hosts
            // that predate the capability, where it is the only signal a phone has. While
            // neither says yes we never attach to GCController and never emit .input packets.
            if hostSupportsControllerInput || FeatureFlags.isUnlocked(.controllerPassthrough) {
                DiagnosticLogger.shared.log(
                    "Controller forwarding armed (host \(hostSupportsControllerInput ? "advertises" : "predates") the capability)",
                    category: "Controller"
                )
                controllerInput.onAttachmentChange = { [weak self] attached in
                    DiagnosticLogger.shared.log("Controller \(attached ? "attached" : "detached")", category: "Controller")
                    Task { @MainActor in
                        self?.appState?.isControllerConnected = attached
                    }
                }
                controllerInput.onReport = { [weak self] report, connected in
                    self?.sendControllerState(report, connected: connected)
                }
                controllerInput.start()
            }
            // Send our quality preference to the host immediately after auth.
            //
            // Over a remote (Tailscale) path we cap it. The presets and the host's auto tiers
            // are tuned for LAN bandwidth, so `auto` opens at 1080p30/6 Mbps and only walks
            // down after the feedback loop has already produced visible buffering. On cellular
            // or a DERP-relayed tailnet that first guess is far too optimistic, so we start
            // conservative and let the host adapt upward if the link turns out to be good.
            // Remote sessions use their own preference (default 720p30) rather than the LAN
            // one. 1080p60 is a fine default at home and a reliable way to stall a cellular
            // or relayed tailnet, and the two links are different enough that one setting
            // can't serve both.
            var preferred: QualityPreset
            if appState?.usingRemoteHost == true {
                // Route-specific setting; see BeamAppState.activeQualityPreset.
                preferred = appState?.remoteQualityPreset ?? .p720_30
                if preferred == .auto {
                    // Only Auto hands control to the ladder. Enter below auto's LAN-tuned
                    // 1080p30 opening guess and climb: being briefly too soft is recoverable,
                    // opening too hot means visible buffering before adaptation reacts.
                    ladderIndex = Self.ladder.firstIndex(of: .p480_30) ?? 1
                    preferred = Self.ladder[ladderIndex!]
                }
                DiagnosticLogger.shared.log(
                    "Remote path: quality \(preferred.rawValue)\(ladderIndex != nil ? " (adaptive)" : " (fixed)")",
                    category: "Quality"
                )
            } else {
                preferred = appState?.preferredQualityPreset ?? .auto
            }
            sendQualityRequest(preferred)
            beginWarmupIfRemote()
            // Sync viewport lock state with host. Host keeps its own lock across sessions,
            // so we must always send the current state — lock if we have a saved rect,
            // explicit unlock if we don't (covers the keepViewportLock=false case).
            sendViewportLock(appState?.lockedViewportRect)

        case .authFailed:
            logger.error("Auth failed: \(msg.error ?? "unknown")")
            if msg.error == "Device not paired" {
                // Host no longer recognises this device — clear stale pairing data
                KeyStore.shared.clearPairedMac()
                Task { @MainActor in
                    appState?.pairedMac = nil
                    appState?.isStreaming = false
                }
            }
            disconnect()

        case .unpaired:
            logger.info("Host unpaired this device — clearing local pairing data")
            KeyStore.shared.clearPairedMac()
            Task { @MainActor in
                appState?.pairedMac = nil
                appState?.isStreaming = false
            }
            disconnect()

        default:
            break
        }
    }

    // MARK: - Connection Quality

    private func startQualityMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let controlElapsed = Date().timeIntervalSince(lastPacketReceivedAt)
            let mediaElapsed = Date().timeIntervalSince(lastMediaPacketReceivedAt)

            // Relax timeouts when PiP is active — iOS throttles background network delivery,
            // so short timeouts cause spurious disconnects when the user is still watching.
            let mediaTimeout = isPiPActive ? mediaInactivityTimeoutBackground : mediaInactivityTimeoutForeground

            if controlElapsed >= controlInactivityTimeout {
                logger.warning("No packets for \(controlElapsed, format: .fixed(precision: 1))s, disconnecting")
                DiagnosticLogger.shared.log(
                    "Control timeout (\(String(format: "%.1f", controlElapsed))s, PiP=\(isPiPActive))",
                    category: "Timeout"
                )
                self.triggerUnexpectedDisconnect()
                return
            }
            if mediaElapsed >= mediaTimeout {
                logger.warning("No media packets for \(mediaElapsed, format: .fixed(precision: 1))s (timeout=\(mediaTimeout)s, PiP=\(isPiPActive)), disconnecting stalled stream")
                DiagnosticLogger.shared.log(
                    "Media timeout (\(String(format: "%.1f", mediaElapsed))s, threshold=\(String(format: "%.0f", mediaTimeout))s, PiP=\(isPiPActive))",
                    category: "Timeout"
                )
                self.triggerUnexpectedDisconnect()
                return
            }
            let quality: Double
            switch mediaElapsed {
            case ..<0.3:  quality = 1.00
            case ..<0.8:  quality = 0.75
            case ..<1.5:  quality = 0.50
            default:      quality = 0.25
            }
            Task { @MainActor in
                self.appState?.connectionQuality = quality
            }
            // Send quality feedback to host for auto-adaptation
            self.sendQualityFeedback(quality)
            self.stepRemoteQualityLadder(quality: quality)
            self.sendLinkPing()
        }
        timer.resume()
        qualityTimer = timer
    }

    // MARK: - Remote Quality Ladder (BEAM-19)
    //
    // Over Tailscale the achievable bitrate varies enormously and we cannot tell which case
    // we're in from inside the app:
    //   - a DIRECT WireGuard connection is limited only by the two internet links, so it can
    //     comfortably carry 1080p60 and there is no reason to leave that on the table;
    //   - a DERP-RELAYED connection goes through Tailscale's shared relay infrastructure,
    //     which is intended as a fallback rather than a bulk-video pipe, and is both slower
    //     and rude to hammer.
    // Tailscale exposes which one you got via its CLI, but neither app can query that (the
    // iOS client can't, and Beacon can't rely on a `tailscale` binary path that differs across
    // App Store, brew and standalone installs).
    //
    // So we don't guess the transport — we measure the path. Start below the LAN default,
    // then climb one tier at a time while the link holds up, and drop two tiers immediately
    // when it doesn't. A direct connection walks up to its ceiling within ~20s; a relayed or
    // congested cellular one settles low and stays there.

    private static let ladder: [QualityPreset] = [.p360_30, .p480_30, .p720_30, .p1080_30, .p1080_60]
    private var ladderIndex: Int?
    private var goodTicks = 0

    /// Number of consecutive healthy 2s samples required before stepping up. Deliberately
    /// asymmetric with the drop: climbing costs a re-encode and a visible resolution change,
    /// so it should be earned, while falling should be immediate.
    private static let ticksPerStepUp = 4

    private func stepRemoteQualityLadder(quality: Double) {
        // Only drives remote sessions, and only when the user asked for Auto — an explicit
        // preset is a deliberate choice and we must not override it.
        guard appState?.usingRemoteHost == true,
              appState?.remoteQualityPreset == .auto,
              var index = ladderIndex else { return }

        if quality >= 0.95 {
            goodTicks += 1
            // Respect the remote ceiling on the way UP too. It was previously applied only to
            // the opening guess, so a link scoring well (which it always does — the score is
            // derived from packet arrival gaps, not from latency) climbed to 1080p60 in ~24s.
            let ceiling = Self.ladder.firstIndex(of: QualityPreset.remoteCap) ?? (Self.ladder.count - 1)
            guard goodTicks >= Self.ticksPerStepUp, index < min(ceiling, Self.ladder.count - 1) else { return }
            goodTicks = 0
            index += 1
        } else if quality <= 0.5 {
            // Drop two tiers, not one: by the time the score has fallen this far the user is
            // already seeing buffering, and creeping down one step at a time prolongs it.
            guard index > 0 else { goodTicks = 0; return }
            goodTicks = 0
            index = max(0, index - 2)
        } else {
            goodTicks = 0
            return
        }

        ladderIndex = index
        let preset = Self.ladder[index]
        DiagnosticLogger.shared.log(
            "Remote ladder → \(preset.rawValue) (quality=\(String(format: "%.2f", quality)))",
            category: "Quality"
        )
        sendQualityRequest(preset)
    }

    // MARK: - Network Path Monitor

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let ifaces = path.availableInterfaces.map(\.name).joined(separator: ",")
            let expensive = path.isExpensive ? ",expensive" : ""
            let constrained = path.isConstrained ? ",constrained" : ""
            DiagnosticLogger.shared.log(
                "Network path: \(path.status) via [\(ifaces)\(expensive)\(constrained)]",
                category: "Network"
            )
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    // MARK: - Quality

    func sendQualityFeedback(_ quality: Double) {
        sendControl(.qualityFeedback(quality: quality))
    }

    /// Called when app returns to foreground; drops a stale stream view immediately
    /// instead of keeping a frozen last frame.
    func performForegroundHealthCheck() {
        guard appState?.isStreaming == true else { return }
        let mediaElapsed = Date().timeIntervalSince(lastMediaPacketReceivedAt)
        if mediaElapsed > 3.0 {
            logger.warning("Foreground check detected stale media (\(mediaElapsed, format: .fixed(precision: 1))s), disconnecting")
            disconnect()
        }
    }

    func sendQualityRequest(_ preset: QualityPreset) {
        sendControl(.qualityRequest(preset))
    }

    func sendViewportLock(_ normalizedRect: CGRect?) {
        let lock: ViewportLock
        if let normalizedRect {
            lock = ViewportLock(
                locked: true,
                x: normalizedRect.origin.x,
                y: normalizedRect.origin.y,
                width: normalizedRect.width,
                height: normalizedRect.height
            )
        } else {
            lock = .unlocked
        }
        sendControl(.viewportLockRequest(lock))
    }

}
