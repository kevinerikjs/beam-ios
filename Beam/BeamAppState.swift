// BeamAppState.swift
// Central observable state for the iOS Beam client app.

import SwiftUI
import Network

final class BeamAppState: ObservableObject {

    // MARK: - Onboarding / Pairing

    @Published var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    /// The Mac this iPhone is paired with, if any.
    @Published var pairedMac: PairedMac? = nil

    // MARK: - Connection

    /// Whether a stream is currently active (receiving and displaying video).
    @Published var isStreaming: Bool = false

    /// The discovered Mac on the local network (Bonjour found it, not yet connected).
    @Published var discoveredHost: DiscoveredHost? = nil

    /// All Beacon instances currently visible on the network (used by pairing picker).
    @Published var discoveredHosts: [DiscoveredHost] = []

    /// Whether the app is actively looking for the paired Mac on the network.
    @Published var isSearchingForMac: Bool = false

    /// Connection quality (0.0 - 1.0), updated from packet stats.
    @Published var connectionQuality: Double = 1.0

    /// The quality preset currently active on the host (set from .qualityChanged messages).
    @Published var currentQualityPreset: StreamQualityPreset = .p1080_30

    /// The user's preferred quality preset (persisted, sent to host on connect).
    var preferredQualityPreset: StreamQualityPreset {
        get {
            let raw = UserDefaults.standard.string(forKey: "preferredQualityPreset") ?? ""
            return StreamQualityPreset(rawValue: raw) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preferredQualityPreset")
            connectionManager?.sendQualityRequest(newValue)
        }
    }

    // MARK: - Purchase State

    /// Whether the user has purchased the unlimited tier.
    var isPurchased: Bool {
        get { StoreManager.shared.isPurchased }
    }

    // MARK: - Free Tier

    var sessionManager = SessionManager.shared

    // MARK: - Viewport Lock

    /// Last viewport lock rect sent to the host.
    /// Persisted to UserDefaults so it survives app restarts — the host keeps the lock
    /// on its end, and on next authSuccess ConnectionManager re-sends it automatically.
    @Published var lockedViewportRect: CGRect? = {
        guard let str = UserDefaults.standard.string(forKey: "lockedViewportRect") else { return nil }
        let r = NSCoder.cgRect(for: str)
        return r.width > 0 ? r : nil
    }() {
        didSet {
            if let r = lockedViewportRect {
                UserDefaults.standard.set(NSCoder.string(for: r), forKey: "lockedViewportRect")
            } else {
                UserDefaults.standard.removeObject(forKey: "lockedViewportRect")
            }
        }
    }

    // MARK: - Managers

    let bonjourBrowser = BonjourBrowser()
    @Published var connectionManager: ConnectionManager?

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

    /// Used by PairingView — collects all visible Beacons into discoveredHosts.
    func startBrowsingForPairing() {
        isSearchingForMac = true
        discoveredHosts = []
        bonjourBrowser.startBrowsing { [weak self] hosts in
            Task { @MainActor in
                self?.discoveredHosts = hosts
                self?.isSearchingForMac = hosts.isEmpty
            }
        }
    }

    func stopBrowsing() {
        bonjourBrowser.stopBrowsing()
        isSearchingForMac = false
        discoveredHosts = []
    }

    // MARK: - Streaming

    @MainActor
    func startStream() async {
        guard let host = discoveredHost, let mac = pairedMac else { return }
        guard isPurchased || sessionManager.isInTrial || !sessionManager.isInCooldown else { return }

        connectionManager?.disconnect()
        let manager = ConnectionManager(host: host, pairedMac: mac, appState: self)
        self.connectionManager = manager
        await manager.connect()
    }

    @MainActor
    func stopStream() {
        connectionManager?.disconnect()
        connectionManager = nil
        isStreaming = false
        let keepLock = UserDefaults.standard.object(forKey: "beam.keepViewportLock") as? Bool ?? true
        if !keepLock { lockedViewportRect = nil }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        connectionManager?.performForegroundHealthCheck()
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
