// Protocol.swift
// Beam Network Protocol - iOS client side.
// IMPORTANT: This file must stay in sync with beam-macos/BeamHost/Network/Protocol.swift
// Consider using a Swift Package to share this code in the future.

import Foundation
import CoreMedia

// MARK: - Packet Types

enum BeamPacketType: UInt8 {
    case video      = 0x01
    case audio      = 0x02
    case control    = 0x03
    case heartbeat  = 0x04
    case spsPps     = 0x05
    case videoIDR   = 0x06
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

// MARK: - Control Messages

enum BeamControlMessageType: String, Codable {
    case mediaKey           = "media_key"
    case ping               = "ping"
    case pong               = "pong"
    case streamRequest      = "stream_request"
    case streamStop         = "stream_stop"
    case qualityFeedback    = "quality_feedback"
}

struct BeamControlMessage: Codable {
    let type: BeamControlMessageType
    let payload: BeamControlPayload?
}

enum BeamControlPayload: Codable {
    case mediaKey(BeamMediaKeyPayload)
    case qualityFeedback(BeamQualityFeedbackPayload)
    case empty

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let mk = try? container.decode(BeamMediaKeyPayload.self) {
            self = .mediaKey(mk)
        } else if let qf = try? container.decode(BeamQualityFeedbackPayload.self) {
            self = .qualityFeedback(qf)
        } else {
            self = .empty
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .mediaKey(let mk):     try container.encode(mk)
        case .qualityFeedback(let qf): try container.encode(qf)
        case .empty:                try container.encodeNil()
        }
    }
}

struct BeamMediaKeyPayload: Codable {
    enum Key: String, Codable {
        case playPause  = "play_pause"
        case next       = "next"
        case previous   = "previous"
    }
    let key: Key
}

struct BeamQualityFeedbackPayload: Codable {
    let droppedFrames: Int
    let bufferMs: Int
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
}

struct BeamPairingMessage: Codable {
    let type: BeamPairingMessageType
    let deviceName: String?
    let deviceID: String?
    let code: String?
    let sharedSecret: String?
    let error: String?
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
