// PairingManager.swift
// iOS-side pairing flow.
// Sends "hello" to the Mac, receives the challenge, sends code_verify, stores shared secret.

import SwiftUI
import CryptoKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "PairingManager")

@Observable
final class PairingManager {

    static let shared = PairingManager()

    // MARK: - State

    var isPairing: Bool = false
    var isAwaitingCodeEntry: Bool = false
    var pairingError: String? = nil
    var isPairSuccess: Bool = false

    private var connection: PairingConnection?
    private var pairingHost: DiscoveredHost?

    private init() {}

    // MARK: - Start Pairing

    func startPairing(with host: DiscoveredHost) {
        guard !isPairing else { return }
        isPairing = true
        pairingError = nil
        isPairSuccess = false
        pairingHost = host

        connection = PairingConnection(host: host, delegate: self)
        connection?.connect()
    }

    func cancelPairing() {
        connection?.disconnect()
        connection = nil
        isPairing = false
        isAwaitingCodeEntry = false
        pairingError = nil
    }

    // MARK: - Code Submission

    /// Called when the user enters the 6-digit code displayed on the Mac.
    func submitCode(_ code: String) {
        guard isAwaitingCodeEntry else { return }
        connection?.sendCodeVerify(code)
        isAwaitingCodeEntry = false
    }
}

// MARK: - PairingConnectionDelegate

extension PairingManager: PairingConnectionDelegate {

    func pairingConnectionReady(_ connection: PairingConnection) {
        // Send hello with our device identity
        let hello = BeamPairingMessage(
            type: .hello,
            deviceName: UIDevice.current.name,
            deviceID: KeyStore.shared.stableDeviceID,
            code: nil,
            sharedSecret: nil,
            error: nil
        )
        connection.send(hello)
        logger.info("Sent hello to Mac")
    }

    func pairingConnection(_ connection: PairingConnection, didReceive message: BeamPairingMessage) {
        switch message.type {
        case .challenge:
            // Mac acknowledged our hello - show code entry UI
            logger.info("Received challenge from Mac '\(message.deviceName ?? "")'")
            Task { @MainActor in
                self.isAwaitingCodeEntry = true
            }

        case .pairSuccess:
            guard let secretHex = message.sharedSecret,
                  let secretData = Data(hexEncoded: secretHex),
                  let macName = message.deviceName else {
                pairingFailed("Pair success message missing required fields")
                return
            }
            let mac = PairedMac(
                id: KeyStore.shared.stableDeviceID,
                name: macName,
                sharedSecret: secretData,
                lastConnected: Date()
            )
            let isFirstPairing = KeyStore.shared.loadPairedMac() == nil
            KeyStore.shared.savePairedMac(mac)
            if isFirstPairing { Analytics.track("first_pair_completed") }
            logger.info("Paired successfully with '\(macName)'")
            Task { @MainActor in
                self.isPairSuccess = true
                self.isPairing = false
            }
            connection.disconnect()

        case .pairFailed:
            pairingFailed(message.error ?? "Pairing failed")

        default:
            break
        }
    }

    func pairingConnectionFailed(_ connection: PairingConnection, error: Error) {
        pairingFailed(error.localizedDescription)
    }

    private func pairingFailed(_ reason: String) {
        logger.error("Pairing failed: \(reason)")
        Task { @MainActor in
            self.pairingError = reason
            self.isPairing = false
            self.isAwaitingCodeEntry = false
        }
    }
}

// MARK: - PairingConnection

protocol PairingConnectionDelegate: AnyObject {
    func pairingConnectionReady(_ connection: PairingConnection)
    func pairingConnection(_ connection: PairingConnection, didReceive message: BeamPairingMessage)
    func pairingConnectionFailed(_ connection: PairingConnection, error: Error)
}

final class PairingConnection {
    private let host: DiscoveredHost
    weak var delegate: PairingConnectionDelegate?
    private var connection: NWConnection?

    init(host: DiscoveredHost, delegate: PairingConnectionDelegate) {
        self.host = host
        self.delegate = delegate
    }

    func connect() {
        let conn = NWConnection(to: host.endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.delegate?.pairingConnectionReady(self)
                self.receiveNext()
            case .failed(let error):
                self.delegate?.pairingConnectionFailed(self, error: error)
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        connection = conn
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    func send(_ message: BeamPairingMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        connection?.send(content: data.lengthPrefixed(), completion: .contentProcessed { _ in })
    }

    func sendCodeVerify(_ code: String) {
        let msg = BeamPairingMessage(
            type: .codeVerify,
            deviceName: nil,
            deviceID: KeyStore.shared.stableDeviceID,
            code: code,
            sharedSecret: nil,
            error: nil
        )
        send(msg)
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, _ in
            guard let self, let data, data.count == 4 else { return }
            let length = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            self.connection?.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payload, _, _, _ in
                guard let self, let payload else { return }
                // macOS wraps all outgoing messages in a BeamPacketHeader — strip it before JSON decoding
                let jsonData: Data
                if let header = BeamPacketHeader.parse(from: payload), header.type == .control {
                    jsonData = Data(payload.dropFirst(BeamPacketHeader.size))
                } else {
                    jsonData = payload
                }
                if let msg = try? JSONDecoder().decode(BeamPairingMessage.self, from: jsonData) {
                    self.delegate?.pairingConnection(self, didReceive: msg)
                }
                self.receiveNext()
            }
        }
    }
}

import Network
