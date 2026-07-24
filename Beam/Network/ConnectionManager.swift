// ConnectionManager.swift
// Manages the TCP connection lifecycle from iOS to macOS.
// Handles authentication, receives stream packets, and dispatches to StreamReceiver.

import Network
import OSLog
import UIKit

private let logger = Logger(subsystem: "com.beam.ios", category: "ConnectionManager")

final class ConnectionManager {

    let host: DiscoveredHost
    let pairedMac: PairedMac
    private weak var appState: BeamAppState?

    private var connection: NWConnection?
    private var isDisconnecting = false

    // Stream components
    let streamReceiver = StreamReceiver()
    let audioPlayer = AudioPlayer()
    let controllerInput = ControllerInputManager()

    private var receiveBuffer = Data()

    // Connection quality tracking
    private var lastPacketReceivedAt: Date = Date()
    private var lastMediaPacketReceivedAt: Date = Date()
    private var qualityTimer: DispatchSourceTimer?
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

    init(host: DiscoveredHost, pairedMac: PairedMac, appState: BeamAppState) {
        self.host = host
        self.pairedMac = pairedMac
        self.appState = appState
        self.streamReceiver.audioPlayer = self.audioPlayer
    }

    // MARK: - Connect

    @MainActor
    func connect() async {
        isDisconnecting = false
        lastPacketReceivedAt = Date()
        lastMediaPacketReceivedAt = Date()
        streamReceiver.reset()
        DiagnosticLogger.shared.log("Connecting to \(host.name)", category: "Connection")
        let conn = NWConnection(to: host.endpoint, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }

        conn.start(queue: .global(qos: .userInteractive))
        receiveNextPacket()
        startQualityMonitor()
        startPathMonitor()
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("Connected to \(self.host.name)")
            DiagnosticLogger.shared.log("TCP connected to \(host.name)", category: "Connection")
            sendAuthRequest()
        case .waiting(let error):
            logger.warning("Connection waiting: \(error)")
            DiagnosticLogger.shared.log("Connection waiting: \(error)", category: "Connection")
        case .failed(let error):
            logger.error("Connection failed: \(error)")
            DiagnosticLogger.shared.log("Connection failed: \(error)", category: "Connection")
            triggerUnexpectedDisconnect()
        case .cancelled:
            Task { @MainActor in appState?.isStreaming = false }
        default:
            break
        }
    }

    // MARK: - Authentication

    private func sendAuthRequest() {
        let secretHex = pairedMac.sharedSecret.map { String(format: "%02x", $0) }.joined()
        let auth = BeamPairingMessage(
            type: .authRequest,
            deviceName: UIDevice.current.name,
            deviceID: KeyStore.shared.stableDeviceID, // must match the ID sent during pairing
            code: nil,
            sharedSecret: secretHex,
            error: nil
        )
        guard let data = try? JSONEncoder().encode(auth) else { return }
        sendTCP(data.lengthPrefixed())
        logger.info("Sent auth request to \(self.host.name)")
    }

    // MARK: - Send Control Commands

    func sendMediaKey(_ key: BeamMediaKeyPayload.Key) {
        let msg = BeamControlMessage(
            type: .mediaKey,
            payload: .mediaKey(BeamMediaKeyPayload(key: key))
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendTCP(data.lengthPrefixed())
    }

    func sendStreamStop() {
        let msg = BeamControlMessage(type: .streamStop, payload: nil)
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendTCP(data.lengthPrefixed())
    }

    /// Sends a binary controller state report (packet type .input).
    /// Unlike JSON control messages, these are framed with a BeamPacketHeader so the
    /// host can cheaply distinguish them from JSON without attempting a decode.
    func sendControllerState(_ state: BeamControllerState, connected: Bool) {
        let payload = state.serialized()
        let header = BeamPacketHeader(
            type: .input,
            flags: connected ? BeamControllerState.connectedFlag : 0,
            payloadLength: UInt32(payload.count)
        )
        var packet = header.serialized()
        packet.append(payload)
        sendTCP(packet.lengthPrefixed())
    }

    // MARK: - Disconnect

    func disconnect() {
        guard !isDisconnecting else { return }
        isDisconnecting = true

        qualityTimer?.cancel()
        qualityTimer = nil

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
        connection?.cancel()
        connection = nil
        streamReceiver.reset()
        audioPlayer.stop()
        Task { @MainActor in
            appState?.isStreaming = false
            appState?.connectionQuality = 1.0
            appState?.connectionManager = nil
        }
        logger.info("Disconnected from \(self.host.name)")
    }

    /// Triggers the unexpected-disconnect path: tears down and calls back to allow reconnect.
    private func triggerUnexpectedDisconnect() {
        let callback = onUnexpectedDisconnect
        disconnect()
        callback?()
    }

    // MARK: - Receive Loop

    private func receiveNextPacket() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                logger.error("Receive error: \(error)")
                DiagnosticLogger.shared.log("Receive error: \(error)", category: "Connection")
                self.triggerUnexpectedDisconnect()
                return
            }
            if isComplete {
                DiagnosticLogger.shared.log("Connection closed by remote (isComplete)", category: "Connection")
                self.triggerUnexpectedDisconnect()
                return
            }
            guard let data, data.count == 4 else { return }

            let length = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard length > 0, length < 10_000_000 else {  // sanity check
                self.receiveNextPacket()
                return
            }

            self.connection?.receive(
                minimumIncompleteLength: Int(length),
                maximumLength: Int(length)
            ) { [weak self] payload, _, isComplete, error in
                guard let self else { return }
                if let error {
                    logger.error("Payload receive error: \(error)")
                    DiagnosticLogger.shared.log("Payload receive error: \(error)", category: "Connection")
                    self.triggerUnexpectedDisconnect()
                    return
                }
                if isComplete {
                    DiagnosticLogger.shared.log("Connection closed by remote during payload read", category: "Connection")
                    self.triggerUnexpectedDisconnect()
                    return
                }
                guard let payload else { return }
                self.handleIncomingPacket(payload)
                self.receiveNextPacket()
            }
        }
    }

    private func handleIncomingPacket(_ data: Data) {
        lastPacketReceivedAt = Date()
        guard let header = BeamPacketHeader.parse(from: data) else { return }
        let payload = data.dropFirst(BeamPacketHeader.size)

        switch header.type {
        case .video, .videoIDR:
            lastMediaPacketReceivedAt = Date()
            streamReceiver.receive(videoPayload: Data(payload), isKeyframe: header.type == .videoIDR)

        case .spsPps:
            streamReceiver.receiveParameterSets(Data(payload))

        case .audio:
            lastMediaPacketReceivedAt = Date()
            streamReceiver.receive(audioPayload: Data(payload), player: audioPlayer)

        case .control:
            if let msg = try? JSONDecoder().decode(BeamPairingMessage.self, from: payload) {
                handlePairingMessage(msg)
            } else if let msg = try? JSONDecoder().decode(BeamControlMessage.self, from: payload) {
                handleControlMessage(msg)
            }

        case .heartbeat:
            // Send pong back
            let pong = BeamControlMessage(type: .pong, payload: nil)
            if let pongData = try? JSONEncoder().encode(pong) {
                sendTCP(pongData.lengthPrefixed())
            }

        case .input:
            break  // outbound-only (iOS → macOS); the host never sends input packets
        }
    }

    private func handleControlMessage(_ msg: BeamControlMessage) {
        switch msg.type {
        case .qualityChanged:
            if case .qualityChanged(let payload) = msg.payload {
                Task { @MainActor in
                    self.appState?.currentQualityPreset = payload.preset
                }
            } else if case .qualityRequest(let payload) = msg.payload {
                // BeamControlPayload decoding is shape-based; qualityChanged currently decodes
                // to .qualityRequest because both carry BeamQualityPayload.
                Task { @MainActor in
                    self.appState?.currentQualityPreset = payload.preset
                }
            }
        case .audioFormatChanged:
            if case .audioFormat(let payload) = msg.payload {
                audioPlayer.updateRemoteFormat(sampleRate: payload.sampleRate, channels: payload.channels)
            }
        case .qualityRequest:
            break  // iOS doesn't receive quality requests from host
        default:
            break
        }
    }

    private func handlePairingMessage(_ msg: BeamPairingMessage) {
        switch msg.type {
        case .authSuccess:
            logger.info("Authenticated with \(self.host.name), stream starting")
            DiagnosticLogger.shared.log("Auth success, stream starting", category: "Connection")
            streamStartedAt = Date()
            // Refresh the host's remote (Tailscale) addresses on every successful auth, not
            // just at pairing — this is how the stored copy stays correct if the Mac's tailnet
            // address changes (BEAM-19). Runs while we're on the LAN, so away-from-home works
            // later without the user configuring anything.
            Task { @MainActor in appState?.updateRemoteHosts(msg.tailscaleHosts) }
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
            // Gated on the remote feature flag (BEAM-18): while locked we never attach to
            // GCController and never emit .input packets, so the feature is fully inert in
            // builds that ship before the Mac half is live.
            if FeatureFlags.isUnlocked(.controllerPassthrough) {
                controllerInput.onConnectionChange = { [weak self] connected in
                    Task { @MainActor in
                        self?.appState?.isControllerConnected = connected
                    }
                }
                controllerInput.start(connectionManager: self)
            }
            // Send our quality preference to the host immediately after auth.
            //
            // Over a remote (Tailscale) path we cap it. The presets and the host's auto tiers
            // are tuned for LAN bandwidth, so `auto` opens at 1080p30/6 Mbps and only walks
            // down after the feedback loop has already produced visible buffering. On cellular
            // or a DERP-relayed tailnet that first guess is far too optimistic, so we start
            // conservative and let the host adapt upward if the link turns out to be good.
            var preferred = appState?.preferredQualityPreset ?? .auto
            if appState?.usingRemoteHost == true, preferred == .auto {
                // Enter the ladder at 480p30 rather than auto's 1080p30 opening guess, then
                // climb. Being briefly too soft is recoverable; opening too hot means the user
                // watches it buffer before adaptation catches up, which is what they notice.
                ladderIndex = Self.ladder.firstIndex(of: .p480_30) ?? 1
                preferred = Self.ladder[ladderIndex!]
                DiagnosticLogger.shared.log(
                    "Remote path: starting ladder at \(preferred.rawValue)",
                    category: "Quality"
                )
            }
            sendQualityRequest(preferred)
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

    private static let ladder: [StreamQualityPreset] = [.p360_30, .p480_30, .p720_30, .p1080_30, .p1080_60]
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
              appState?.preferredQualityPreset == .auto,
              var index = ladderIndex else { return }

        if quality >= 0.95 {
            goodTicks += 1
            guard goodTicks >= Self.ticksPerStepUp, index < Self.ladder.count - 1 else { return }
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
        let msg = BeamControlMessage(
            type: .qualityFeedback,
            payload: .qualityFeedback(BeamQualityFeedbackPayload(quality: quality))
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendTCP(data.lengthPrefixed())
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

    func sendQualityRequest(_ preset: StreamQualityPreset) {
        let msg = BeamControlMessage(
            type: .qualityRequest,
            payload: .qualityRequest(BeamQualityPayload(preset: preset))
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendTCP(data.lengthPrefixed())
    }

    func sendViewportLock(_ normalizedRect: CGRect?) {
        let payload: BeamViewportLockPayload
        if let normalizedRect {
            payload = BeamViewportLockPayload(
                locked: true,
                x: normalizedRect.origin.x,
                y: normalizedRect.origin.y,
                width: normalizedRect.width,
                height: normalizedRect.height
            )
        } else {
            payload = BeamViewportLockPayload(locked: false, x: 0, y: 0, width: 1, height: 1)
        }

        let msg = BeamControlMessage(
            type: .viewportLockRequest,
            payload: .viewportLock(payload)
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendTCP(data.lengthPrefixed())
    }

    // MARK: - TCP Send

    private func sendTCP(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                logger.error("Send error: \(error)")
                self?.disconnect()
            }
        })
    }
}
