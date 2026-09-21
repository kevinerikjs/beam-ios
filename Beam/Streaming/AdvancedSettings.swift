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
    }

    // MARK: Stream mode

    static let streamModeKey = "beam.settings.streamMode"
    enum StreamMode: Int { case auto = 0, game = 1, video = 2, custom = 3 }
    static var streamMode: StreamMode { StreamMode(rawValue: UserDefaults.standard.integer(forKey: streamModeKey)) ?? .auto }

    /// Set by the connection: a controller is attached or click mode is on. Auto follows it.
    static var interactiveNow = false { didSet { if interactiveNow != oldValue && streamMode == .auto { applyMode() } } }

    /// Game: capped bitrate for input latency, lowest-latency pacing. Video: full rate,
    /// smoothest pacing. Auto is Game while the session is interactive. Custom keeps whatever
    /// the Advanced knobs say.
    static var isGameMode: Bool {
        switch streamMode {
        case .game: return true
        case .video: return false
        case .auto: return interactiveNow
        case .custom: return bitrateCap != nil
        }
    }

    /// A mode is a preset: choosing one writes the knobs it owns (cap and pacing), so
    /// Advanced shows what is in effect. Editing a knob afterwards makes the mode Custom.
    static func applyMode() {
        guard streamMode != .custom else { return }
        let game = isGameMode
        UserDefaults.standard.set(game ? Double(interactiveCap) / 1_000_000 : 0, forKey: bitrateCapMbpsKey)
        UserDefaults.standard.set(game ? FramePacing.lowestLatency.rawValue : FramePacing.smoothest.rawValue, forKey: framePacingKey)
    }

    /// Called by the Advanced knobs after a change: a value the current mode would not have
    /// written means Custom from now on (a change the mode itself made is left alone).
    static func knobEdited() {
        guard streamMode != .custom else { return }
        let game = isGameMode
        let expectedCap: Int? = game ? interactiveCap : nil
        let expectedPacing: FramePacing = game ? .lowestLatency : .smoothest
        if bitrateCap != expectedCap || framePacing != expectedPacing {
            UserDefaults.standard.set(StreamMode.custom.rawValue, forKey: streamModeKey)
        }
    }

    /// The pacing in effect right now (a knob the mode writes).
    static var framePacing: FramePacing {
        FramePacing(rawValue: UserDefaults.standard.integer(forKey: framePacingKey)) ?? .smoothest
    }

    /// Bits per second, or nil for no cap. A knob the mode writes; what is stored is in effect.
    static var bitrateCap: Int? {
        let mbps = UserDefaults.standard.double(forKey: bitrateCapMbpsKey)
        return mbps > 0 ? Int(mbps * 1_000_000) : nil
    }

    static let interactiveCap = 6_000_000
    static func effectiveBitrateCap(controllerAttached: Bool) -> Int? { bitrateCap }

    static var keepScreenAwake: Bool {
        UserDefaults.standard.object(forKey: keepScreenAwakeKey) as? Bool ?? true
    }

    static let allKeys = [framePacingKey, bitrateCapMbpsKey, keepScreenAwakeKey, latencyMeterKey, enqueueOnMainKey, forceH264Key, "beam.settings.legacyTransport"]

    static func reset() {
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}
