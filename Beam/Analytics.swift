// Analytics.swift
// PostHog wrapper. Anonymous by default — no PII collected.

import Foundation
import PostHog

enum Analytics {

    static func start() {
        let config = PostHogConfig(apiKey: "phc_h2gJDFJnFYT3CKU5pyuv2Yk5VE28YjS2mBvAQqTTNij", host: "https://w.beamscreen.app")
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = true
        #if DEBUG
        config.flushAt = 1
        #endif
        PostHogSDK.shared.setup(config)
    }

    static func track(_ event: String, properties: [String: Any]? = nil) {
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
}
