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

    /// Quality used when the Mac is reached over a remote (Tailscale) path, kept separate
    /// from the LAN preference. Remote links are far more variable than a home network, so a
    /// setting that is right at home is usually wrong away from it — and having one control
    /// serve both meant every trip changed the value you came home to.
    /// Defaults to 720p30, which is a realistic ceiling for cellular and relayed tailnets.
    var remoteQualityPreset: StreamQualityPreset {
        get {
            let raw = UserDefaults.standard.string(forKey: "remoteQualityPreset") ?? ""
            return StreamQualityPreset(rawValue: raw) ?? .p720_30
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "remoteQualityPreset")
            objectWillChange.send()
            if usingRemoteHost { connectionManager?.sendQualityRequest(newValue) }
        }
    }

    /// The user's preferred quality preset on the local network (persisted, sent on connect).
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

    // MARK: - Remote (Tailscale) fallback — BEAM-19

    /// Beacon's listening port is fixed, so a remote endpoint needs no discovery.
    /// Keep in sync with beam-macos `StreamServer.listeningPort`.
    static let remotePort: UInt16 = 7979

    /// How long Bonjour gets before we try a stored remote address. Long enough that a
    /// normal LAN launch never falls back, short enough not to feel broken when away.
    static let remoteFallbackGrace: TimeInterval = 3.0

    /// True when the current host came from a stored remote address rather than Bonjour.
    /// Used by the UI to explain the connection and to pick conservative quality defaults.
    @Published var usingRemoteHost: Bool = false

    /// Smoothed round-trip time on the control channel, nil until the first pong.
    @Published var linkRTT: TimeInterval?

    // MARK: - Reconnect overlay (BEAM-24)
    //
    // A dropped stream used to dump the user straight back to the home screen, which is a
    // jarring way to present something that usually resolves itself in a second or two —
    // especially on a WiFi/Tailscale handover, where the connection is being renegotiated
    // rather than lost. The stream view now stays mounted over the last frame while we retry.

    /// True while we are retrying a dropped connection and holding the stream view open.
    @Published var isReconnecting = false

    /// When the current reconnect window expires. Past this we give up, return to the home
    /// screen, and stop retrying rather than looping forever.
    private var reconnectDeadline: Date?

    /// Enforces the hold window independently of the connection's own callbacks.
    ///
    /// Necessary because NWConnection parks in `.waiting` when there is no route (WiFi off)
    /// and never transitions to `.failed`. Nothing calls back, so a deadline checked only on
    /// re-entry into scheduleReconnect is never evaluated: the overlay would stay up forever
    /// with no retry and no way out. This timer is the one thing guaranteed to fire.
    private var reconnectWatchdog: Task<Void, Never>?

    /// How long the stream is held open across a drop before giving up.
    static let reconnectHoldWindow: TimeInterval = 20

    /// How good the remote link actually is. Only meaningful when `usingRemoteHost`.
    ///
    /// Tailscale always starts a session DERP-relayed and upgrades to a direct path in the
    /// background, so a remote stream's first seconds are slow even when it is about to become
    /// fast. Users read that as "the app is broken" rather than "wait a moment", which is why
    /// this is surfaced rather than hidden. Thresholds come from measurement on a real
    /// tailnet: direct IPv6 measured ~110-170ms, DERP-relayed measured ~2200ms under load.
    enum RemoteLinkQuality {
        case connecting   // no RTT sample yet
        case direct       // fast path, full quality is realistic
        case marginal     // ambiguous; likely mid-upgrade
        case relayed      // via DERP; video will struggle

        var label: String {
            switch self {
            case .connecting: return "Connecting…"
            case .direct:     return "Direct"
            case .marginal:   return "Negotiating…"
            case .relayed:    return "Relayed"
            }
        }
    }

    var remoteLinkQuality: RemoteLinkQuality {
        guard let rtt = linkRTT else { return .connecting }
        if rtt < 0.25 { return .direct }
        if rtt < 0.6 { return .marginal }
        return .relayed
    }

    private var remoteFallbackTask: Task<Void, Never>?
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
        remoteFallbackTask?.cancel()

        // Debug escape hatch (BEAM-19): skip Bonjour entirely and go straight to the stored
        // remote address. Lets the Tailscale path be exercised while still on WiFi — the
        // connection genuinely routes over the tailnet, but the phone stays reachable for
        // log capture, which it isn't when actually off-network.
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "beam.debug.forceRemoteHost") {
            Task { @MainActor in activateRemoteHost(reason: "forced by debug setting") }
            return
        }
        #endif

        bonjourBrowser.startBrowsing { [weak self] host in
            Task { @MainActor in
                guard let self else { return }
                // Bonjour won — cancel any pending remote fallback. LAN always wins:
                // it's lower latency and doesn't depend on Tailscale being up.
                self.remoteFallbackTask?.cancel()
                self.remoteFallbackTask = nil
                self.usingRemoteHost = false
                self.discoveredHost = host
                self.isSearchingForMac = false
                if self.pendingAutoStart {
                    self.pendingAutoStart = false
                    await self.startStream()
                }
            }
        }
        Task { @MainActor in scheduleRemoteFallback() }
    }

    /// If Bonjour hasn't produced the paired Mac within the grace period, fall back to a
    /// stored remote address (BEAM-19). mDNS doesn't traverse Tailscale, so off-LAN this is
    /// the only way to reach the host — but we always give the LAN a fair chance first,
    /// because a local hit is faster and doesn't depend on the VPN being connected.
    @MainActor
    private func scheduleRemoteFallback() {
        // This deadline is what guarantees the "Looking for your Mac…" state always ends.
        //
        // It deliberately keys off `isSearchingForMac` rather than `discoveredHost == nil`.
        // Keying off the host was a bug: after a stream ends, `discoveredHost` still holds the
        // endpoint from the previous session, so the deadline bailed out early while Bonjour
        // (off-LAN) never called back — leaving the spinner running forever with no way out
        // but an app restart.
        remoteFallbackTask?.cancel()
        remoteFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.remoteFallbackGrace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Bonjour got there first and already cleared the searching state.
            guard self.isSearchingForMac else { return }

            if let mac = self.pairedMac, !mac.allRemoteHosts.isEmpty {
                self.activateRemoteHost(reason: "Bonjour found nothing in \(Int(Self.remoteFallbackGrace))s")
            } else {
                // Nothing to fall back to. Stop spinning and let the UI say so, rather than
                // implying we're still making progress.
                DiagnosticLogger.shared.log(
                    "Discovery gave up: no Bonjour result and no stored remote address",
                    category: "Discovery"
                )
                self.discoveredHost = nil
                self.usingRemoteHost = false
                self.isSearchingForMac = false
            }
        }
    }

    /// Points discovery at the stored remote address and, if a start was pending, begins the
    /// stream. Endpoint only: we don't probe first, so an unreachable address surfaces through
    /// the normal connection-failure path rather than a second, divergent error route.
    /// Whether this device may use remote (away-from-home) streaming.
    /// Remote is a Beam Unlimited feature; the trial grants it like every other paid feature.
    /// Local streaming is unaffected and stays free forever.
    var canUseRemoteStreaming: Bool {
        isPurchased || sessionManager.isInTrial
    }

    /// Set when discovery had a usable remote address but the user isn't entitled to it,
    /// so the UI can offer the upgrade instead of just saying "not found".
    @Published var remoteBlockedByPaywall = false

    @MainActor
    private func activateRemoteHost(reason: String) {
        guard let mac = pairedMac, let address = mac.allRemoteHosts.first else {
            DiagnosticLogger.shared.log("Remote host requested but none stored", category: "Discovery")
            isSearchingForMac = false
            return
        }
        // Single choke point for every remote path — timed fallback, reconnect escalation and
        // the debug force toggle all land here, so the entitlement check belongs here rather
        // than duplicated at each call site.
        guard canUseRemoteStreaming else {
            DiagnosticLogger.shared.log("Remote host available but requires Unlimited", category: "Discovery")
            remoteBlockedByPaywall = true
            discoveredHost = nil
            usingRemoteHost = false
            isSearchingForMac = false
            return
        }
        remoteBlockedByPaywall = false
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: Self.remotePort) ?? 7979
        )
        DiagnosticLogger.shared.log(
            "Using remote host \(address):\(Self.remotePort) (\(reason))",
            category: "Discovery"
        )
        usingRemoteHost = true
        discoveredHost = DiscoveredHost(name: mac.name, endpoint: endpoint, port: Self.remotePort)
        isSearchingForMac = false
        if pendingAutoStart {
            pendingAutoStart = false
            Task { await startStream() }
        }
    }

    /// Stores the host's self-reported remote addresses. Called on every successful auth so
    /// the stored copy tracks the Mac's current tailnet address.
    @MainActor
    func updateRemoteHosts(_ hosts: [String]?, hostSupportsRemote: Bool? = nil) {
        guard var mac = pairedMac else { return }
        var changed = false
        if let hosts, !hosts.isEmpty, mac.remoteHosts != hosts {
            mac.remoteHosts = hosts
            changed = true
            DiagnosticLogger.shared.log("Remote hosts updated (\(hosts.count))", category: "Discovery")
        }
        // Recorded even when no addresses came back — that combination is exactly how we tell
        // "Mac needs Tailscale" apart from "Mac needs a Beacon update".
        if mac.hostSupportsRemoteAccess != hostSupportsRemote {
            mac.hostSupportsRemoteAccess = hostSupportsRemote
            changed = true
        }
        guard changed else { return }   // no churn on the Keychain
        pairedMac = mac
        KeyStore.shared.savePairedMac(mac)
    }

    // MARK: - One-tap remote setup (BEAM-19)

    /// True while a remote-access setup probe is running.
    @Published var isSettingUpRemoteAccess = false
    /// User-facing result of the last setup attempt; nil when never run or cleared.
    @Published var remoteSetupError: String?

    /// Fetches the Mac's Tailscale address over the LAN and stores it, without starting a
    /// stream. For pairings made before the Mac started advertising its address.
    @MainActor
    func setUpRemoteAccess() async {
        guard let mac = pairedMac, !isSettingUpRemoteAccess else { return }
        isSettingUpRemoteAccess = true
        remoteSetupError = nil
        defer { isSettingUpRemoteAccess = false }

        // Needs a LAN-discovered host: the whole point is that we don't have a remote address
        // yet, so there's nothing else to connect to.
        guard let host = discoveredHost, !usingRemoteHost else {
            remoteSetupError = RemoteSetupProbe.Failure.macNotOnNetwork.errorDescription
            return
        }

        do {
            let hosts = try await RemoteSetupProbe.fetchRemoteHosts(from: host, pairedMac: mac)
            updateRemoteHosts(hosts)
            DiagnosticLogger.shared.log("Remote access set up via probe (\(hosts.count))", category: "Discovery")
        } catch {
            remoteSetupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DiagnosticLogger.shared.log("Remote setup probe failed: \(error)", category: "Discovery")
        }
    }

    /// Sets or clears the hand-entered remote address. Pass nil/empty to clear.
    @MainActor
    func setManualRemoteHost(_ address: String?) {
        guard var mac = pairedMac else { return }
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        mac.manualRemoteHost = (trimmed?.isEmpty ?? true) ? nil : trimmed
        pairedMac = mac
        KeyStore.shared.savePairedMac(mac)
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
        remoteFallbackTask?.cancel()
        remoteFallbackTask = nil
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
    @MainActor
    private func scheduleReconnect() {
        // Open the hold window on the first failure of a run, then keep the stream view up
        // until it expires. Attempts alone are a poor bound because the backoff makes their
        // duration vary wildly; a wall-clock window is what the user actually experiences.
        if reconnectDeadline == nil {
            let deadline = Date().addingTimeInterval(Self.reconnectHoldWindow)
            reconnectDeadline = deadline
            reconnectWatchdog?.cancel()
            reconnectWatchdog = Task { @MainActor [weak self] in
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                guard !Task.isCancelled, let self, self.isReconnecting else { return }
                DiagnosticLogger.shared.log(
                    "Reconnect window expired with no route, returning to home",
                    category: "Reconnect"
                )
                self.endReconnect(resumed: false)
                self.discoveredHost = nil
                self.startBrowsing()
            }
        }
        isReconnecting = true

        let expired = reconnectDeadline.map { Date() >= $0 } ?? false
        guard reconnectAttempt < maxReconnectAttempts, !expired else {
            DiagnosticLogger.shared.log(
                expired ? "Reconnect window expired, returning to home"
                        : "Max reconnect attempts reached, giving up",
                category: "Reconnect"
            )
            endReconnect(resumed: false)
            // Re-run discovery so the UI resolves to a real state instead of leaving the user
            // holding a host we've just proven unreachable.
            discoveredHost = nil
            startBrowsing()
            return
        }
        guard discoveredHost != nil, pairedMac != nil else {
            reconnectAttempt = 0
            return
        }
        // Losing WiFi mid-stream is the common case here, and the LAN endpoint we were using
        // is now unreachable — retrying it on a backoff can never succeed. Switch to the
        // stored remote address on the FIRST failure rather than after one wasted attempt,
        // and skip the backoff for that first remote try: the user is staring at a frozen
        // frame, and we already know where the host lives.
        var immediate = false
        if !usingRemoteHost, canUseRemoteStreaming,
           let mac = pairedMac, !mac.allRemoteHosts.isEmpty {
            activateRemoteHost(reason: "LAN dropped mid-stream, failing over to remote")
            immediate = true
        }

        let attempt = reconnectAttempt
        let delay: UInt64 = immediate ? 0 : [1, 3, 9, 27][min(attempt, 3)]
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

    /// Closes the reconnect window. `resumed: true` means a stream is running again and the
    /// overlay should simply disappear; `false` tears down and returns to the home screen.
    @MainActor
    func endReconnect(resumed: Bool) {
        reconnectWatchdog?.cancel()
        reconnectWatchdog = nil
        reconnectDeadline = nil
        reconnectAttempt = 0
        isReconnecting = false
        if !resumed {
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionManager?.onUnexpectedDisconnect = nil
            connectionManager?.disconnect()
            connectionManager = nil
            isStreaming = false
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

    /// Addresses this Mac can be reached at when Bonjour can't see it — i.e. when the phone
    /// is off the home LAN (BEAM-19). Normally captured automatically: Beacon reports its own
    /// Tailscale addresses during pairing and on every successful auth, so this self-heals if
    /// the Mac's tailnet address changes. May also be set by hand for a Mac that had no
    /// Tailscale at pairing time.
    ///
    /// Optional rather than a defaulted array so pairings stored by older builds still decode.
    var remoteHosts: [String]?

    /// Whichever remote address the user typed in themselves. Kept separate from the
    /// auto-reported list so a later auto-refresh can't silently overwrite it.
    var manualRemoteHost: String?

    /// Whether the Mac reported that it understands remote access at all. nil means it never
    /// said — i.e. a Beacon older than the feature — which the UI must distinguish from a
    /// modern Beacon that simply has no Tailscale set up.
    var hostSupportsRemoteAccess: Bool?

    /// Auto-reported addresses first, then the manual one, de-duplicated, in try order.
    var allRemoteHosts: [String] {
        var seen = Set<String>()
        return ((remoteHosts ?? []) + [manualRemoteHost].compactMap { $0 })
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct DiscoveredHost: Equatable {
    let name: String
    let endpoint: NWEndpoint
    let port: UInt16
}
