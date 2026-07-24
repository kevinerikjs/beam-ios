// StreamReceiver.swift
// Receives and reassembles fragmented video + audio packets.
// Feeds video to VideoRenderer and audio to AudioPlayer.

import Foundation
import AVFoundation
import CoreMedia
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "StreamReceiver")

// MARK: - Fragment Buffer

private struct VideoFrameBuffer {
    let frameNumber: UInt32
    let totalFragments: UInt16
    let presentationTimestamp: Int64
    var fragments: [UInt16: Data]  // fragmentIndex → data

    var isComplete: Bool {
        fragments.count == Int(totalFragments)
    }

    func assembled() -> Data? {
        guard isComplete else { return nil }
        return (0..<totalFragments).compactMap { fragments[UInt16($0)] }.reduce(Data(), +)
    }
}

// MARK: - StreamReceiver

final class StreamReceiver {

    weak var videoRenderer: VideoRenderer?
    weak var audioPlayer: AudioPlayer?

    // SPS/PPS parameter sets for H.264
    private var parameterSets: Data? = nil

    // In-flight video frame assembly
    private var frameBuffers: [UInt32: VideoFrameBuffer] = [:]
    private var lastDeliveredFrameNumber: UInt32 = UInt32.max

    // Cached format description — built once from SPS/PPS, reused for every frame
    private(set) var cachedFormatDesc: CMFormatDescription?

    // Audio sequence tracking
    private var lastAudioSequenceNumber: UInt32 = UInt32.max
    /// Codec of the last accepted audio packet. A change means the host switched
    /// representations mid-session (e.g. its encoder failed and it degraded to PCM); the
    /// decoder is torn down and A/V sync re-anchored so no bytes are ever reinterpreted
    /// with the previous codec.
    private var lastAudioCodec: BeamAudioCodec?
    private var aacDecoder: AACDecoder?
    /// Consecutive AAC decode failures, used to self-heal a wedged decoder.
    private var consecutiveDecodeFailures = 0
    private static let maxDecodeFailuresBeforeReset = 5
    private let decoderResetLock = NSLock()
    private var decoderResetRequested = false

    private let assemblyQueue = DispatchQueue(label: "com.beam.ios.assembly", qos: .userInteractive)

    func reset() {
        assemblyQueue.async { [weak self] in
            guard let self else { return }
            parameterSets = nil
            frameBuffers.removeAll()
            cachedFormatDesc = nil
            lastDeliveredFrameNumber = UInt32.max
            lastAudioSequenceNumber = UInt32.max
            lastAudioCodec = nil
            resetAudioDecoder()
            audioPlayer?.resetSync()
        }
    }

    // MARK: - Parameter Sets

    func receiveParameterSets(_ data: Data) {
        assemblyQueue.async { [weak self] in
            guard let self else { return }
            self.parameterSets = data
            // Pre-build and cache the format description so it's ready for the first IDR frame
            var desc: CMFormatDescription?
            self.buildFormatDescription(from: data, into: &desc)
            self.cachedFormatDesc = desc
            if desc != nil {
                logger.info("Received SPS/PPS parameter sets (\(data.count) bytes)")
                DiagnosticLogger.shared.log("SPS/PPS received (\(data.count) bytes)", category: "Video")
            } else {
                logger.error("Failed to build format description from SPS/PPS")
                DiagnosticLogger.shared.log("SPS/PPS parse failed — video decode will not work", category: "Video")
            }
        }
    }

    // MARK: - Video

    func receive(videoPayload: Data, isKeyframe: Bool) {
        assemblyQueue.async { [weak self] in
            self?.processVideoPayload(videoPayload, isKeyframe: isKeyframe)
        }
    }

    private func processVideoPayload(_ data: Data, isKeyframe: Bool) {
        guard let header = BeamVideoPayloadHeader.parse(from: data) else { return }
        let nalData = Data(data.dropFirst(BeamVideoPayloadHeader.size))

        if header.totalFragments == 1 {
            // Single-fragment frame - deliver immediately
            deliverVideoFrame(
                nalData,
                frameNumber: header.frameNumber,
                pts: header.presentationTimestamp,
                isKeyframe: isKeyframe
            )
        } else {
            // Multi-fragment frame - buffer until complete
            if frameBuffers[header.frameNumber] == nil {
                frameBuffers[header.frameNumber] = VideoFrameBuffer(
                    frameNumber: header.frameNumber,
                    totalFragments: header.totalFragments,
                    presentationTimestamp: header.presentationTimestamp,
                    fragments: [:]
                )
            }
            frameBuffers[header.frameNumber]?.fragments[header.fragmentIndex] = nalData

            if let buffer = frameBuffers[header.frameNumber], buffer.isComplete,
               let assembled = buffer.assembled() {
                frameBuffers.removeValue(forKey: header.frameNumber)
                deliverVideoFrame(
                    assembled,
                    frameNumber: header.frameNumber,
                    pts: buffer.presentationTimestamp,
                    isKeyframe: isKeyframe
                )
            }
        }

        // Clean up stale frame buffers (frames older than 10 frames back)
        let staleThreshold = header.frameNumber > 10 ? header.frameNumber - 10 : 0
        frameBuffers = frameBuffers.filter { $0.key >= staleThreshold }
    }

    private func deliverVideoFrame(
        _ annexBData: Data,
        frameNumber: UInt32,
        pts: Int64,
        isKeyframe: Bool
    ) {
        guard let renderer = videoRenderer else { return }

        let presentationTime = CMTime.fromMicroseconds(pts)

        // Build CMSampleBuffer from Annex B data
        guard let sampleBuffer = buildSampleBuffer(from: annexBData, pts: presentationTime, isKeyframe: isKeyframe) else {
            logger.error("Failed to build sample buffer for frame \(frameNumber)")
            DiagnosticLogger.shared.log(
                "Sample buffer build failed for frame \(frameNumber) (keyframe=\(isKeyframe), hasFormatDesc=\(cachedFormatDesc != nil))",
                category: "Video"
            )
            return
        }
        audioPlayer?.updateVideoClock(remotePresentationTimestampUs: pts)

        DispatchQueue.main.async {
            renderer.enqueue(sampleBuffer)
        }
    }

    private func buildSampleBuffer(from annexBData: Data, pts: CMTime, isKeyframe: Bool) -> CMSampleBuffer? {
        // AVSampleBufferDisplayLayer with a CMVideoFormatDescription from
        // CMVideoFormatDescriptionCreateFromH264ParameterSets(nalUnitHeaderLength: 4) expects
        // AVCC format (4-byte big-endian length prefix before each NAL unit), NOT Annex B.
        // Convert here since the macOS side sends Annex B over the wire.
        let avccData = annexBToAVCC(annexBData)
        guard !avccData.isEmpty else { return nil }

        // Allocate CF-owned CMBlockBuffer and copy the AVCC bytes in.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = avccData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // Stamp with the iOS local host time so AVSampleBufferDisplayLayer renders immediately.
        // The macOS PTS is from the Mac's host clock (unrelated scale to iPhone's host clock),
        // so using it directly would schedule frames years into the past/future and drop them.
        let localPTS = CMClockGetTime(CMClockGetHostTimeClock())
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: localPTS,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeCopy = avccData.count

        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: cachedFormatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeCopy,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }

    /// Convert Annex B (0x00 0x00 0x00 0x01 start-code prefixed) → AVCC (4-byte big-endian length prefixed).
    /// This is the inverse of VideoEncoder.convertToAnnexB on the macOS side.
    private func annexBToAVCC(_ annexB: Data) -> Data {
        var result = Data()
        var offset = 0
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        while offset + 4 <= annexB.count {
            guard Array(annexB[offset..<offset+4]) == startCode else { offset += 1; continue }
            offset += 4  // skip start code

            // Find the end of this NAL unit (next start code or end of buffer)
            var end = offset
            while end + 4 <= annexB.count {
                if Array(annexB[end..<end+4]) == startCode { break }
                end += 1
            }
            if end + 4 > annexB.count { end = annexB.count }

            let nalLength = end - offset
            guard nalLength > 0 else { continue }

            // Write 4-byte big-endian length prefix
            var length = UInt32(nalLength).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(annexB[offset..<end])
            offset = end
        }

        return result
    }

    private func buildFormatDescription(from spsPpsData: Data, into desc: inout CMFormatDescription?) {
        // Parse SPS/PPS from Annex B formatted data
        // Find start codes and extract NAL units
        var nalUnits: [Data] = []
        var offset = 0
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        while offset < spsPpsData.count - 4 {
            if Array(spsPpsData[offset..<offset+4]) == startCode {
                var end = offset + 4
                while end < spsPpsData.count - 4 {
                    if Array(spsPpsData[end..<end+4]) == startCode { break }
                    end += 1
                }
                if end == spsPpsData.count - 4 { end = spsPpsData.count }
                nalUnits.append(Data(spsPpsData[(offset+4)..<end]))
                offset = end
            } else {
                offset += 1
            }
        }

        guard nalUnits.count >= 2 else { return }

        let spsData = nalUnits[0]
        let ppsData = nalUnits[1]

        spsData.withUnsafeBytes { spsPtr in
            ppsData.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                // Build non-optional pointer array for CMVideoFormatDescriptionCreateFromH264ParameterSets
                let paramPtrs: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let paramSizes: [Int] = [spsData.count, ppsData.count]

                paramPtrs.withUnsafeBufferPointer { ptrs in
                    paramSizes.withUnsafeBufferPointer { sizes in
                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: sizes.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                    }
                }
            }
        }
    }

    // MARK: - Audio

    /// Discards the AAC decoder so the next AAC packet rebuilds it against the current
    /// negotiated sample rate / channel count. Called when `audio_format_changed` arrives.
    func resetAudioDecoder() {
        decoderResetLock.lock()
        decoderResetRequested = true
        decoderResetLock.unlock()
    }

    /// Handles one audio packet. `flags` is the raw `BeamPacketHeader.flags` byte; its low
    /// nibble is the codec id. Codec id 0 is Float32 PCM forever (that is what every shipped
    /// Beacon sends), and an unknown codec id is DROPPED rather than fed to the PCM path —
    /// playing compressed bytes as Float32 samples is full-scale white noise.
    func receive(audioPayload: Data, flags: UInt8, player: AudioPlayer) {
        // 1. Unknown codec id ⇒ drop. Never touch the decoder, never fall through to PCM.
        guard let codec = BeamAudioCodec(packetFlags: flags) else { return }

        // 2. Header parse + reorder guard (unchanged).
        guard let header = BeamAudioPayloadHeader.parse(from: audioPayload) else { return }
        if lastAudioSequenceNumber != UInt32.max,
           !isNewerAudioSequence(header.sequenceNumber, than: lastAudioSequenceNumber) {
            // A latch by construction: the drop path did not advance the counter, so once one
            // packet landed in the backward half-window EVERY subsequent packet did too, for
            // the life of the session. The transport is TCP and never reorders, so a large
            // backward jump means the host restarted its sequence, not a stale packet —
            // re-anchor instead of silencing audio forever.
            let backwardDelta = lastAudioSequenceNumber &- header.sequenceNumber
            if backwardDelta > 256 {
                DiagnosticLogger.shared.log(
                    "RECOVERY[audio-sequence]: sequence jumped back \(backwardDelta) — re-anchoring",
                    category: "Audio"
                )
                lastAudioSequenceNumber = header.sequenceNumber
            } else {
                return
            }
        } else {
            lastAudioSequenceNumber = header.sequenceNumber
        }

        // 3. Codec transition (host fell back to PCM mid-session, or upgraded): rebuild.
        if codec != lastAudioCodec {
            DiagnosticLogger.shared.log(
                "Audio codec \(lastAudioCodec?.wireName ?? "none") → \(codec.wireName)",
                category: "Audio"
            )
            aacDecoder = nil
            player.resetSync()
            lastAudioCodec = codec
        }

        // Pending decoder invalidation from audio_format_changed / reset().
        decoderResetLock.lock()
        let shouldResetDecoder = decoderResetRequested
        decoderResetRequested = false
        decoderResetLock.unlock()
        if shouldResetDecoder { aacDecoder = nil }

        // 4. Payload header is still exactly 12 bytes in both codecs.
        let body = Data(audioPayload.dropFirst(BeamAudioPayloadHeader.size))

        switch codec {
        case .pcmFloat32:
            player.enqueue(body, remotePresentationTimestampUs: header.presentationTimestamp)

        case .aacLC:
            guard (1...BeamAudioCodec.maxAccessUnitBytes).contains(body.count) else { return }
            // Wait for the host's real format before building a decoder. The snapshot starts
            // at a 44100 default and is corrected the moment audioFormatChanged arrives, so
            // building eagerly produced a decoder at the wrong rate for the first packets and
            // an immediate rebuild — visible in the logs as "decoder ready (44100Hz)" followed
            // by "(48000Hz)" milliseconds later. Harmless but wasteful, and it discards the
            // first audio of every session.
            guard player.hasRemoteFormat else { return }
            let rate = player.currentSampleRate
            let channels = player.currentChannels
            if let existing = aacDecoder, existing.sampleRate != rate || existing.channels != channels {
                aacDecoder = nil
            }
            if aacDecoder == nil {
                aacDecoder = AACDecoder(sampleRate: rate, channels: channels)
                if aacDecoder == nil {
                    DiagnosticLogger.shared.log(
                        "AAC decoder init failed (\(Int(rate))Hz \(channels)ch) — dropping audio",
                        category: "Audio"
                    )
                    return
                }
                DiagnosticLogger.shared.log(
                    "AAC-LC decoder ready (\(Int(rate))Hz \(channels)ch)",
                    category: "Audio"
                )
            }
            guard let decoder = aacDecoder else { return }
            guard let buffer = decoder.decode(accessUnit: body) else {
                // A wedged decoder is otherwise unrecoverable for the whole session. The
                // starvation-recovery safety net lives in AudioPlayer, DOWNSTREAM of here, so
                // it never fires when decoding is what's failing: audio simply stops forever
                // while video keeps going. That is exactly the reported symptom — a stutter
                // damages the stream, video resumes with artefacts, audio never returns.
                //
                // Isolated failures are expected after packet loss, so tolerate a few, then
                // rebuild. AAC-LC access units are independently decodable, so a fresh decoder
                // resyncs on the very next packet.
                consecutiveDecodeFailures += 1
                if consecutiveDecodeFailures >= Self.maxDecodeFailuresBeforeReset {
                    DiagnosticLogger.shared.log(
                        "AAC decode failed \(consecutiveDecodeFailures)x — rebuilding decoder",
                        category: "Audio"
                    )
                    aacDecoder = nil
                    consecutiveDecodeFailures = 0
                    player.resetSync()
                }
                return
            }
            consecutiveDecodeFailures = 0
            player.enqueue(buffer: buffer, remotePresentationTimestampUs: header.presentationTimestamp)
        }
    }

    private func isNewerAudioSequence(_ sequence: UInt32, than previous: UInt32) -> Bool {
        let diff = sequence &- previous
        return diff != 0 && diff < (UInt32.max / 2)
    }
}
