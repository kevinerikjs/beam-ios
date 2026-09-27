// Analytics.swift
// PostHog wrapper. Anonymous by default — no PII collected.

import Foundation
import PostHog

enum Analytics {

    /// Simulator and Debug builds stay out of the production project: a
    /// screenshot run on 2026-09-27 reinstalled the app on a simulator 13
    /// times and took that day's installs from 5 to 18 (BEAM-71). Set
    /// `BEAM_ANALYTICS=1` in the scheme's environment to send anyway, for
    /// example to check a new event.
    private static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["BEAM_ANALYTICS"] == "1" { return true }
        #if targetEnvironment(simulator) || DEBUG
        return false
        #else
        return true
        #endif
    }()

    static func start() {
        guard isEnabled else { return }
        let config = PostHogConfig(apiKey: "phc_h2gJDFJnFYT3CKU5pyuv2Yk5VE28YjS2mBvAQqTTNij", host: "https://w.beamscreen.app")
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = true
        #if DEBUG
        config.flushAt = 1
        #endif
        PostHogSDK.shared.setup(config)
    }

    static func track(_ event: String, properties: [String: Any]? = nil) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }
}

// MARK: - Event constants

extension Analytics {
    static func streamStarted(isPurchased: Bool, isInTrial: Bool, qualityPreset: String) {
        track("stream_started", properties: [
            "is_purchased": isPurchased,
            "is_in_trial": isInTrial,
            "quality_preset": qualityPreset
        ])
    }

    static func streamEnded(durationSeconds: TimeInterval, isPurchased: Bool) {
        track("stream_ended", properties: [
            "duration_seconds": Int(durationSeconds),
            "is_purchased": isPurchased
        ])
    }

    static func pipActivated() {
        track("pip_activated")
    }

    static func paywallShown(reason: String) {
        track("paywall_shown", properties: ["reason": reason])
    }

    static func iapInitiated() {
        track("iap_purchase_initiated")
    }

    static func iapCompleted() {
        track("iap_purchase_completed")
    }

    /// Fires once, the first time the app detects the 3-day free trial has expired.
    static func trialExpired() {
        track("trial_expired")
    }

    /// Fires each time a free-tier streaming session is cut short by the 30-minute daily limit.
    static func dailyLimitReached() {
        track("daily_limit_reached")
    }
}
