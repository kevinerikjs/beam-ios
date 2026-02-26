// SessionManager.swift
// Free tier session enforcement: 10-minute limit + 24-hour cooldown.
// Uses Keychain timestamps so limits survive app reinstall (anti-abuse).

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "SessionManager")

private let kSessionStartKey = "free_session_start"
private let kLastSessionEndKey = "free_session_end"
private let kSessionLimitSeconds: TimeInterval = 10 * 60   // 10 minutes
private let kCooldownSeconds: TimeInterval = 24 * 60 * 60  // 24 hours

@Observable
final class SessionManager {

    static let shared = SessionManager()

    // MARK: - State

    /// Time remaining in the current free session (seconds). nil = no active session.
    private(set) var secondsRemaining: TimeInterval? = nil

    /// Whether the 24h cooldown is active.
    var isInCooldown: Bool {
        guard let lastEnd = lastSessionEnd else { return false }
        return Date().timeIntervalSince(lastEnd) < kCooldownSeconds
    }

    /// Seconds until the cooldown expires.
    var cooldownSecondsRemaining: TimeInterval {
        guard let lastEnd = lastSessionEnd else { return 0 }
        let elapsed = Date().timeIntervalSince(lastEnd)
        return max(0, kCooldownSeconds - elapsed)
    }

    // MARK: - Private

    private var sessionTimer: Timer?
    private var sessionStart: Date? {
        get {
            guard let data = KeychainHelper.load(key: kSessionStartKey),
                  let str = String(data: data, encoding: .utf8),
                  let ts = Double(str) else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
        set {
            if let newValue {
                let str = String(newValue.timeIntervalSince1970)
                KeychainHelper.save(key: kSessionStartKey, data: Data(str.utf8))
            } else {
                KeychainHelper.delete(key: kSessionStartKey)
            }
        }
    }

    private var lastSessionEnd: Date? {
        get {
            guard let data = KeychainHelper.load(key: kLastSessionEndKey),
                  let str = String(data: data, encoding: .utf8),
                  let ts = Double(str) else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
        set {
            if let newValue {
                let str = String(newValue.timeIntervalSince1970)
                KeychainHelper.save(key: kLastSessionEndKey, data: Data(str.utf8))
            } else {
                KeychainHelper.delete(key: kLastSessionEndKey)
            }
        }
    }

    var onSessionExpired: (() -> Void)?

    private init() {}

    // MARK: - Session Control

    func startSession() {
        guard !StoreManager.shared.isPurchased else { return }  // Unlimited users skip this

        sessionStart = Date()
        secondsRemaining = kSessionLimitSeconds
        logger.info("Free session started, limit: \(kSessionLimitSeconds / 60) min")

        // Tick every second
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stopSession() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        lastSessionEnd = Date()
        sessionStart = nil
        secondsRemaining = nil
        logger.info("Free session ended")
    }

    private func tick() {
        guard let start = sessionStart else {
            stopSession()
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = kSessionLimitSeconds - elapsed

        if remaining <= 0 {
            stopSession()
            logger.info("Free session expired")
            DispatchQueue.main.async { self.onSessionExpired?() }
        } else {
            secondsRemaining = remaining
        }
    }

    // MARK: - Formatted

    var formattedTimeRemaining: String {
        guard let seconds = secondsRemaining else { return "" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var formattedCooldownRemaining: String {
        let secs = cooldownSecondsRemaining
        let hours = Int(secs) / 3600
        let mins = (Int(secs) % 3600) / 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

// MARK: - Keychain Helper (minimal, inline)

private enum KeychainHelper {
    static func save(key: String, data: Data) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.beam.ios.session",
            kSecAttrAccount: key
        ]
        let attrs: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query; add[kSecValueData] = data; add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load(key: String) -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: "com.beam.ios.session",
                                      kSecAttrAccount: key,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: "com.beam.ios.session",
                                      kSecAttrAccount: key]
        SecItemDelete(query as CFDictionary)
    }
}
