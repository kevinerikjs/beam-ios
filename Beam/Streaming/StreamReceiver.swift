// StreamReceiver.swift
// Receives video + audio payloads and feeds video to VideoRenderer and audio to AudioPlayer.
//
// Reassembly, sequencing, format descriptions, sample buffers and AAC decoding come
// from PhorosSession and PhorosMedia. What stays here is Beam's plumbing: the queue,
// the renderer and player hand-off, the diagnostic log, and the "wait for the host's
// real audio format before building a decoder" rule.

import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Phoros
import PhorosMedia
import PhorosSession

private let logger = Logger(subsystem: "com.beam.ios", category: "StreamReceiver")

final class StreamReceiver {

    weak var videoRenderer: VideoRenderer?
    weak var audioPlayer: AudioPlayer?

    /// Encoded frame size, from the SPS. Fires whenever it changes: the host switches frame
    /// shape when it locks onto a window (BEAM-38) and the overlay geometry must follow.
    var onVideoDimensionsChanged: ((CGSize) -> Void)?
    private var lastVideoDimensions: CGSize = .zero

    // Video
    private var assembler = FrameAssembler()
    /// Built from the most recent .parameterSets packet; reused for every frame.
    private(set) var cachedFormatDesc: CMFormatDescription?

    // Audio
    private var sequenceGuard = AudioSequenceGuard()
    /// Codec of the last accepted audio packet. A change means the host switched
    /// representations mid-session (e.g. its encoder failed and it degraded to PCM); the
    /// decoder is torn down and A/V sync re-anchored so no bytes are ever reinterpreted
    /// with the previous codec.
    private var lastAudioCodec: AudioCodecID?
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
            assembler.reset()
            cachedFormatDesc = nil
            sequenceGuard.reset()
            lastAudioCodec = nil
            resetAudioDecoder()
            audioPlayer?.resetSync()
        }
    }

    // MARK: - Parameter Sets

    func receiveParameterSets(_ data: Data, codec: VideoCodecID) {
        assemblyQueue.async { [weak self] in
            guard let self else { return }
            guard let description = VideoFormat.makeDescription(parameterSets: data, codec: codec) else {
                logger.error("Failed to build format description from \(codec.wireName) parameter sets")
                DiagnosticLogger.shared.log("\(codec.wireName) parameter set parse failed — video decode will not work", category: "Video")
                return
            }
            cachedFormatDesc = description
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            if size != lastVideoDimensions, size.width > 0, size.height > 0 {
                lastVideoDimensions = size
                DiagnosticLogger.shared.log("Video frame size \(Int(size.width))x\(Int(size.height))", category: "Video")
                onVideoDimensionsChanged?(size)
            }
            logger.info("Received \(codec.wireName) parameter sets (\(data.count) bytes)")
            DiagnosticLogger.shared.log("\(codec.wireName) parameter sets received (\(data.count) bytes)", category: "Video")
        }
    }

    // MARK: - Video

    func receive(videoPayload: Data, isKeyframe: Bool) {
        assemblyQueue.async { [weak self] in
            guard let self, let frame = assembler.receive(videoPayload, isKeyframe: isKeyframe) else { return }
            deliver(frame)
        }
    }

    private func deliver(_ frame: AssembledFrame) {
        guard let renderer = videoRenderer, let description = cachedFormatDesc else { return }

        // Stamp with the local host time so AVSampleBufferDisplayLayer renders immediately.
        // The Mac's PTS is on the Mac's clock; scheduling against it displays nothing.
        let localPTS = CMClockGetTime(CMClockGetHostTimeClock())
        guard let sampleBuffer = VideoFormat.makeSampleBuffer(annexB: frame.bitstream, formatDescription: description, presentationTime: localPTS) else {
            logger.error("Failed to build sample buffer for frame \(frame.frameNumber)")
            DiagnosticLogger.shared.log(
                "Sample buffer build failed for frame \(frame.frameNumber) (keyframe=\(frame.isKeyframe))",
                category: "Video"
            )
            return
        }
        audioPlayer?.updateVideoClock(remotePresentationTimestampUs: frame.presentationTimestamp)

        DispatchQueue.main.async {
            renderer.enqueue(sampleBuffer)
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

    /// Handles one audio packet. `flags` is the raw `PacketHeader.flags` byte; its low
    /// nibble is the codec id. An unknown codec id is DROPPED rather than fed to the PCM path:
    /// playing compressed bytes as Float32 samples is full-scale white noise.
    func receive(audioPayload: Data, flags: UInt8, player: AudioPlayer) {
        guard let codec = AudioCodecID(packetFlags: flags) else { return }
        guard let header = AudioChunkHeader.parse(from: audioPayload) else { return }

        switch sequenceGuard.accept(header.sequenceNumber) {
        case .accept:
            break
        case .duplicate:
            return
        case .restarted:
            // The transport is TCP and never reorders, so a large backward jump means the
            // host restarted its sequence. Re-anchor instead of silencing audio forever.
            DiagnosticLogger.shared.log("RECOVERY[audio-sequence]: host restarted its sequence — re-anchoring", category: "Audio")
        }

        // Codec transition (host fell back to PCM mid-session, or upgraded): rebuild.
        if codec != lastAudioCodec {
            DiagnosticLogger.shared.log("Audio codec \(lastAudioCodec?.wireName ?? "none") → \(codec.wireName)", category: "Audio")
            aacDecoder = nil
            player.resetSync()
            lastAudioCodec = codec
        }

        decoderResetLock.lock()
        let shouldResetDecoder = decoderResetRequested
        decoderResetRequested = false
        decoderResetLock.unlock()
        if shouldResetDecoder { aacDecoder = nil }

        let body = Data(audioPayload.dropFirst(AudioChunkHeader.size))

        switch codec {
        case .pcmFloat32:
            player.enqueue(body, remotePresentationTimestampUs: header.presentationTimestamp)

        case .aacLC:
            guard (1...AudioCodecID.maxAccessUnitBytes).contains(body.count) else { return }
            // Wait for the host's real format before building a decoder. Building eagerly at
            // the 44100 default produced a decoder at the wrong rate for the first packets and
            // an immediate rebuild, discarding the first audio of every session.
            guard player.hasRemoteFormat else { return }
            let rate = player.currentSampleRate
            let channels = player.currentChannels
            if let existing = aacDecoder, existing.sampleRate != rate || existing.channels != channels {
                aacDecoder = nil
            }
            if aacDecoder == nil {
                aacDecoder = AACDecoder(sampleRate: rate, channels: channels)
                guard aacDecoder != nil else {
                    DiagnosticLogger.shared.log("AAC decoder init failed (\(Int(rate))Hz \(channels)ch) — dropping audio", category: "Audio")
                    return
                }
                DiagnosticLogger.shared.log("AAC-LC decoder ready (\(Int(rate))Hz \(channels)ch)", category: "Audio")
            }
            guard let decoder = aacDecoder else { return }
            guard let buffer = decoder.decode(body) else {
                // A wedged decoder is otherwise unrecoverable for the whole session. Isolated
                // failures are expected after packet loss, so tolerate a few, then rebuild.
                // AAC-LC access units are independently decodable, so a fresh decoder resyncs
                // on the very next packet.
                consecutiveDecodeFailures += 1
                if consecutiveDecodeFailures >= Self.maxDecodeFailuresBeforeReset {
                    DiagnosticLogger.shared.log("AAC decode failed \(consecutiveDecodeFailures)x — rebuilding decoder", category: "Audio")
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
}
