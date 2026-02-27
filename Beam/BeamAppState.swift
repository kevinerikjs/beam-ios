// BeamAppState.swift
// Central observable state for the iOS Beam client app.

import SwiftUI
import Network

@Observable
final class BeamAppState {

    // MARK: - Onboarding / Pairing

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// The Mac this iPhone is paired with, if any.
    var pairedMac: PairedMac? = nil

    // MARK: - Connection

    /// Whether a stream is currently active (receiving and displaying video).
    var isStreaming: Bool = false

    /// The discovered Mac on the local network (Bonjour found it, not yet connected).
    var discoveredHost: DiscoveredHost? = nil

    /// Whether the app is actively looking for the paired Mac on the network.
    var isSearchingForMac: Bool = false

    /// Connection quality (0.0 - 1.0), updated from packet stats.
    var connectionQuality: Double = 1.0

    // MARK: - Purchase State

    /// Whether the user has purchased the unlimited tier.
    var isPurchased: Bool {
        get { StoreManager.shared.isPurchased }
    }

    // MARK: - Free Tier

    var sessionManager = SessionManager.shared

    // MARK: - Managers

    let bonjourBrowser = BonjourBrowser()
    var connectionManager: ConnectionManager?

    // MARK: - Init

    init() {
        pairedMac = KeyStore.shared.loadPairedMac()

        // Start browsing for the paired Mac right away
        if pairedMac != nil {
            startBrowsing()
        }
    }

    // MARK: - Browsing

    func startBrowsing() {
        isSearchingForMac = true
        bonjourBrowser.startBrowsing { [weak self] host in
            Task { @MainActor in
                self?.discoveredHost = host
                self?.isSearchingForMac = false
            }
        }
    }

    func stopBrowsing() {
        bonjourBrowser.stopBrowsing()
        isSearchingForMac = false
    }

    // MARK: - Streaming

    @MainActor
    func startStream() async {
        guard let host = discoveredHost, let mac = pairedMac else { return }

        let manager = ConnectionManager(host: host, pairedMac: mac, appState: self)
        self.connectionManager = manager
        await manager.connect()
    }

    @MainActor
    func stopStream() {
        connectionManager?.disconnect()
        connectionManager = nil
        isStreaming = false
    }
}

// MARK: - Supporting Types

struct PairedMac: Codable {
    let id: String        // UUID string matching the macOS app's device ID for this iPhone
    let name: String      // e.g. "Kevin's MacBook Pro"
    let sharedSecret: Data
    var lastConnected: Date
}

struct DiscoveredHost: Equatable {
    let name: String
    let endpoint: NWEndpoint
    let port: UInt16
}
