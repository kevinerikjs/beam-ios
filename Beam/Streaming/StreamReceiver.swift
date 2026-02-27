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

    // SPS/PPS parameter sets for H.264
    private var parameterSets: Data? = nil

    // In-flight video frame assembly
    private var frameBuffers: [UInt32: VideoFrameBuffer] = [:]
    private var lastDeliveredFrameNumber: UInt32 = UInt32.max

    // Audio sequence tracking
    private var lastAudioSequenceNumber: UInt32 = UInt32.max

    private let assemblyQueue = DispatchQueue(label: "com.beam.ios.assembly", qos: .userInteractive)

    // MARK: - Parameter Sets

    func receiveParameterSets(_ data: Data) {
        assemblyQueue.async { [weak self] in
            self?.parameterSets = data
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

        DispatchQueue.main.async {
            renderer.enqueue(sampleBuffer)
        }
    }

    private func buildSampleBuffer(from annexBData: Data, pts: CMTime, isKeyframe: Bool) -> CMSampleBuffer? {
        // Allocate an owned CMBlockBuffer and copy the Annex B bytes into it.
        // We must not point directly into annexBData: that Data goes out of scope
        // before AVSampleBufferDisplayLayer consumes the buffer on the main thread,
        // causing a use-after-free crash (EXC_BAD_ACCESS).
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,                   // CF allocates the memory
            blockLength: annexBData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: annexBData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        // Copy the Annex B payload into the CF-owned buffer
        status = annexBData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: annexBData.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // Format description (needed for keyframes; subsequent frames can reuse)
        var formatDesc: CMFormatDescription?
        if isKeyframe, let paramData = parameterSets {
            buildFormatDescription(from: paramData, into: &formatDesc)
        }

        // Build sample buffer
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sampleSize = annexBData.count
        var sampleSizeCopy = sampleSize

        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeCopy,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
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
        let aacData = Data(audioPayload.dropFirst(BeamAudioPayloadHeader.size))
        let pts = CMTime.fromMicroseconds(header.presentationTimestamp)
        player.enqueue(aacData, presentationTime: pts)
    }
}
