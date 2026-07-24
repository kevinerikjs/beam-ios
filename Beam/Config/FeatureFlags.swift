// FeatureFlags.swift
// Remotely-gated features that ship dark and are switched on server-side later (BEAM-18).
//
// Rules this file exists to enforce — all four matter, none are incidental:
//
//   1. Ships OFF. A feature is invisible until the server affirmatively says otherwise.
//   2. Fails closed. No network, a timeout, a 500, or malformed JSON all mean "not enabled".
//      Absence of an answer is never treated as permission.
//   3. Latches ON, permanently. The first time the server says `true`, the unlock is written
//      to the Keychain and this device keeps the feature forever — offline, on a LAN with no
//      internet, after a reinstall, after the flag server is turned off entirely. Beam is a
//      local-network product; a controller player mid-game must not lose their controller
//      because a marketing site was unreachable.
//   4. There is NO remote disable. Setting the server flag back to false only stops *new*
//      devices from unlocking. Pulling a live feature means shipping a new build.
//
// Consequence worth stating plainly: flipping the server flag to `true` is irreversible in
// practice. Treat it as a release, not a toggle.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "FeatureFlags")

@MainActor
final class FeatureFlags: ObservableObject {

    static let shared = FeatureFlags()

    /// Server-side flag names. Must match the keys in beam-web `server/flags.json`.
    enum Feature: String, CaseIterable {
        /// Forwarding an iPhone-paired game controller to the Mac as a virtual gamepad.
        /// Gated because the Mac half needs Apple's `com.apple.developer.hid.virtual.device`
        /// entitlement, which is approval-only (BEAM-16).
        case controllerPassthrough = "controller_passthrough"
    }

    private static let endpoint = URL(string: "https://beamscreen.app/api/flags")!
    private static let timeout: TimeInterval = 8

    /// Published so SwiftUI re-renders the moment a feature unlocks mid-session.
    @Published private(set) var unlocked: Set<Feature>

    private var inFlight: Task<Void, Never>?

    private init() {
        // Seed synchronously from the Keychain so the very first frame is already correct
        // and a latched user never sees a flash of the feature missing.
        unlocked = Set(Feature.allCases.filter { KeyStore.shared.isFeatureUnlocked($0.rawValue) })
        if !unlocked.isEmpty {
            logger.info("Latched features at launch: \(self.unlocked.map(\.rawValue).joined(separator: ","), privacy: .public)")
        }
    }

    // MARK: - Query

    func isEnabled(_ feature: Feature) -> Bool { unlocked.contains(feature) }

    /// Latch check for callers that aren't on the main actor (network queues, session setup).
    /// Reads the Keychain directly, which is thread-safe and is the same source of truth the
    /// main-actor copy is seeded from. Safe because the latch is write-once: a nonisolated
    /// read can never observe a value that later becomes false.
    nonisolated static func isUnlocked(_ feature: Feature) -> Bool {
        KeyStore.shared.isFeatureUnlocked(feature.rawValue)
    }

    /// Convenience for the controller passthrough gate, which is checked in several places.
    var controllerPassthroughEnabled: Bool { isEnabled(.controllerPassthrough) }

    // MARK: - Refresh

    /// Fetches the flag payload and latches on anything the server affirmatively enables.
    /// Safe to call on every launch and every foreground; concurrent calls coalesce.
    func refresh() {
        guard unlocked.count < Feature.allCases.count else {
            return  // Everything already latched — nothing a fetch could tell us.
        }
        guard inFlight == nil else { return }
        inFlight = Task { [weak self] in
            await self?.performRefresh()
            self?.inFlight = nil
        }
    }

    private func performRefresh() async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false

        do {
            let (data, response) = try await URLSession(configuration: config).data(from: Self.endpoint)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.info("Flag fetch returned non-200 — staying closed")
                return
            }
            let payload = try JSONDecoder().decode(FlagPayload.self, from: data)
            apply(payload.flags)
        } catch {
            // Expected constantly: offline, LAN-only, captive portal, server down.
            // Never escalate — the shipped/latched state stands.
            logger.debug("Flag fetch failed (staying closed): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ flags: [String: Bool]) {
        for feature in Feature.allCases {
            // Only an explicit `true` unlocks. Missing key, null, or false: no change.
            guard flags[feature.rawValue] == true, !unlocked.contains(feature) else { continue }
            KeyStore.shared.unlockFeature(feature.rawValue)
            unlocked.insert(feature)
            logger.info("Feature unlocked: \(feature.rawValue, privacy: .public)")
            DiagnosticLogger.shared.log("Feature unlocked: \(feature.rawValue)", category: "FeatureFlags")
        }
    }

    // MARK: - One-time unlock notice
    //
    // Derived from durable state rather than from the in-memory "did it flip this session"
    // signal, so the notice survives the app being killed between the unlock and the user
    // seeing it — and still shows exactly once, because the marker is Keychain-backed and
    // therefore reinstall-proof.

    /// The feature whose unlock changelog is owed to the user, if any.
    var pendingUnlockNotice: Feature? {
        unlocked.first { !KeyStore.shared.hasShownUnlockNotice($0.rawValue) }
    }

    /// Records that the unlock changelog for `feature` has been presented. Permanent.
    func markUnlockNoticeShown(_ feature: Feature) {
        KeyStore.shared.markUnlockNoticeShown(feature.rawValue)
        objectWillChange.send()
    }

    // MARK: - Payload

    private struct FlagPayload: Decodable {
        let version: Int
        let flags: [String: Bool]
    }
}
