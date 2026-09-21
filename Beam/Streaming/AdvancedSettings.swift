import Foundation

/// The Advanced settings, read where they take effect. Keys are stable: they are what
/// "Reset Advanced Settings" clears.
enum AdvancedSettings {
    static let framePacingKey = "beam.settings.framePacing"          // FramePacing.rawValue
    static let bitrateCapMbpsKey = "beam.settings.bitrateCapMbps"    // 0 = no cap
    static let keepScreenAwakeKey = "beam.settings.keepScreenAwake"  // default true
    static let latencyMeterKey = "beam.debug.showLatency"
    static let enqueueOnMainKey = "beam.debug.enqueueOnMain"
    static let forceH264Key = "BeamForceH264Video"

    enum FramePacing: Int {
        /// Every frame is shown the moment it decodes. Input feels immediate; a late frame shows as a hitch.
        case lowestLatency = 0
        /// Frames are held just long enough to even out arrival jitter, then shown on the capture cadence.
        case smoothest = 1
        /// Follows the stream mode: lowest latency in Game, smoothest in Video.
        case auto = 2
    }

    /// The user's choice in Advanced; `.auto` (the default) follows the stream mode.
    static var framePacingSetting: FramePacing {
        UserDefaults.standard.object(forKey: framePacingKey) == nil ? .auto : (FramePacing(rawValue: UserDefaults.standard.integer(forKey: framePacingKey)) ?? .auto)
    }

    /// The pacing in effect right now.
    static var framePacing: FramePacing {
        let set = framePacingSetting
        if set != .auto { return set }
        return isGameMode ? .lowestLatency : .smoothest
    }

    // MARK: Stream mode

    static let streamModeKey = "beam.settings.streamMode"
    enum StreamMode: Int { case auto = 0, game = 1, video = 2 }
    static var streamMode: StreamMode { StreamMode(rawValue: UserDefaults.standard.integer(forKey: streamModeKey)) ?? .auto }

    /// Set by the connection: a controller is attached or click mode is on. Auto follows it.
    static var interactiveNow = false

    /// Game: capped bitrate for input latency, lowest-latency pacing. Video: full rate,
    /// smoothest pacing. Auto picks Game while the session is interactive.
    static var isGameMode: Bool {
        switch streamMode {
        case .game: return true
        case .video: return false
        case .auto: return interactiveNow
        }
    }

    /// Bits per second the user set, or nil for no cap.
    static var bitrateCap: Int? {
        let mbps = UserDefaults.standard.double(forKey: bitrateCapMbpsKey)
        return mbps > 0 ? Int(mbps * 1_000_000) : nil
    }

    /// The cap in effect: the user's, or with a controller attached the interactive default.
    /// An iPhone taxes every packet it sends by ~7 ms while sustained downlink exceeds
    /// roughly 7 Mbps, on any transport; at 6 Mbps a press reaches the screen in 24/27 ms
    /// (p50/p95) over Wi-Fi against 36/62 at the preset's ~10 Mbps. Watching video pays
    /// nothing for the tax, so it keeps the full rate.
    static let interactiveCap = 6_000_000
    static func effectiveBitrateCap(controllerAttached: Bool) -> Int? {
        if let cap = bitrateCap { return cap }
        return isGameMode ? interactiveCap : nil
    }

    static var keepScreenAwake: Bool {
        UserDefaults.standard.object(forKey: keepScreenAwakeKey) as? Bool ?? true
    }

    static let allKeys = [framePacingKey, bitrateCapMbpsKey, keepScreenAwakeKey, latencyMeterKey, enqueueOnMainKey, forceH264Key, "beam.settings.legacyTransport"]

    static func reset() {
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}
