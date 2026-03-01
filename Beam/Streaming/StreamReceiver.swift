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
    private var cachedFormatDesc: CMFormatDescription?

    // Audio sequence tracking
    private var lastAudioSequenceNumber: UInt32 = UInt32.max

    private let assemblyQueue = DispatchQueue(label: "com.beam.ios.assembly", qos: .userInteractive)

    func reset() {
        assemblyQueue.async { [weak self] in
            guard let self else { return }
            parameterSets = nil
            frameBuffers.removeAll()
            cachedFormatDesc = nil
            lastDeliveredFrameNumber = UInt32.max
            lastAudioSequenceNumber = UInt32.max
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
            logger.info("Received SPS/PPS parameter sets (\(data.count) bytes)")
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

    func receive(audioPayload: Data, player: AudioPlayer) {
        guard let header = BeamAudioPayloadHeader.parse(from: audioPayload) else { return }
        if lastAudioSequenceNumber != UInt32.max,
           !isNewerAudioSequence(header.sequenceNumber, than: lastAudioSequenceNumber) {
            return
        }
        lastAudioSequenceNumber = header.sequenceNumber

        let pcmData = Data(audioPayload.dropFirst(BeamAudioPayloadHeader.size))
        player.enqueue(pcmData, remotePresentationTimestampUs: header.presentationTimestamp)
    }

    private func isNewerAudioSequence(_ sequence: UInt32, than previous: UInt32) -> Bool {
        let diff = sequence &- previous
        return diff != 0 && diff < (UInt32.max / 2)
    }
}
