// PairingManager.swift
// iOS-side pairing flow: connect, say hello, show the code prompt, send the typed code,
// store the secret. The protocol side is PhorosSession (ClientCapabilities, PairingClient);
// the transport is PhorosNetwork. What stays here is UI state, the Keychain and analytics.

import Network
import OSLog
import Phoros
import PhorosNetwork
import PhorosSession
import SwiftUI

private let logger = Logger(subsystem: "com.beam.ios", category: "PairingManager")

final class PairingManager: ObservableObject {

    static let shared = PairingManager()

    // MARK: - State

    @Published var isPairing: Bool = false
    @Published var isAwaitingCodeEntry: Bool = false
    @Published var pairingError: String? = nil
    @Published var isPairSuccess: Bool = false

    private var link: PhorosConnection?
    private var pairingHost: DiscoveredHost?

    private init() {}

    /// What this phone tells the Mac it can do during pairing.
    private var capabilities: ClientCapabilities {
        ClientCapabilities(
            deviceName: UIDevice.current.name,
            deviceID: KeyStore.shared.stableDeviceID,
            audioCodecs: AudioCodecID.clientAdvertisedCodecs().compactMap(AudioCodecID.init(wireName:)),
            videoCodecs: VideoCodecID.clientAdvertisedCodecs().compactMap(VideoCodecID.init(wireName:))
        )
    }

    // MARK: - Start Pairing

    func startPairing(with host: DiscoveredHost) {
        guard !isPairing else { return }
        isPairing = true
        pairingError = nil
        isPairSuccess = false
        pairingHost = host

        let link = PhorosConnection(to: host.endpoint, queue: .global(qos: .userInitiated))
        self.link = link
        link.onReady = { [weak self] in
            guard let self else { return }
            self.send(self.capabilities.hello())
            logger.info("Sent hello to Mac")
        }
        link.onFrame = { [weak self] frame in
            // The Mac wraps its replies in a .control packet; either form decodes the same.
            let json: Data
            switch frame {
            case .packet(let packet): json = packet.payload
            case .message(let data): json = data
            }
            guard let message = try? JSONDecoder().decode(PairingMessage.self, from: json) else { return }
            self?.handle(message)
        }
        link.onEnd = { [weak self] reason in
            switch reason {
            case .transportFailed(let error): self?.pairingFailed(error.localizedDescription)
            case .closedByPeer, .protocolViolation: self?.pairingFailed("The Mac closed the connection")
            case .cancelled: break
            }
        }
        link.start()
    }

    func cancelPairing() {
        link?.cancel()
        link = nil
        isPairing = false
        isAwaitingCodeEntry = false
        pairingError = nil
    }

    // MARK: - Code Submission

    /// Called when the user enters the 6-digit code displayed on the Mac.
    func submitCode(_ code: String) {
        guard isAwaitingCodeEntry else { return }
        send(capabilities.codeVerify(code))
        isAwaitingCodeEntry = false
    }

    // MARK: - Host replies

    private func handle(_ message: PairingMessage) {
        switch PairingClient.interpret(message) {
        case .codeRequested(let hostName):
            logger.info("Received challenge from Mac '\(hostName ?? "")'")
            Task { @MainActor in self.isAwaitingCodeEntry = true }

        case .paired(let secret, let host, let hostName):
            guard let macName = hostName else {
                pairingFailed("Pair success message missing the Mac's name")
                return
            }
            let mac = PairedMac(
                id: KeyStore.shared.stableDeviceID,
                name: macName,
                sharedSecret: secret.bytes,
                lastConnected: Date(),
                // Captured at pair time so away-from-home streaming works later with no setup
                // step (BEAM-19). Empty when the Mac has no Tailscale — the user can still add
                // an address by hand from settings.
                remoteHosts: host.remoteHosts.isEmpty ? nil : host.remoteHosts,
                manualRemoteHost: nil,
                hostSupportsRemoteAccess: host.supportsRemoteAccess
            )
            let isFirstPairing = !UserDefaults.standard.bool(forKey: "hasEverPaired")
            KeyStore.shared.savePairedMac(mac)
            if isFirstPairing {
                UserDefaults.standard.set(true, forKey: "hasEverPaired")
                Analytics.track("first_pair_completed")
            }
            logger.info("Paired successfully with '\(macName)'")
            Task { @MainActor in
                self.isPairSuccess = true
                self.isPairing = false
            }
            link?.cancel()
            link = nil

        case .failed(let reason):
            pairingFailed(reason)

        case .authenticated, .unpaired, .unexpected:
            break
        }
    }

    private func send(_ message: PairingMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        link?.send(data)
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
