// PromoConfig.swift
// Remote-controlled state for the limited-time Beam Unlimited launch price (BEAM-28).
//
// Why this file exists at all
// ---------------------------
// Apple has no promotional pricing mechanism for non-consumables. Introductory offers and
// promotional offers are auto-renewable subscriptions only, and Beam Unlimited is a one-time
// unlock. So a "launch price, going up soon" story has to be built by hand: two separate
// products in App Store Connect, one cheap and one at the eventual regular price, with the app
// deciding which one it offers.
//
// The legal shape this has to hold
// --------------------------------
// Kevin sells from the EU. Under the Unfair Commercial Practices Directive as amended by the
// Omnibus Directive, a countdown that restarts, or a "price rises on Friday" claim where the
// price never rises, is a prohibited practice, not a grey area. So the design rule here is
// stronger than "don't lie": the code is arranged so it *cannot* tell a lie that matters.
//
//   1. The deadline is never invented on-device. There is no "first launch plus 48 hours"
//      fallback, no per-install timer. The only deadline that exists is one absolute instant
//      published by the server. A reinstall, a relaunch, or a backgrounding cannot move it,
//      because nothing local ever produced it.
//   2. Urgency needs proof. The countdown is only drawn when we can show, from live StoreKit
//      data, both the price you pay now and the price it becomes. If the regular-price product
//      is not loadable, there is no verifiable claim to make and no countdown is drawn.
//   3. Silence beats a stale claim. A fetch that fails, times out, 404s, or returns junk shows
//      no urgency at all. A cached config is trusted only for `freshnessWindow`; after that the
//      urgency messaging goes away on its own, so ending a promo server-side takes effect for
//      practical purposes within hours even for a client that never fetches again.
//   4. Uncertainty resolves in the customer's favour. When we do not know the promo state, we
//      offer the *cheaper* product. Never the reverse. An unreachable server can cost Kevin a
//      few euros; it can never overcharge someone.
//
// Guideline 2.5.2: this endpoint carries configuration only, never code and never behaviour.
// Booleans, one timestamp, two strings of display copy. Nothing here can change what the app
// does, only which of two already-shipped products it sells and what words sit above the button.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "PromoConfig")

@MainActor
final class PromoConfig: ObservableObject {

    static let shared = PromoConfig()

    // MARK: - Tuning

    private static let endpoint = URL(string: "https://beamscreen.app/api/promo")!
    private static let timeout: TimeInterval = 8

    /// How long a successfully fetched config may still drive urgency messaging.
    ///
    /// Deliberately short. Remote config exists so a promo can be ended without an App Store
    /// release, and that promise is only real if a client that stops fetching also stops
    /// claiming. Six hours means an ended promo goes quiet on effectively every device the
    /// same day, while a user who is briefly offline still sees a coherent paywall.
    private nonisolated static let freshnessWindow: TimeInterval = 6 * 60 * 60

    /// Remote copy is display text, so it is length-capped and stripped of line breaks before
    /// it can reach a `Text`. Keeps a bad paste from wrecking the layout.
    private static let maxCopyLength = 140

    private nonisolated static let cacheKey = "beam.promo.cachedConfig"

    // MARK: - Published state

    /// Bumped after every state change so SwiftUI re-reads the computed properties below.
    /// The config itself is intentionally not published: readers should go through the
    /// accessors, which apply the freshness and truthfulness rules.
    @Published private(set) var revision: Int = 0

    private var cached: CachedConfig?
    private var inFlight: Task<Void, Never>?

    private init() {
        cached = Self.readCache()
    }

    // MARK: - Reads (main actor)

    /// The promo copy and deadline, but only when every condition for an honest, checkable
    /// claim holds. `nil` means: draw no urgency of any kind.
    ///
    /// Callers must additionally confirm they can display both prices from StoreKit; this type
    /// has no visibility into the store, so it cannot enforce that half itself.
    var activeCountdown: Countdown? {
        // Never let a marketing countdown into an App Store screenshot.
        guard !ShotMode.isActive else { return nil }
        guard let cached, cached.isFresh(asOf: Date()) else { return nil }
        guard cached.promo.enabled, cached.promo.deadline > Date() else { return nil }
        return Countdown(
            deadline: cached.promo.deadline,
            headline: cached.promo.headline ?? Countdown.defaultHeadline,
            note: cached.promo.note
        )
    }

    // MARK: - Reads (any thread)

    /// Whether the discounted product is the one to sell.
    ///
    /// Note this ignores freshness on purpose, and is a separate question from whether to *say*
    /// anything about a promo. Which product is offered must stay stable and generous: a device
    /// that has never reached the server, or has not reached it lately, keeps the lower price.
    /// It only moves up once a config it has actually seen says the deadline has passed, or
    /// that the promo is switched off.
    nonisolated static var offersPromoPrice: Bool {
        guard let cached = readCache() else {
            return true  // Never heard from the server. Sell the price that is live today.
        }
        guard cached.promo.enabled else { return false }
        return Date() < cached.promo.deadline
    }

    // MARK: - Refresh

    /// Safe to call on launch and on every foreground. Concurrent calls coalesce.
    func refresh() {
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
                logger.info("Promo fetch returned non-200, keeping last known state")
                return
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            apply(payload.promo)
        } catch {
            // Routine: offline, LAN with no internet, captive portal, endpoint not deployed yet.
            // The cached config stands, and its own freshness window retires it on schedule.
            logger.debug("Promo fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ incoming: Promo?) {
        guard let incoming else {
            // A well-formed payload with no promo block is an explicit "there is no promo".
            // That is an answer, and it clears the cache immediately.
            clearCache()
            return
        }

        let sanitized = Promo(
            enabled: incoming.enabled,
            deadline: incoming.deadline,
            headline: Self.sanitize(incoming.headline),
            note: Self.sanitize(incoming.note)
        )

        let entry = CachedConfig(promo: sanitized, fetchedAt: Date())
        cached = entry
        Self.writeCache(entry)
        revision &+= 1
        logger.info("Promo config updated (enabled=\(sanitized.enabled, privacy: .public))")
    }

    private func clearCache() {
        guard cached != nil else { return }
        cached = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        revision &+= 1
        logger.info("Promo config cleared by server")
    }

    // MARK: - Copy hygiene

    private static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(maxCopyLength))
    }

    // MARK: - Cache

    private nonisolated static func readCache() -> CachedConfig? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedConfig.self, from: data)
    }

    private nonisolated static func writeCache(_ entry: CachedConfig) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    // MARK: - Types

    /// Everything the paywall needs to make one true statement.
    struct Countdown: Equatable {
        static let defaultHeadline = "Launch price"

        let deadline: Date
        let headline: String
        let note: String?

        var timeRemaining: TimeInterval { max(0, deadline.timeIntervalSinceNow) }
        var hasExpired: Bool { timeRemaining <= 0 }

        /// Localized, e.g. "2d 4h", "13m 5s". Two units is enough to feel precise without
        /// implying a precision the network round trip does not have.
        var formattedRemaining: String? {
            Self.formatter.string(from: timeRemaining)
        }

        private static let formatter: DateComponentsFormatter = {
            let f = DateComponentsFormatter()
            f.unitsStyle = .abbreviated
            f.allowedUnits = [.day, .hour, .minute, .second]
            f.maximumUnitCount = 2
            f.zeroFormattingBehavior = .dropAll
            return f
        }()
    }

    struct Promo: Codable, Equatable {
        let enabled: Bool
        let deadline: Date
        let headline: String?
        let note: String?

        private enum CodingKeys: String, CodingKey {
            case enabled, deadline, headline, note
        }

        init(enabled: Bool, deadline: Date, headline: String?, note: String?) {
            self.enabled = enabled
            self.deadline = deadline
            self.headline = headline
            self.note = note
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            headline = try c.decodeIfPresent(String.self, forKey: .headline)
            note = try c.decodeIfPresent(String.self, forKey: .note)

            // Deadline is mandatory and must be an unambiguous absolute instant. Anything the
            // parser cannot pin to a real moment in time throws, and a throw means no promo,
            // which is the safe outcome.
            let raw = try c.decode(String.self, forKey: .deadline)
            guard let parsed = Promo.parseTimestamp(raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deadline, in: c,
                    debugDescription: "deadline must be an ISO 8601 timestamp with an explicit offset"
                )
            }
            deadline = parsed
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(Promo.isoOut.string(from: deadline), forKey: .deadline)
            try c.encodeIfPresent(headline, forKey: .headline)
            try c.encodeIfPresent(note, forKey: .note)
        }

        private static let isoOut: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        private static let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        static func parseTimestamp(_ raw: String) -> Date? {
            isoOut.date(from: raw) ?? isoFractional.date(from: raw)
        }
    }

    private struct CachedConfig: Codable {
        let promo: Promo
        let fetchedAt: Date

        /// A `fetchedAt` in the future means the device clock moved backwards since the fetch.
        /// Treat that as unusable rather than as infinite freshness.
        func isFresh(asOf now: Date) -> Bool {
            let age = now.timeIntervalSince(fetchedAt)
            return age >= 0 && age < PromoConfig.freshnessWindow
        }
    }

    private struct Payload: Decodable {
        let version: Int?
        let promo: Promo?
    }
}
