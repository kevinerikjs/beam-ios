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

    /// Whether a physical game controller is paired to the phone and being forwarded to the host.
    @Published var isControllerConnected: Bool = false

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

    // Auto-reconnect state
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private let maxReconnectAttempts = 4

    // Widget quick-start: set when app is opened via beam://start
    private var pendingAutoStart = false

    // MARK: - Init

    init() {
        pairedMac = KeyStore.shared.loadPairedMac()

        // Cold-launch widget tap: AppDelegate stashes this flag before we init.
        // Consume it now so startBrowsing() auto-streams when the Mac is found.
        if UserDefaults.standard.bool(forKey: "beam.pendingAutoStart") {
            UserDefaults.standard.removeObject(forKey: "beam.pendingAutoStart")
            pendingAutoStart = true
        }

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
                if self?.pendingAutoStart == true {
                    self?.pendingAutoStart = false
                    await self?.startStream()
                }
            }
        }
    }

    /// Called when the app is opened via beam://start (widget tap).
    /// If the Mac is already found, starts immediately; otherwise waits for Bonjour.
    @MainActor
    func requestAutoStart() {
        guard pairedMac != nil else { return }
        if discoveredHost != nil {
            Task { await startStream() }
        } else {
            pendingAutoStart = true
            startBrowsing()
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
        manager.onUnexpectedDisconnect = { [weak self] in
            self?.scheduleReconnect()
        }
        self.connectionManager = manager
        await manager.connect()
    }

    @MainActor
    func stopStream() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        // Nil the callback BEFORE disconnect() so the receive-loop race can't
        // fire triggerUnexpectedDisconnect → scheduleReconnect after a manual stop.
        connectionManager?.onUnexpectedDisconnect = nil
        connectionManager?.disconnect()
        connectionManager = nil
        isStreaming = false
        let keepLock = UserDefaults.standard.object(forKey: "beam.keepViewportLock") as? Bool ?? true
        if !keepLock { lockedViewportRect = nil }
    }

    /// Schedules a reconnect attempt with exponential backoff (1s, 3s, 9s, 27s).
    /// Called from ConnectionManager when an unexpected disconnect occurs.
    private func scheduleReconnect() {
        guard reconnectAttempt < maxReconnectAttempts else {
            DiagnosticLogger.shared.log("Max reconnect attempts reached, giving up", category: "Reconnect")
            reconnectAttempt = 0
            return
        }
        guard discoveredHost != nil, pairedMac != nil else {
            reconnectAttempt = 0
            return
        }
        let attempt = reconnectAttempt
        let delay: UInt64 = [1, 3, 9, 27][min(attempt, 3)]
        reconnectAttempt += 1
        DiagnosticLogger.shared.log("Scheduling reconnect attempt \(reconnectAttempt)/\(maxReconnectAttempts) in \(delay)s", category: "Reconnect")

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, !self.isStreaming else { return }
            DiagnosticLogger.shared.log("Reconnect attempt \(self.reconnectAttempt)", category: "Reconnect")
            await self.startStream()
        }
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
