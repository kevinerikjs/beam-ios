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
            // Send our quality preference to the host immediately after auth
            let preferred = appState?.preferredQualityPreset ?? .auto
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
        }
        timer.resume()
        qualityTimer = timer
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
