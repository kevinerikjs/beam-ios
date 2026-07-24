// AACDecoder.swift
// Decodes raw AAC-LC access units (one 1024-frame AU per network packet, no ADTS/LATM/ASC)
// into non-interleaved Float32 PCM buffers that match AudioPlayer's output format exactly,
// so the decoded buffer can be scheduled with no further conversion.
//
// IMPORTANT: this performs NO priming trim and NO timestamp adjustment. The host already
// shifts each access unit's PTS back by the AAC priming delay; compensating again here would
// double-correct and push audio permanently early.

import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "AACDecoder")

final class AACDecoder {

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let framesPerPacket: AVAudioFrameCount

    let sampleRate: Double
    let channels: AVAudioChannelCount

    init?(sampleRate: Double, channels: AVAudioChannelCount) {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate       = sampleRate
        asbd.mFormatID         = kAudioFormatMPEG4AAC
        asbd.mFormatFlags      = 0
        asbd.mBytesPerPacket   = 0
        asbd.mFramesPerPacket  = UInt32(BeamAudioCodec.aacFramesPerPacket)
        asbd.mBytesPerFrame    = 0
        asbd.mChannelsPerFrame = UInt32(channels)
        asbd.mBitsPerChannel   = 0
        asbd.mReserved         = 0

        guard let inFormat = AVAudioFormat(streamDescription: &asbd) else {
            logger.error("Failed to build AAC input format (\(sampleRate)Hz \(channels)ch)")
            return nil
        }
        // Byte-identical to AudioPlayer.makeOutputFormat().
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            logger.error("Failed to build PCM output format (\(sampleRate)Hz \(channels)ch)")
            return nil
        }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            logger.error("AVAudioConverter creation failed for AAC-LC decode")
            return nil
        }

        self.converter = conv
        self.inputFormat = inFormat
        self.outputFormat = outFormat
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerPacket = AVAudioFrameCount(
            max(1, inFormat.streamDescription.pointee.mFramesPerPacket)
        )
    }

    func reset() {
        converter.reset()
    }

    /// Decodes ONE raw AAC-LC access unit. Returns nil on any error; the caller drops the packet.
    func decode(accessUnit: Data) -> AVAudioPCMBuffer? {
        guard accessUnit.count > 0, accessUnit.count <= BeamAudioCodec.maxAccessUnitBytes else {
            return nil
        }

        let compressed = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: BeamAudioCodec.maxAccessUnitBytes
        )

        accessUnit.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(compressed.data, base, accessUnit.count)
        }
        compressed.byteLength = UInt32(accessUnit.count)
        compressed.packetCount = 1
        if let descs = compressed.packetDescriptions {
            descs[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(accessUnit.count)
            )
        }

        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: framesPerPacket) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }

        switch status {
        case .haveData:
            guard out.frameLength > 0 else { return nil }
            return out
        case .inputRanDry, .endOfStream:
            // The decoder swallowed this AU without emitting frames (normal for the very first
            // access unit while it primes). Nothing to schedule.
            return nil
        case .error:
            logger.error("AAC decode failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        @unknown default:
            return nil
        }
    }
}
