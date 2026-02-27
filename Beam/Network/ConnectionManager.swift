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

    // Stream components
    let streamReceiver = StreamReceiver()
    let audioPlayer = AudioPlayer()

    private var receiveBuffer = Data()

    // Connection quality tracking
    private var lastPacketReceivedAt: Date = Date()
    private var qualityTimer: DispatchSourceTimer?

    init(host: DiscoveredHost, pairedMac: PairedMac, appState: BeamAppState) {
        self.host = host
        self.pairedMac = pairedMac
        self.appState = appState
    }

    // MARK: - Connect

    @MainActor
    func connect() async {
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
        qualityTimer?.cancel()
        qualityTimer = nil
        sendStreamStop()
        connection?.cancel()
        connection = nil
        audioPlayer.stop()
        Task { @MainActor in
            appState?.isStreaming = false
            appState?.connectionQuality = 1.0
            appState?.connectionManager = nil
        }
        logger.info("Disconnected from \(self.host.name)")
    }

    // MARK: - Receive Loop

    private func receiveNextPacket() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { logger.error("Receive error: \(error)"); return }
            guard let data, data.count == 4 else { return }

            let length = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard length > 0, length < 10_000_000 else {  // sanity check
                self.receiveNextPacket()
                return
            }

            self.connection?.receive(
                minimumIncompleteLength: Int(length),
                maximumLength: Int(length)
            ) { [weak self] payload, _, _, error in
                guard let self else { return }
                if let error { logger.error("Payload receive error: \(error)"); return }
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
            streamReceiver.receive(videoPayload: Data(payload), isKeyframe: header.type == .videoIDR)

        case .spsPps:
            streamReceiver.receiveParameterSets(Data(payload))

        case .audio:
            streamReceiver.receive(audioPayload: Data(payload), player: audioPlayer)

        case .control:
            if let msg = try? JSONDecoder().decode(BeamPairingMessage.self, from: payload) {
                handlePairingMessage(msg)
            }

        case .heartbeat:
            // Send pong back
            let pong = BeamControlMessage(type: .pong, payload: nil)
            if let pongData = try? JSONEncoder().encode(pong) {
                sendTCP(pongData.lengthPrefixed())
            }
        }
    }

    private func handlePairingMessage(_ msg: BeamPairingMessage) {
        switch msg.type {
        case .authSuccess:
            logger.info("Authenticated with \(self.host.name), stream starting")
            Task { @MainActor in
                appState?.isStreaming = true
                // Start free tier timer if not purchased
                if !(appState?.isPurchased ?? false) {
                    SessionManager.shared.startSession()
                }
            }
            audioPlayer.start()

        case .authFailed:
            logger.error("Auth failed: \(msg.error ?? "unknown")")
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
            let elapsed = Date().timeIntervalSince(lastPacketReceivedAt)
            let quality: Double
            switch elapsed {
            case ..<0.3:  quality = 1.00
            case ..<0.8:  quality = 0.75
            case ..<1.5:  quality = 0.50
            default:      quality = 0.25
            }
            Task { @MainActor in
                self.appState?.connectionQuality = quality
            }
        }
        timer.resume()
        qualityTimer = timer
    }

    // MARK: - TCP Send

    private func sendTCP(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error { logger.error("Send error: \(error)") }
        })
    }
}
