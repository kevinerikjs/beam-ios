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

    static var framePacing: FramePacing {
        FramePacing(rawValue: UserDefaults.standard.integer(forKey: framePacingKey)) ?? .lowestLatency
    }

    /// Bits per second, or nil for no cap.
    static var bitrateCap: Int? {
        let mbps = UserDefaults.standard.double(forKey: bitrateCapMbpsKey)
        return mbps > 0 ? Int(mbps * 1_000_000) : nil
    }

    static var keepScreenAwake: Bool {
        UserDefaults.standard.object(forKey: keepScreenAwakeKey) as? Bool ?? true
    }

    static let allKeys = [framePacingKey, bitrateCapMbpsKey, keepScreenAwakeKey, latencyMeterKey, enqueueOnMainKey, forceH264Key]

    static func reset() {
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}
