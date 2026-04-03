// SessionManager.swift
// Free tier session enforcement: accumulated active stream time per 24h window.
// Uses Keychain timestamps so limits survive app reinstall (anti-abuse).
//
// Model:
//   kWindowStartKey  — when the current 24h window began
//   kUsedSecondsKey  — total seconds streamed so far inside that window
//   kSessionStartKey — in-flight session start (for crash-recovery accumulation)
//
// Timer states:
//   running  — sessionStart != nil, sessionTimer firing, secondsRemaining counting down
//   paused   — sessionStart == nil, sessionTimer nil, secondsRemaining non-nil (set when backgrounded)
//   stopped  — sessionStart == nil, sessionTimer nil, secondsRemaining nil (no active session)

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "SessionManager")

private let kSessionStartKey: String   = "free_session_start"
private let kUsedSecondsKey: String    = "free_used_seconds"
private let kWindowStartKey: String    = "free_window_start"
private let kTrialStartKey: String     = "free_trial_start"

/// Total free streaming seconds per 24h window. 30 minutes.
private let kSessionLimitSeconds: TimeInterval = 30 * 60
private let kCooldownSeconds: TimeInterval     = 24 * 60 * 60
/// Free trial duration: 3 days from first successful stream.
private let kTrialDurationSeconds: TimeInterval = 3 * 24 * 60 * 60

final class SessionManager: ObservableObject {

    static let shared = SessionManager()

    // MARK: - Observable State

    /// Seconds remaining in the current session (running or paused). `nil` = no active session.
    @Published private(set) var secondsRemaining: TimeInterval? = nil

    // MARK: - Trial State

    /// `true` while the 3-day free trial (from first successful stream) is still active.
    var isInTrial: Bool {
        guard !StoreManager.shared.isPurchased else { return false }
        guard let start = trialStartDate else { return false }
        return Date().timeIntervalSince(start) < kTrialDurationSeconds
    }

    /// Remaining trial time in whole days, rounded up (1–3). Returns 0 when expired or not started.
    var trialDaysRemaining: Int {
        guard let start = trialStartDate else { return 0 }
        let remaining = kTrialDurationSeconds - Date().timeIntervalSince(start)
        return max(0, Int(ceil(remaining / (24 * 60 * 60))))
    }

    /// Whether a trial was ever started (used to detect first-time expiry for the transition modal).
    var hasTrialStarted: Bool { trialStartDate != nil }

    /// Human-readable remaining trial label for the bottom bar chip.
    /// Returns a "start your trial" label if the trial hasn't been triggered yet.
    var formattedTrialDaysRemaining: String {
        guard hasTrialStarted else { return "3-day free trial" }
        switch trialDaysRemaining {
        case 3:  return "3 days free"
        case 2:  return "2 days free"
        case 1:  return "1 day free"
        default: return "< 1 day free"
        }
    }

    // MARK: - 24h Cooldown State

    /// `true` when the user has exhausted their daily allowance and the 24h window hasn't reset.
    var isInCooldown: Bool {
        guard let ws = windowStart else { return false }
        guard Date().timeIntervalSince(ws) < kCooldownSeconds else { return false }
        return usedSeconds >= kSessionLimitSeconds
    }

    /// How many seconds until the 24h window resets. Used for UI countdown display.
    var cooldownSecondsRemaining: TimeInterval {
        guard let ws = windowStart else { return 0 }
        let windowEnd = ws.addingTimeInterval(kCooldownSeconds)
        return max(0, windowEnd.timeIntervalSince(Date()))
    }

    // MARK: - Callback

    /// Fired on the main thread when the session limit is hit.
    var onSessionExpired: (() -> Void)?

    // MARK: - Private

    private var sessionTimer: Timer?

    // MARK: - Keychain-backed stored properties

    private var sessionStart: Date? {
        get { loadDate(key: kSessionStartKey) }
        set { saveDate(newValue, key: kSessionStartKey) }
    }

    private var usedSeconds: TimeInterval {
        get {
            guard let data = KeychainHelper.load(key: kUsedSecondsKey),
                  let str  = String(data: data, encoding: .utf8),
                  let val  = Double(str) else { return 0 }
            return val
        }
        set {
            KeychainHelper.save(key: kUsedSecondsKey, data: Data(String(newValue).utf8))
        }
    }

    private var windowStart: Date? {
        get { loadDate(key: kWindowStartKey) }
        set { saveDate(newValue, key: kWindowStartKey) }
    }

    private var trialStartDate: Date? {
        get { loadDate(key: kTrialStartKey) }
        set { saveDate(newValue, key: kTrialStartKey) }
    }

    // MARK: - Init

    private init() {
        // Crash/kill recovery: if a session was in-flight, commit its elapsed time now.
        if let start = sessionStart {
            let recovered = Date().timeIntervalSince(start)
            usedSeconds = min(kSessionLimitSeconds, usedSeconds + recovered)
            sessionStart = nil
            logger.info("Recovered \(recovered, format: .fixed(precision: 1))s from interrupted session")
        }
    }

    // MARK: - Session Control

    /// Records the start of the 3-day free trial on the very first successful stream.
    /// No-op if the trial has already been started or the user has purchased.
    func recordFirstStream() {
        guard !StoreManager.shared.isPurchased else { return }
        guard trialStartDate == nil else { return }
        trialStartDate = Date()
        logger.info("Free trial started")
    }

    /// Start a new session (called on authSuccess). No-op for purchased or trial users.
    func startSession() {
        guard !StoreManager.shared.isPurchased else { return }
        guard !isInTrial else { return }

        resetWindowIfExpired()

        guard usedSeconds < kSessionLimitSeconds else {
            logger.info("Daily limit already reached (\(self.usedSeconds, format: .fixed(precision: 1))s used)")
            DispatchQueue.main.async { self.onSessionExpired?() }
            return
        }

        if windowStart == nil { windowStart = Date() }

        sessionStart = Date()
        secondsRemaining = kSessionLimitSeconds - usedSeconds
        logger.info("Session started. Used: \(self.usedSeconds, format: .fixed(precision: 1))s / \(kSessionLimitSeconds, format: .fixed(precision: 0))s")

        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Pause the timer (app backgrounded without PiP). Commits elapsed time; timer can be resumed.
    func pauseSession() {
        guard sessionTimer != nil else { return } // already paused or stopped

        sessionTimer?.invalidate()
        sessionTimer = nil

        if let start = sessionStart {
            let elapsed = Date().timeIntervalSince(start)
            usedSeconds = min(kSessionLimitSeconds, usedSeconds + elapsed)
            sessionStart = nil
        }

        // Keep secondsRemaining non-nil — that's how resumeSession() knows a session is paused.
        secondsRemaining = kSessionLimitSeconds - usedSeconds
        logger.info("Session paused. Total used: \(self.usedSeconds, format: .fixed(precision: 1))s")
    }

    /// Resume a paused session (app foregrounded, or PiP became active). No-op if not paused.
    func resumeSession() {
        guard !StoreManager.shared.isPurchased else { return }
        // secondsRemaining != nil means a session is active or paused
        guard secondsRemaining != nil else { return }
        // sessionStart == nil means we're paused (not already running)
        guard sessionStart == nil else { return }
        guard usedSeconds < kSessionLimitSeconds else {
            DispatchQueue.main.async { self.onSessionExpired?() }
            return
        }

        sessionStart = Date()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        logger.info("Session resumed. Remaining: \(self.secondsRemaining ?? 0, format: .fixed(precision: 1))s")
    }

    /// Stop the session entirely (stream disconnected). Commits time and clears all state.
    func stopSession() {
        sessionTimer?.invalidate()
        sessionTimer = nil

        if let start = sessionStart {
            let elapsed = Date().timeIntervalSince(start)
            usedSeconds = min(kSessionLimitSeconds, usedSeconds + elapsed)
            logger.info("Session stopped. Total used: \(self.usedSeconds, format: .fixed(precision: 1))s / \(kSessionLimitSeconds, format: .fixed(precision: 0))s")
        }

        sessionStart = nil
        secondsRemaining = nil
    }

    private func tick() {
        guard let start = sessionStart else { stopSession(); return }
        let elapsed   = Date().timeIntervalSince(start)
        let remaining = kSessionLimitSeconds - (usedSeconds + elapsed)

        if remaining <= 0 {
            usedSeconds      = kSessionLimitSeconds
            sessionStart     = nil
            sessionTimer?.invalidate()
            sessionTimer     = nil
            secondsRemaining = nil
            logger.info("Daily session limit reached")
            Analytics.dailyLimitReached()
            DispatchQueue.main.async { self.onSessionExpired?() }
        } else {
            secondsRemaining = remaining
        }
    }

    private func resetWindowIfExpired() {
        guard let ws = windowStart else { return }
        if Date().timeIntervalSince(ws) >= kCooldownSeconds {
            logger.info("24h window expired — resetting usage counter")
            usedSeconds  = 0
            windowStart  = nil
            sessionStart = nil
        }
    }

    // MARK: - Formatted Strings

    var formattedTimeRemaining: String {
        guard let seconds = secondsRemaining else { return "" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Human-readable countdown until the 24h window resets.
    var formattedCooldownRemaining: String {
        let secs  = cooldownSecondsRemaining
        let hours = Int(secs) / 3600
        let mins  = (Int(secs) % 3600) / 60
        let secsR = Int(secs) % 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        if mins  > 0 { return "\(mins)m \(secsR)s" }
        return "\(secsR)s"
    }

    /// Remaining free time today for HomeView bottom bar.
    /// Re-reads Keychain on every call — HomeView's 1s clock tick keeps it current.
    var formattedFreeTimeRemainingToday: String {
        let totalMins = Int(kSessionLimitSeconds / 60)
        // If window is active, compute remaining
        if let ws = windowStart, Date().timeIntervalSince(ws) < kCooldownSeconds {
            let remaining = max(0, kSessionLimitSeconds - usedSeconds)
            let mins = Int(ceil(remaining / 60.0))
            if mins >= totalMins { return "\(totalMins) min free" }
            if mins == 0 { return "< 1 min left today" }
            return "\(mins) min left today"
        }
        // No window started yet or window expired — full time available
        return "\(totalMins) min free"
    }

    // MARK: - Keychain date helpers

    private func loadDate(key: String) -> Date? {
        guard let data = KeychainHelper.load(key: key),
              let str  = String(data: data, encoding: .utf8),
              let ts   = Double(str) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func saveDate(_ date: Date?, key: String) {
        if let date {
            KeychainHelper.save(key: key, data: Data(String(date.timeIntervalSince1970).utf8))
        } else {
            KeychainHelper.delete(key: key)
        }
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
        let attrs: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData]      = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load(key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.beam.ios.session",
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
            ? result as? Data : nil
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.beam.ios.session",
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
