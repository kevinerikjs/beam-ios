// Protocol.swift
// Beam Network Protocol - iOS client side.
// IMPORTANT: This file must stay in sync with beam-macos/BeamHost/Network/Protocol.swift
// Consider using a Swift Package to share this code in the future.

import Foundation
import CoreMedia
import VideoToolbox

// MARK: - Stream Quality Presets

enum StreamQualityPreset: String, Codable, CaseIterable, Identifiable {
    case auto     = "auto"
    case p360_30  = "360p30"
    case p480_30  = "480p30"
    case p720_30  = "720p30"
    case p720_60  = "720p60"
    case p1080_30 = "1080p30"
    case p1080_60 = "1080p60"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:     return "Auto"
        case .p360_30:  return "360p · 30 fps"
        case .p480_30:  return "480p · 30 fps"
        case .p720_30:  return "720p · 30 fps"
        case .p720_60:  return "720p · 60 fps"
        case .p1080_30: return "1080p · 30 fps"
        case .p1080_60: return "1080p · 60 fps"
        }
    }

    var width: Int {
        switch self {
        case .auto:                   return 1920
        case .p360_30:                return 640
        case .p480_30:                return 854
        case .p720_30, .p720_60:      return 1280
        case .p1080_30, .p1080_60:    return 1920
        }
    }

    var height: Int {
        switch self {
        case .auto:                   return 1080
        case .p360_30:                return 360
        case .p480_30:                return 480
        case .p720_30, .p720_60:      return 720
        case .p1080_30, .p1080_60:    return 1080
        }
    }

    var fps: Double {
        switch self {
        case .auto, .p360_30, .p480_30, .p720_30, .p1080_30: return 30
        case .p720_60, .p1080_60:                             return 60
        }
    }

    var bitrateMbps: Double {
        switch self {
        case .auto:    return 6
        case .p360_30: return 1.5
        case .p480_30: return 2.5
        case .p720_30: return 4
        case .p720_60: return 6
        case .p1080_30: return 6
        case .p1080_60: return 10
        }
    }

    /// Non-auto presets ordered lowest → highest (for auto-adaptation tiering).
    static let autoTiers: [StreamQualityPreset] = [.p360_30, .p480_30, .p720_30, .p1080_30]

    /// Ceiling applied when the host is reached over a remote path rather than the LAN
    /// (BEAM-19). Everything above this assumes LAN bandwidth and will buffer on cellular or
    /// a relayed tailnet before the adaptation loop can react.
    static let remoteCap: StreamQualityPreset = .p720_30

    /// Whether this preset asks for more than a remote link should be started at.
    /// `.auto` counts: it opens at 1080p30, which is exactly the too-optimistic first guess
    /// the cap exists to avoid.
    var exceedsRemoteCap: Bool {
        switch self {
        case .p360_30, .p480_30, .p720_30:
            return false
        case .auto, .p720_60, .p1080_30, .p1080_60:
            return true
        }
    }
}

// MARK: - Packet Types

enum BeamPacketType: UInt8 {
    case video      = 0x01
    case audio      = 0x02
    case control    = 0x03
    case heartbeat  = 0x04
    case spsPps     = 0x05
    case videoIDR   = 0x06
    case input      = 0x07  // Controller state report (iOS → macOS)
}

// MARK: - Packet Header (10 bytes)

struct BeamPacketHeader {
    static let magic: UInt32 = 0x4245414D  // "BEAM"
    static let size: Int = 10

    let type: BeamPacketType
    let flags: UInt8
    let payloadLength: UInt32

    func serialized() -> Data {
        var magic = BeamPacketHeader.magic.bigEndian
        var length = payloadLength.bigEndian
        var out = Data(capacity: BeamPacketHeader.size)
        Swift.withUnsafeBytes(of: &magic) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(flags)
        Swift.withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        return out
    }

    static func parse(from data: Data) -> BeamPacketHeader? {
        guard data.count >= BeamPacketHeader.size else { return nil }
        let magic = data[0..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard magic == BeamPacketHeader.magic else { return nil }
        guard let type = BeamPacketType(rawValue: data[4]) else { return nil }
        let flags = data[5]
        let length = data[6..<10].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        return BeamPacketHeader(type: type, flags: flags, payloadLength: length)
    }
}

// MARK: - Video Payload Header (16 bytes)

struct BeamVideoPayloadHeader {
    static let size: Int = 16

    let frameNumber: UInt32
    let fragmentIndex: UInt16
    let totalFragments: UInt16
    let presentationTimestamp: Int64

    static func parse(from data: Data) -> BeamVideoPayloadHeader? {
        guard data.count >= BeamVideoPayloadHeader.size else { return nil }
        let fn  = data[0..<4].withUnsafeBytes  { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let fi  = data[4..<6].withUnsafeBytes  { $0.loadUnaligned(as: UInt16.self).bigEndian }
        let tf  = data[6..<8].withUnsafeBytes  { $0.loadUnaligned(as: UInt16.self).bigEndian }
        let ts  = data[8..<16].withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
        return BeamVideoPayloadHeader(frameNumber: fn, fragmentIndex: fi, totalFragments: tf, presentationTimestamp: ts)
    }
}

// MARK: - Audio Payload Header (12 bytes)

struct BeamAudioPayloadHeader {
    static let size: Int = 12

    let sequenceNumber: UInt32
    let presentationTimestamp: Int64

    static func parse(from data: Data) -> BeamAudioPayloadHeader? {
        guard data.count >= BeamAudioPayloadHeader.size else { return nil }
        let sn = data[0..<4].withUnsafeBytes  { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let ts = data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
        return BeamAudioPayloadHeader(sequenceNumber: sn, presentationTimestamp: ts)
    }
}

// MARK: - Audio Codec (BeamPacketHeader.flags for packet type .audio)
//
// The audio payload header is a FIXED 12 bytes and must never grow: both peers parse it by
// absolute byte range and iOS does dropFirst(BeamAudioPayloadHeader.size). The codec is
// therefore signalled in the already-reserved flags byte of BeamPacketHeader, and the
// CAPABILITY is negotiated out of band via BeamPairingMessage.supportedAudioCodecs.
//
// flags layout for type == .audio:
//   bits 0-3  codec id (mask 0x0F)   0 = Float32 interleaved PCM (legacy), 1 = AAC-LC
//   bits 4-7  reserved, must be 0, must be masked off before comparison
//
// SAFETY: every Beacon ever shipped writes flags = 0 and every Beam ever shipped ignores the
// flags byte entirely. A host that sends AAC to such a client makes it play compressed bytes
// as Float32 samples — full-scale white noise into headphones. Codec id 0 is therefore
// permanently PCM, and a non-zero id may ONLY be sent to a client that advertised support in
// the authRequest of the current connection.
enum BeamAudioCodec: UInt8 {
    /// Float32 interleaved PCM, native endianness, no sub-header. The legacy wire format.
    case pcmFloat32 = 0x00
    /// One raw AAC-LC access unit (1024 frames) per packet. No ADTS, no LATM, no length
    /// prefix — the packet's payloadLength is the access unit's explicit byte size.
    case aacLC      = 0x01

    /// Mask applied to BeamPacketHeader.flags before interpreting an audio packet.
    static let flagsMask: UInt8 = 0x0F

    /// UserDefaults key, identical on both platforms, that forces the legacy PCM path.
    /// Escape hatch for a bad release; the macOS half self-updates via Sparkle.
    static let forcePCMDefaultsKey = "BeamForcePCMAudio"

    /// Maximum size of a single AAC-LC access unit we will emit or accept, in bytes.
    static let maxAccessUnitBytes = 1536

    /// AAC-LC access unit length in frames.
    static let aacFramesPerPacket = 1024

    /// Total AAC-LC priming delay in frames (encoder priming + decoder lookahead, counted
    /// once). Used as the fallback when kAudioConverterPrimeInfo reports nothing.
    static let aacPrimingFrames = 2112

    /// Value written into BeamPacketHeader.flags for an audio packet in this codec.
    var packetFlags: UInt8 { rawValue }

    /// Decodes an audio packet's flags byte. Returns nil for an unassigned codec id, which
    /// the receiver MUST treat as "drop this packet" — never as a reason to fall through to
    /// the PCM path.
    init?(packetFlags: UInt8) {
        self.init(rawValue: packetFlags & BeamAudioCodec.flagsMask)
    }

    /// Stable string used in BeamPairingMessage.supportedAudioCodecs / .selectedAudioCodec.
    /// Strings, not an enum, so an unknown future codec can never fail decoding of the whole
    /// pairing message (which would break authentication itself).
    var wireName: String {
        switch self {
        case .pcmFloat32: return "pcm_f32le"
        case .aacLC:      return "aac_lc"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "pcm_f32le": self = .pcmFloat32
        case "aac_lc":    self = .aacLC
        default:          return nil
        }
    }

    /// What the iOS client advertises. PCM is always included and always last-resort.
    static func clientAdvertisedCodecs() -> [String] {
        if UserDefaults.standard.bool(forKey: forcePCMDefaultsKey) {
            return [BeamAudioCodec.pcmFloat32.wireName]
        }
        return [BeamAudioCodec.aacLC.wireName, BeamAudioCodec.pcmFloat32.wireName]
    }

    /// Host-side AAC bitrate for the active video preset. Bound to the preset because it is
    /// the only signal the host has for a constrained link, and the auto-tiering already
    /// drives it down on exactly those links. Halved for mono. Never above 160 kbps, which is
    /// what keeps one access unit inside a single 1400-byte packet (audio is never fragmented).
    static func aacBitrate(for preset: StreamQualityPreset, channels: Int) -> Int {
        let stereoRate: Int
        switch preset {
        case .p360_30:                                          stereoRate = 64_000
        case .p480_30:                                          stereoRate = 96_000
        case .p720_30, .p720_60, .p1080_30, .p1080_60, .auto:   stereoRate = 128_000
        }
        return channels <= 1 ? stereoRate / 2 : min(stereoRate, 160_000)
    }
}

// MARK: - Video Codec (BeamPacketHeader.flags for packet type .spsPps)
//
// Negotiated exactly like BeamAudioCodec, one layer up. CAPABILITY is advertised out of band
// via BeamPairingMessage.supportedVideoCodecs; the authoritative per-stream signal is the low
// nibble of BeamPacketHeader.flags on the .spsPps packet, because the parameter sets are what
// decide whether we build an H.264 (SPS+PPS) or HEVC (VPS+SPS+PPS) format description.
// Keep in sync with beam-macos Protocol.swift.
enum BeamVideoCodec: UInt8 {
    /// H.264 High profile. The legacy wire format and the permanent default.
    case h264 = 0x00
    /// HEVC (H.265) Main profile. Hardware-decoded on every iPhone that meets Beam's iOS 16
    /// floor (A9 and newer). ~40-50% less bitrate at equal quality.
    case hevc = 0x01

    /// Mask applied to BeamPacketHeader.flags before interpreting a .spsPps packet's codec.
    static let flagsMask: UInt8 = 0x0F

    var packetFlags: UInt8 { rawValue }

    /// Decodes a .spsPps packet's flags byte. An unassigned codec id falls back to H.264: a
    /// legacy host sends flags = 0 (H.264), and an unknown future id is safest read as the
    /// permanent default rather than a decode we can't perform.
    init(packetFlags: UInt8) {
        self = BeamVideoCodec(rawValue: packetFlags & BeamVideoCodec.flagsMask) ?? .h264
    }

    var wireName: String {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "h264": self = .h264
        case "hevc": self = .hevc
        default:     return nil
        }
    }

    /// UserDefaults key that forces the legacy H.264 path. Escape hatch mirroring the audio
    /// force-PCM key, in case an HEVC decode regression ever ships.
    static let forceH264DefaultsKey = "BeamForceH264Video"

    /// What the iOS client advertises, most-preferred first. HEVC is offered only when this
    /// device can hardware-decode it (true for every iOS 16 device, but probed rather than
    /// assumed). H.264 is always included and always last-resort.
    static func clientAdvertisedCodecs() -> [String] {
        if UserDefaults.standard.bool(forKey: forceH264DefaultsKey) {
            return [BeamVideoCodec.h264.wireName]
        }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            return [BeamVideoCodec.hevc.wireName, BeamVideoCodec.h264.wireName]
        }
        return [BeamVideoCodec.h264.wireName]
    }
}

// MARK: - Controller Input (packet type .input)

/// Fixed-size binary controller state report, sent iOS → macOS at up to 60 Hz.
/// The packet header's flags bit 0 (`connectedFlag`) indicates whether a physical
/// controller is currently attached on the phone; a packet with the flag cleared
/// carries a neutral state and tells the host to tear down its virtual gamepad.
/// Axes are full-range Int16 with GameController orientation (up/right = positive).
struct BeamControllerState: Equatable {
    static let size: Int = 14
    static let connectedFlag: UInt8 = 0x01

    struct Buttons: OptionSet, Equatable {
        let rawValue: UInt32
        static let a             = Buttons(rawValue: 1 << 0)
        static let b             = Buttons(rawValue: 1 << 1)
        static let x             = Buttons(rawValue: 1 << 2)
        static let y             = Buttons(rawValue: 1 << 3)
        static let leftShoulder  = Buttons(rawValue: 1 << 4)
        static let rightShoulder = Buttons(rawValue: 1 << 5)
        static let leftThumb     = Buttons(rawValue: 1 << 6)
        static let rightThumb    = Buttons(rawValue: 1 << 7)
        static let dpadUp        = Buttons(rawValue: 1 << 8)
        static let dpadDown      = Buttons(rawValue: 1 << 9)
        static let dpadLeft      = Buttons(rawValue: 1 << 10)
        static let dpadRight     = Buttons(rawValue: 1 << 11)
        static let menu          = Buttons(rawValue: 1 << 12)
        static let options       = Buttons(rawValue: 1 << 13)
        static let home          = Buttons(rawValue: 1 << 14)
    }

    var buttons: Buttons = []
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0
    var leftTrigger: UInt8 = 0   // 0...255
    var rightTrigger: UInt8 = 0  // 0...255

    static let neutral = BeamControllerState()

    func serialized() -> Data {
        var out = Data(capacity: BeamControllerState.size)
        var btn = buttons.rawValue.bigEndian
        Swift.withUnsafeBytes(of: &btn) { out.append(contentsOf: $0) }
        for axis in [leftX, leftY, rightX, rightY] {
            var v = axis.bigEndian
            Swift.withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        }
        out.append(leftTrigger)
        out.append(rightTrigger)
        return out
    }

    static func parse(from data: Data) -> BeamControllerState? {
        guard data.count >= BeamControllerState.size else { return nil }
        let d = Data(data)  // rebase indices to 0
        let btn = d[0..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let lx  = d[4..<6].withUnsafeBytes { $0.loadUnaligned(as: Int16.self).bigEndian }
        let ly  = d[6..<8].withUnsafeBytes { $0.loadUnaligned(as: Int16.self).bigEndian }
        let rx  = d[8..<10].withUnsafeBytes { $0.loadUnaligned(as: Int16.self).bigEndian }
        let ry  = d[10..<12].withUnsafeBytes { $0.loadUnaligned(as: Int16.self).bigEndian }
        return BeamControllerState(
            buttons: Buttons(rawValue: btn),
            leftX: lx, leftY: ly, rightX: rx, rightY: ry,
            leftTrigger: d[12], rightTrigger: d[13]
        )
    }
}

// MARK: - Control Messages

enum BeamControlMessageType: String, Codable {
    case mediaKey           = "media_key"
    case ping               = "ping"
    case pong               = "pong"
    case streamRequest      = "stream_request"
    case streamStop         = "stream_stop"
    case qualityFeedback    = "quality_feedback"
    case qualityRequest     = "quality_request"   // iOS → macOS: change to this preset
    case qualityChanged     = "quality_changed"   // macOS → iOS: current preset is now this
    case viewportLockRequest = "viewport_lock_request" // iOS → macOS: lock capture to viewport rect
    case audioFormatChanged = "audio_format_changed" // macOS → iOS: active audio sample rate/channels
    case videoPause         = "video_pause"    // iOS → macOS: hold video, keep audio flowing
    case videoResume        = "video_resume"   // iOS → macOS: resume video
    case audioEnableRequest = "audio_enable_request" // iOS → macOS: start/stop sending audio to this client (BEAM-34)
    case windowListRequest  = "window_list_request"  // iOS → macOS: send me the Mac's capturable windows (BEAM-35)
    case windowList         = "window_list"          // macOS → iOS: reply to the above
    case windowSelectRequest = "window_select_request" // iOS → macOS: lock capture to this window (0 = full display)
    case captureModeChanged = "capture_mode_changed" // macOS → iOS: what the host is capturing now
}

struct BeamControlMessage: Codable {
    let type: BeamControlMessageType
    let payload: BeamControlPayload?
}

enum BeamControlPayload: Codable {
    case mediaKey(BeamMediaKeyPayload)
    case qualityFeedback(BeamQualityFeedbackPayload)
    case qualityRequest(BeamQualityPayload)
    case qualityChanged(BeamQualityPayload)
    case viewportLock(BeamViewportLockPayload)
    case audioFormat(BeamAudioFormatPayload)
    case audioEnable(BeamAudioEnablePayload)
    case windowList(BeamWindowListPayload)
    case windowSelect(BeamWindowSelectPayload)
    case captureMode(BeamCaptureModePayload)
    case empty

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(BeamMediaKeyPayload.self)        { self = .mediaKey(v); return }
        if let v = try? container.decode(BeamQualityPayload.self)         { self = .qualityRequest(v); return }
        if let v = try? container.decode(BeamQualityFeedbackPayload.self) { self = .qualityFeedback(v); return }
        if let v = try? container.decode(BeamViewportLockPayload.self)    { self = .viewportLock(v); return }
        if let v = try? container.decode(BeamAudioFormatPayload.self)     { self = .audioFormat(v); return }
        if let v = try? container.decode(BeamAudioEnablePayload.self)     { self = .audioEnable(v); return }
        if let v = try? container.decode(BeamWindowListPayload.self)      { self = .windowList(v); return }
        if let v = try? container.decode(BeamCaptureModePayload.self)     { self = .captureMode(v); return }
        if let v = try? container.decode(BeamWindowSelectPayload.self)    { self = .windowSelect(v); return }
        self = .empty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .mediaKey(let v):        try container.encode(v)
        case .qualityFeedback(let v): try container.encode(v)
        case .qualityRequest(let v):  try container.encode(v)
        case .qualityChanged(let v):  try container.encode(v)
        case .viewportLock(let v):    try container.encode(v)
        case .audioFormat(let v):     try container.encode(v)
        case .audioEnable(let v):     try container.encode(v)
        case .windowList(let v):      try container.encode(v)
        case .windowSelect(let v):    try container.encode(v)
        case .captureMode(let v):     try container.encode(v)
        case .empty:                  try container.encodeNil()
        }
    }
}

struct BeamMediaKeyPayload: Codable {
    enum Key: String, Codable {
        case playPause      = "play_pause"
        case next           = "next"
        case previous       = "previous"
        case seekBackward   = "seek_backward"
        case seekForward    = "seek_forward"
    }
    let key: Key
    /// BEAM-39. Id of the pressed button from the host's advertised `phoneControls`. A host
    /// that advertised a layout acts on this and ignores `key`; older hosts never see it.
    /// Keep in sync with the other Protocol.swift.
    var controlID: String? = nil
}

/// Quality feedback payload — carries a 0.0–1.0 quality score from iOS to macOS.
struct BeamQualityFeedbackPayload: Codable {
    let quality: Double  // 0.0–1.0
}

/// Unified payload for qualityRequest / qualityChanged messages (both carry a preset).
struct BeamQualityPayload: Codable {
    let preset: StreamQualityPreset
}

/// Viewport lock payload used by iOS to request host-side capture cropping.
/// Values are normalized to 0...1 in the currently streamed full-display coordinate space.
struct BeamViewportLockPayload: Codable {
    let locked: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Audio format payload sent by host when active stream audio format changes.
struct BeamAudioFormatPayload: Codable {
    let sampleRate: Double
    let channels: Int
}

/// iOS → macOS (BEAM-34). Whether this client wants audio packets at all. When false the host
/// stops encoding and sending audio for this session — it is not a mute, the bytes never leave
/// the Mac. A host that predates this message logs a decode failure and keeps streaming audio,
/// which the client then mutes locally. Same intent, less bandwidth saved.
struct BeamAudioEnablePayload: Codable {
    let enabled: Bool
}

/// One capturable window on the Mac (BEAM-35). `id` is the CGWindowID, which is only stable
/// for the life of that window — the client must refresh the list rather than remember ids.
/// No thumbnails: titles and app names are enough to pick from and keep the message tiny.
struct BeamWindowInfo: Codable, Identifiable, Equatable {
    let id: UInt32
    let title: String
    let app: String
}

/// macOS → iOS (BEAM-35). Only ever sent inside an authenticated session — window titles are
/// as private as the picture itself and must never cross the pairing channel.
struct BeamWindowListPayload: Codable {
    let windows: [BeamWindowInfo]
}

/// iOS → macOS (BEAM-35). `windowID` 0 means "clear the window lock, capture the full display".
/// Required (not optional) on purpose: an all-optional payload would decode from ANY object and
/// hijack every other message in the shape-based payload decoder.
struct BeamWindowSelectPayload: Codable {
    let windowID: UInt32
}

/// macOS → iOS (BEAM-35). Broadcast to every client whenever the host switches between full
/// display and a window, from either end, and sent once right after authSuccess so a fresh
/// client starts in sync with the Mac's menu bar.
struct BeamCaptureModePayload: Codable {
    let windowMode: Bool
    let windowID: UInt32?
    let title: String?
    let app: String?
}

// MARK: - Pairing Messages

enum BeamPairingMessageType: String, Codable {
    case hello          = "hello"
    case challenge      = "challenge"
    case codeVerify     = "code_verify"
    case pairSuccess    = "pair_success"
    case pairFailed     = "pair_failed"
    case authRequest    = "auth_request"
    case authSuccess    = "auth_success"
    case authFailed     = "auth_failed"
    case unpaired       = "unpaired"    // macOS → iOS: device was unpaired by the host
}

struct BeamPairingMessage: Codable {
    let type: BeamPairingMessageType
    let deviceName: String?
    let deviceID: String?
    let code: String?
    let sharedSecret: String?
    let error: String?

    /// macOS → iOS. Addresses the host can be reached at from outside the local network —
    /// in practice its Tailscale IPv4 and MagicDNS name (BEAM-19). Sent on `pairSuccess` and
    /// on every `authSuccess`, so the phone's copy refreshes itself whenever it connects over
    /// the LAN and can't go stale if the tailnet address changes.
    ///
    /// Optional on purpose: every field here is optional, so an old client decoding a new
    /// host's message (or vice versa) simply sees nil. No version negotiation required.
    var tailscaleHosts: [String]? = nil

    /// macOS → iOS. Always true from the Beacon version that added remote access. Its
    /// ABSENCE is what carries information: a host that omits it predates the feature
    /// entirely, which needs a Beacon update — a different fix from a host that supports it
    /// but has no Tailscale installed. Both otherwise present identically as an empty
    /// `tailscaleHosts`, so without this we'd give the wrong instruction.
    /// Keep in sync with beam-macos Protocol.swift.
    var supportsRemoteAccess: Bool? = nil

    /// macOS → iOS. True only on hosts that correctly restart video when we release a warmup
    /// hold (BEAM-21). Absence means "do not hold video on this host" rather than "this host
    /// doesn't understand video_pause".
    ///
    /// A host that accepts the pause but predates the fix strands our decoder for the entire
    /// session: it drops every frame encoded while held, the opening IDR included, and its
    /// encoder never restates its parameter sets — so the picture never arrives and nothing
    /// reports an error. Warmup buys smoother relayed starts; it is not worth a black stream,
    /// so on an older Beacon we simply don't hold video.
    /// Keep in sync with beam-macos Protocol.swift.
    var supportsVideoHold: Bool? = nil

    /// iOS → macOS. The client's native hardware sample rate, sent at auth (BEAM-29).
    ///
    /// Previously the host chose a rate and the client reacted to audioFormatChanged, which
    /// left a window at every session start where the client had to GUESS: it built its engine
    /// at a default, then tore the whole chain down when the real rate arrived. Guessing wrong
    /// played audio at the wrong speed for those first moments.
    ///
    /// The client is the party that actually knows this value, so it states it up front and the
    /// host encodes to match. Optional like every other field here, so an older host simply
    /// ignores it and the existing audioFormatChanged path still applies.
    var preferredAudioSampleRate: Double? = nil


    /// iOS → macOS. Wire names of the audio codecs this client can decode, most-preferred
    /// first (e.g. ["aac_lc", "pcm_f32le"]). Sent on `hello` and on EVERY `authRequest`.
    ///
    /// `nil` is the load-bearing case: a client that omits this field predates audio codec
    /// negotiation and can decode ONLY Float32 interleaved PCM. The host MUST then send every
    /// audio packet with codec id 0 for the whole session. Feeding such a client AAC bytes
    /// produces full-scale white noise in someone's ears, so absence is never optimistic.
    /// An EMPTY array means the same thing as ["pcm_f32le"] — never "anything goes".
    ///
    /// Typed as [String] rather than [BeamAudioCodec] on purpose: an unknown enum case would
    /// fail decoding of the ENTIRE pairing message, which would break authentication itself.
    /// Unknown strings must be silently ignored.
    var supportedAudioCodecs: [String]? = nil

    /// macOS → iOS. Wire name of the codec the host has chosen for this session, echoed on
    /// `authSuccess`. Diagnostic/telemetry only — the authority for how to decode any given
    /// packet is always that packet's BeamPacketHeader.flags, because the host may fall back
    /// to PCM mid-session if its encoder fails. `nil` = host predates negotiation = PCM.
    var selectedAudioCodec: String? = nil

    /// iOS → macOS. Wire names of the video codecs this client can decode, most-preferred
    /// first (e.g. ["hevc", "h264"]). Sent on `hello` and on EVERY `authRequest`. Absence, or
    /// absence of "hevc", means an H.264-only client and the host must encode H.264 for the
    /// whole session. Typed as [String] so an unknown codec can't fail the whole pairing
    /// message. Keep in sync with beam-macos Protocol.swift.
    var supportedVideoCodecs: [String]? = nil

    /// macOS → iOS. Wire name of the codec the host negotiated for this client, echoed on
    /// `authSuccess`. Diagnostic only — the authority for how to decode video is always the
    /// .spsPps packet's BeamPacketHeader.flags. `nil` = host predates negotiation = H.264.
    var selectedVideoCodec: String? = nil

    /// iOS → macOS (BEAM-34). False means "do not send me audio for this session". Sent on
    /// `authRequest` so the host never encodes a single audio packet for a client that has
    /// audio switched off. Absence means true — an older client always wants audio.
    /// Keep in sync with the other Protocol.swift.
    var wantsAudio: Bool? = nil

    /// macOS → iOS (BEAM-34). True on hosts that honour `wantsAudio` and `audio_enable_request`.
    /// Absence means the host will stream audio regardless, so the client must mute locally
    /// instead and can tell the user a Beacon update would save bandwidth.
    var supportsAudioToggle: Bool? = nil

    /// macOS → iOS (BEAM-35). True on hosts that answer `window_list_request` and honour
    /// `window_select_request`. Absence hides the window picker on the phone entirely.
    var supportsWindowSelection: Bool? = nil

    /// macOS → iOS (BEAM-39). What the phone's media buttons are configured to do on the Mac,
    /// so the phone can show the icon Kevin picked in Beacon Settings. Keyed by the same
    /// wire names as BeamMediaKeyPayload.Key. Absence = host predates the feature = default
    /// glyphs. Unknown or unavailable symbols fall back to the default glyph on the phone.
    /// Keep in sync with the other Protocol.swift.
    var phoneControls: [BeamPhoneControl]? = nil
}

/// BEAM-39. One button of the host's active phone-control layout, in left-to-right order.
/// Up to 7 per layout. The phone renders exactly this list; a tap sends the button's `id`
/// back in BeamMediaKeyPayload.controlID.
struct BeamPhoneControl: Codable, Equatable {
    /// Stable button id within the layout (UUID string). Not semantic.
    let id: String
    /// SF Symbol name chosen on the Mac.
    let symbol: String
    /// Short accessibility label / tooltip, e.g. "Back 10s" or "Next tab".
    let label: String
    /// True for the one emphasised (larger) button, normally play/pause in the middle.
    var prominent: Bool? = nil
}

// MARK: - Helpers

extension CMTime {
    var microseconds: Int64 {
        guard timescale != 0 else { return 0 }
        return Int64(Double(value) / Double(timescale) * 1_000_000)
    }

    static func fromMicroseconds(_ us: Int64) -> CMTime {
        CMTime(value: CMTimeValue(us), timescale: 1_000_000)
    }
}

extension Data {
    func lengthPrefixed() -> Data {
        var out = Data(capacity: 4 + count)
        var len = UInt32(count).bigEndian
        Swift.withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(self)
        return out
    }

    init?(hexEncoded hex: String) {
        guard hex.count % 2 == 0 else { return nil }
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
