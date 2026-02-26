// AudioPlayer.swift
// AVAudioEngine-based audio playback for the received AAC-LC ADTS stream.

import AVFoundation
import CoreMedia
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "AudioPlayer")

final class AudioPlayer {

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var converter: AVAudioConverter?

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44100,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Lifecycle

    func start() {
        setupAudioSession()
        setupEngine()
    }

    func stop() {
        engine?.stop()
        playerNode?.stop()
        engine = nil
        playerNode = nil
        converter = nil
        logger.info("AudioPlayer stopped")
    }

    // MARK: - Setup

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothHFP, .allowAirPlay]
            )
            try session.setActive(true)
        } catch {
            logger.error("Failed to configure audio session: \(error)")
        }
    }

    private func setupEngine() {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        do {
            try engine.start()
            playerNode.play()
            self.engine = engine
            self.playerNode = playerNode
            logger.info("AudioPlayer engine started")
        } catch {
            logger.error("Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Enqueue

    func enqueue(_ adtsData: Data, presentationTime: CMTime) {
        guard let playerNode else { return }

        // Decode ADTS AAC → PCM using AVAudioConverter
        guard let pcmBuffer = decodeAAC(adtsData) else { return }

        playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    // MARK: - AAC Decoding

    private func decodeAAC(_ adtsData: Data) -> AVAudioPCMBuffer? {
        // Parse ADTS header to get format info
        guard adtsData.count > 7 else { return nil }

        // ADTS header: syncword (12 bits) + ID (1 bit) + layer (2 bits) + protection_absent (1 bit)
        // profile (2 bits) + sampling_frequency_index (4 bits) + channel_config (3 bits) ...
        let samplingFreqIndex = (adtsData[2] >> 2) & 0xF
        let channelConfig = ((adtsData[2] & 0x1) << 2) | ((adtsData[3] >> 6) & 0x3)

        let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard samplingFreqIndex < sampleRates.count else { return nil }
        let sampleRate = sampleRates[Int(samplingFreqIndex)]
        let channels = channelConfig == 0 ? 2 : Int(channelConfig)

        // Create input format for the AAC data
        // Validate we have a supported sample rate/channels combo (suppresses unused warning)
        guard AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) != nil else { return nil }

        // Build AVAudioCompressedBuffer (init is non-optional in Swift)
        let frameCapacity: AVAudioFrameCount = 1024  // AAC-LC frame size
        let compressedBuffer = AVAudioCompressedBuffer(
            format: aacFormat(sampleRate: sampleRate, channels: channels),
            packetCapacity: 1,
            maximumPacketSize: adtsData.count
        )

        compressedBuffer.byteLength = UInt32(adtsData.count)
        adtsData.withUnsafeBytes { ptr in
            compressedBuffer.data.copyMemory(from: ptr.baseAddress!, byteCount: adtsData.count)
        }
        compressedBuffer.packetCount = 1

        // Setup converter if needed
        if converter == nil || converter?.inputFormat != compressedBuffer.format {
            converter = AVAudioConverter(from: compressedBuffer.format, to: outputFormat)
        }
        guard let converter else { return nil }

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity)!
        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return compressedBuffer
        }

        if let error {
            logger.error("AAC decode error: \(error)")
            return nil
        }

        return outputBuffer
    }

    private func aacFormat(sampleRate: Double, channels: Int) -> AVAudioFormat {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        return AVAudioFormat(settings: settings)!
    }
}
