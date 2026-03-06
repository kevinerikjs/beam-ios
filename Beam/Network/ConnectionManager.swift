// ConnectionManager.swift
// Manages the TCP connection lifecycle from iOS to macOS.
// Handles authentication, receives stream packets, and dispatches to StreamReceiver.

import Network
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "ConnectionManager")

@Observable
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
    private let controlInactivityTimeout: TimeInterval = 12
    private let mediaInactivityTimeout: TimeInterval = 6

    // Post-auth media watchdog — detects wedged host pipeline (auth succeeded, no media flows)
    private var postAuthWatchdog: DispatchSourceTimer?
    private var hasReceivedFirstMedia = false
    /// True while we're silently reconnecting due to a wedged stream (suppresses connectionManager teardown).
    private var isAutoReconnecting = false
    /// Prevents infinite auto-reconnect loops — only one silent retry per ConnectionManager lifetime.
    private var autoReconnectAttempted = false

    init(host: DiscoveredHost, pairedMac: PairedMac, appState: BeamAppState) {
        self.host = host
        self.pairedMac = pairedMac
        self.appState = appState
        self.streamReceiver.audioPlayer = self.audioPlayer
    }

    // MARK: - Connect

    @MainActor
    func connect(isAutoReconnect: Bool = false) async {
        isDisconnecting = false
        hasReceivedFirstMedia = false
        if !isAutoReconnect { autoReconnectAttempted = false }
        lastPacketReceivedAt = Date()
        lastMediaPacketReceivedAt = Date()
        streamReceiver.reset()
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
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("Connected to \(self.host.name)")
            sendAuthRequest()
        case .waiting(let error):
            logger.warning("Connection waiting: \(error)")
        case .failed(let error):
            logger.error("Connection failed: \(error)")
            disconnect()
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

        cancelPostAuthWatchdog()
        qualityTimer?.cancel()
        qualityTimer = nil
        SessionManager.shared.stopSession()
        sendStreamStop()
        connection?.cancel()
        connection = nil
        streamReceiver.reset()
        audioPlayer.stop()
        let autoReconnecting = isAutoReconnecting
        Task { @MainActor in
            appState?.isStreaming = false
            appState?.connectionQuality = 1.0
            // Keep connectionManager alive during silent auto-reconnect so we can reuse it
            if !autoReconnecting {
                appState?.connectionManager = nil
            }
        }
        logger.info("Disconnected from \(self.host.name)")
    }

    // MARK: - Receive Loop

    private func receiveNextPacket() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { logger.error("Receive error: \(error)"); self.disconnect(); return }
            if isComplete { self.disconnect(); return }
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
                if let error { logger.error("Payload receive error: \(error)"); self.disconnect(); return }
                if isComplete { self.disconnect(); return }
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
            if !hasReceivedFirstMedia { hasReceivedFirstMedia = true; cancelPostAuthWatchdog() }
            streamReceiver.receive(videoPayload: Data(payload), isKeyframe: header.type == .videoIDR)

        case .spsPps:
            streamReceiver.receiveParameterSets(Data(payload))

        case .audio:
            lastMediaPacketReceivedAt = Date()
            if !hasReceivedFirstMedia { hasReceivedFirstMedia = true; cancelPostAuthWatchdog() }
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
            // Record first stream to start the 3-day free trial clock (no-op after first time)
            SessionManager.shared.recordFirstStream()
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
            // Re-apply any viewport lock from the previous session
            if let rect = appState?.lockedViewportRect {
                sendViewportLock(rect)
            }
            // Watchdog: if the host pipeline is wedged, no media will arrive despite a
            // successful auth. Detect this and silently reconnect once.
            startPostAuthWatchdog()

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
            if controlElapsed >= controlInactivityTimeout {
                logger.warning("No packets for \(controlElapsed, format: .fixed(precision: 1))s, disconnecting")
                self.disconnect()
                return
            }
            if mediaElapsed >= mediaInactivityTimeout {
                logger.warning("No media packets for \(mediaElapsed, format: .fixed(precision: 1))s, disconnecting stalled stream")
                self.disconnect()
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

    // MARK: - Post-Auth Watchdog

    private func startPostAuthWatchdog() {
        cancelPostAuthWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { [weak self] in
            guard let self, !hasReceivedFirstMedia else { return }
            postAuthWatchdog = nil
            logger.warning("No media received 5s after auth — host pipeline may be wedged, attempting silent reconnect")
            Task { @MainActor in self.handleWedgedStream() }
        }
        timer.resume()
        postAuthWatchdog = timer
    }

    private func cancelPostAuthWatchdog() {
        postAuthWatchdog?.cancel()
        postAuthWatchdog = nil
    }

    /// Called when auth succeeded but no media arrived — silently reconnects once.
    /// On the second failure the user is returned to the home screen normally.
    @MainActor
    private func handleWedgedStream() {
        guard !autoReconnectAttempted else {
            logger.error("Stream still wedged after auto-reconnect — giving up, returning to home")
            isAutoReconnecting = false
            disconnect()
            return
        }
        guard !isDisconnecting else { return }
        autoReconnectAttempted = true
        isAutoReconnecting = true
        logger.info("Wedged stream — disconnecting and reconnecting in 1.5s")
        disconnect()
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.5))
            isAutoReconnecting = false
            // Only proceed if we're still the active connection manager
            guard appState?.connectionManager === self, appState?.pairedMac != nil else { return }
            await connect(isAutoReconnect: true)
        }
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
