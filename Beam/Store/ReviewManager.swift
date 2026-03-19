// ReviewManager.swift
// Asks for a review after the user has completed enough streams.
// Uses SKStoreReviewController which enforces Apple's 3x/year cap automatically.

import StoreKit
import UIKit

enum ReviewManager {

    private static let streamsKey       = "reviewStreamsCompleted"
    private static let lastPromptKey    = "reviewLastPromptDate"
    private static let minStreams       = 3
    private static let minDaysBetween: TimeInterval = 60 * 24 * 60 * 60   // 60 days

    /// Call after every completed stream. Prompts if conditions are met.
    static func recordStreamCompleted() {
        let count = UserDefaults.standard.integer(forKey: streamsKey) + 1
        UserDefaults.standard.set(count, forKey: streamsKey)

        guard count >= minStreams else { return }

        if let last = UserDefaults.standard.object(forKey: lastPromptKey) as? Date {
            guard Date().timeIntervalSince(last) >= minDaysBetween else { return }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
            SKStoreReviewController.requestReview(in: scene)
            UserDefaults.standard.set(Date(), forKey: lastPromptKey)
        }
    }
}
