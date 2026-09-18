import CoreMedia
import Foundation
import Phoros
import VideoToolbox

// Beam's own policy on top of the Phoros wire contract: what this phone
// advertises it can decode, the quality cap for remote links, display strings
// and the escape hatches that force the legacy codecs. None of this is on the
// wire; the Mac has its own copy of what it needs.

extension QualityPreset {
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .p360_30: return "360p · 30 fps"
        case .p480_30: return "480p · 30 fps"
        case .p720_30: return "720p · 30 fps"
        case .p720_60: return "720p · 60 fps"
        case .p1080_30: return "1080p · 30 fps"
        case .p1080_60: return "1080p · 60 fps"
        }
    }

    /// The bitrate Beacon targets for this preset. Mirrors the host's table so the
    /// phone can warn before asking a constrained link for more than it can carry.
    var bitrateMbps: Double {
        switch self {
        case .auto: return 6
        case .p360_30: return 1.5
        case .p480_30: return 2.5
        case .p720_30: return 4
        case .p720_60: return 6
        case .p1080_30: return 6
        case .p1080_60: return 10
        }
    }

    static let remoteCap: QualityPreset = .p720_30

    var exceedsRemoteCap: Bool {
        switch self {
        case .p360_30, .p480_30, .p720_30:
            false
        case .auto, .p720_60, .p1080_30, .p1080_60:
            true
        }
    }
}

extension AudioCodecID {
    /// UserDefaults key, identical on both platforms, that forces the legacy PCM path.
    /// Escape hatch for a bad release.
    static let forcePCMDefaultsKey = "BeamForcePCMAudio"

    /// What this phone advertises, most preferred first. PCM is always included and
    /// always the last resort.
    static func clientAdvertisedCodecs() -> [String] {
        if UserDefaults.standard.bool(forKey: forcePCMDefaultsKey) {
            return [AudioCodecID.pcmFloat32.wireName]
        }
        return [AudioCodecID.aacLC.wireName, AudioCodecID.pcmFloat32.wireName]
    }
}

extension VideoCodecID {
    /// UserDefaults key that forces the legacy H.264 path, mirroring the audio one.
    static let forceH264DefaultsKey = "BeamForceH264Video"

    /// What this phone advertises, most preferred first. HEVC is offered only when the
    /// device can hardware-decode it (true for every iOS 16 device, but probed rather
    /// than assumed). H.264 is always included and always the last resort.
    static func clientAdvertisedCodecs() -> [String] {
        guard !UserDefaults.standard.bool(forKey: forceH264DefaultsKey) else {
            return [VideoCodecID.h264.wireName]
        }
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else {
            return [VideoCodecID.h264.wireName]
        }
        return [VideoCodecID.hevc.wireName, VideoCodecID.h264.wireName]
    }
}

extension CMTime {
    /// This time on the wire clock: microseconds, the unit every Phoros timestamp uses.
    var microseconds: Int64 {
        guard timescale != 0 else { return 0 }
        return Int64(Double(value) / Double(timescale) * 1_000_000)
    }

    static func fromMicroseconds(_ microseconds: Int64) -> CMTime {
        CMTime(value: CMTimeValue(microseconds), timescale: 1_000_000)
    }
}

extension Data {
    init?(hexEncoded hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
