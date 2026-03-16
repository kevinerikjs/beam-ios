// AudioPlayer.swift
// AVAudioEngine playback for host-streamed Float32 interleaved PCM.

import AVFoundation
import CoreMedia
import OSLog
import Darwin

private let logger = Logger(subsystem: "com.beam.ios", category: "AudioPlayer")

final class AudioPlayer {

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let renderQueue = DispatchQueue(label: "com.beam.ios.audioplayer", qos: .userInteractive)

    // Remote audio format (updated by host control messages).
    private var playbackSampleRate: Double = 44_100
    private var playbackChannels: AVAudioChannelCount = 2
    private var outputFormat: AVAudioFormat?

    // Sync state (renderQueue-only).
    // Video is the master clock; audio is scheduled slightly ahead on that timeline.
    private var syncAnchorRemotePTSUs: Int64?
    private var syncAnchorLocalSeconds: Double?
    private var lastVideoRemotePTSUs: Int64?
    private var lastVideoLocalSeconds: Double?
    private var nextScheduledAudioSeconds: Double?

    private let targetAudioLeadSeconds: Double = 0.10
    private let maxAudioLeadSeconds: Double = 0.45
    private let lateAudioCatchupThresholdSeconds: Double = 0.30
    private let hardAudioResyncThresholdSeconds: Double = 0.85
    private let clockResetThresholdSeconds: Double = 1.5

    // MARK: - Lifecycle

    func start() {
        renderQueue.async { [weak self] in
            self?.setupAudioSession()
            self?.setupEngine()
        }
    }

    func stop() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            resetSyncState()
            self.engine?.stop()
            self.playerNode?.stop()
            self.engine = nil
            self.playerNode = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("AudioPlayer stopped")
        }
    }

    func resetSync() {
        renderQueue.async { [weak self] in
            self?.resetSyncState()
        }
    }

    func updateRemoteFormat(sampleRate: Double, channels: Int) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            let normalizedRate = sampleRate.clamped(to: 8_000...96_000)
            let normalizedChannels = AVAudioChannelCount(max(1, min(channels, 8)))
            let sampleRateChanged = abs(normalizedRate - playbackSampleRate) > 1
            let channelsChanged = normalizedChannels != playbackChannels
            guard sampleRateChanged || channelsChanged else { return }

            playbackSampleRate = normalizedRate
            playbackChannels = normalizedChannels
            rebuildAudioEngineForFormatChange()
            logger.info("AudioPlayer format updated: \(normalizedRate, format: .fixed(precision: 0)) Hz, \(normalizedChannels)ch")
        }
    }

    // MARK: - Setup

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback keeps audio active in background (required for PiP) and lets AVKit
            // know this session is media-playback-eligible so isPictureInPicturePossible
            // becomes true as soon as the stream starts. .mixWithOthers lets other audio
            // (music, podcasts) continue alongside the stream.
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            logger.error("Failed to configure audio session: \(error)")
        }
    }

    private func setupEngine() {
        guard engine == nil, playerNode == nil else { return }
        guard let format = makeOutputFormat() else {
            logger.error("Failed to create output format for audio engine")
            return
        }
        outputFormat = format
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            node.play()
            self.engine = engine
            self.playerNode = node
            logger.info("AudioPlayer engine started")
        } catch {
            logger.error("Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Enqueue

    func updateVideoClock(remotePresentationTimestampUs: Int64) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            ingestVideoClock(remotePresentationTimestampUs: remotePresentationTimestampUs)
        }
    }

    func enqueue(_ pcmData: Data, remotePresentationTimestampUs: Int64) {
        renderQueue.async { [weak self] in
            guard let self, let node = self.playerNode else { return }
            guard let buffer = self.makePCMBuffer(fromInterleavedFloat32: pcmData) else { return }
            let session = AVAudioSession.sharedInstance()
            let shouldApplySync = session.outputVolume > 0.001
            if !shouldApplySync {
                nextScheduledAudioSeconds = nil
                node.scheduleBuffer(buffer, completionHandler: nil)
                return
            }
            guard lastVideoRemotePTSUs != nil else {
                // Video drives sync; ignore pre-roll audio until first video clock sample arrives.
                return
            }

            let now = hostNowSeconds()
            guard let mappedTime = mappedLocalSeconds(forRemotePTSUs: remotePresentationTimestampUs) else { return }
            var targetPlayTime = mappedTime + targetAudioLeadSeconds

            var shouldForceImmediateSchedule = false
            if let videoNowRemotePTSUs = estimatedRemoteVideoPTSUs(atLocalSeconds: now) {
                let desiredAudioPTSUs = videoNowRemotePTSUs + Int64(targetAudioLeadSeconds * 1_000_000.0)
                let avErrorSeconds = Double(remotePresentationTimestampUs - desiredAudioPTSUs) / 1_000_000.0

                if avErrorSeconds < -lateAudioCatchupThresholdSeconds {
                    // Instead of dropping late audio (audible clicks/gaps), force immediate catch-up.
                    shouldForceImmediateSchedule = true
                    nextScheduledAudioSeconds = nil
                    targetPlayTime = now + 0.004

                    if abs(avErrorSeconds) > hardAudioResyncThresholdSeconds {
                        // Severe discontinuity: clear queued audio and reset anchor.
                        node.reset()
                        syncAnchorRemotePTSUs = remotePresentationTimestampUs
                        syncAnchorLocalSeconds = now
                    }
                }
                if avErrorSeconds > maxAudioLeadSeconds {
                    // Keep audio lead bounded; avoid excessive queueing.
                    targetPlayTime = min(targetPlayTime, now + maxAudioLeadSeconds)
                }
            }

            if !shouldForceImmediateSchedule, let queuedAudioTime = nextScheduledAudioSeconds {
                targetPlayTime = max(targetPlayTime, queuedAudioTime)
            }
            targetPlayTime = max(targetPlayTime, now)
            targetPlayTime = min(targetPlayTime, now + maxAudioLeadSeconds)

            let durationSeconds = Double(buffer.frameLength) / playbackSampleRate
            nextScheduledAudioSeconds = targetPlayTime + durationSeconds

            if targetPlayTime <= now + 0.003 {
                node.scheduleBuffer(buffer, completionHandler: nil)
                return
            }

            let hostTime = AVAudioTime.hostTime(forSeconds: targetPlayTime)
            let when = AVAudioTime(hostTime: hostTime)
            node.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
        }
    }

    private func makePCMBuffer(fromInterleavedFloat32 data: Data) -> AVAudioPCMBuffer? {
        guard let format = outputFormat else { return nil }
        let channelCount = Int(playbackChannels)
        let bytesPerFrame = channelCount * MemoryLayout<Float32>.size
        guard bytesPerFrame > 0 else { return nil }

        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let floatChannels = buffer.floatChannelData else { return nil }
        data.withUnsafeBytes { srcRaw in
            let src = srcRaw.baseAddress!.assumingMemoryBound(to: Float32.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    floatChannels[channel][frame] = src[(frame * channelCount) + channel]
                }
            }
        }
        return buffer
    }

    private func ingestVideoClock(remotePresentationTimestampUs: Int64) {
        let now = hostNowSeconds()

        if let previousRemote = lastVideoRemotePTSUs,
           remotePresentationTimestampUs + 100_000 < previousRemote {
            // Stream timestamp discontinuity (seek/restart) - reset mapping.
            resetSyncState()
        }

        if syncAnchorRemotePTSUs == nil || syncAnchorLocalSeconds == nil {
            syncAnchorRemotePTSUs = remotePresentationTimestampUs
            syncAnchorLocalSeconds = now
        }

        lastVideoRemotePTSUs = remotePresentationTimestampUs
        lastVideoLocalSeconds = now

        if let mappedNow = mappedLocalSeconds(forRemotePTSUs: remotePresentationTimestampUs),
           abs(mappedNow - now) > clockResetThresholdSeconds {
            syncAnchorRemotePTSUs = remotePresentationTimestampUs
            syncAnchorLocalSeconds = now
        }

        if let queuedAudioTime = nextScheduledAudioSeconds, queuedAudioTime < now {
            nextScheduledAudioSeconds = nil
        }
    }

    private func mappedLocalSeconds(forRemotePTSUs remotePTSUs: Int64) -> Double? {
        guard let anchorRemote = syncAnchorRemotePTSUs, let anchorLocal = syncAnchorLocalSeconds else { return nil }
        let deltaSeconds = Double(remotePTSUs - anchorRemote) / 1_000_000.0
        return anchorLocal + deltaSeconds
    }

    private func estimatedRemoteVideoPTSUs(atLocalSeconds localSeconds: Double) -> Int64? {
        guard let videoPTS = lastVideoRemotePTSUs, let videoLocal = lastVideoLocalSeconds else { return nil }
        let elapsedSeconds = localSeconds - videoLocal
        return videoPTS + Int64(elapsedSeconds * 1_000_000.0)
    }

    private func hostNowSeconds() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    private func resetSyncState() {
        syncAnchorRemotePTSUs = nil
        syncAnchorLocalSeconds = nil
        lastVideoRemotePTSUs = nil
        lastVideoLocalSeconds = nil
        nextScheduledAudioSeconds = nil
    }

    private func rebuildAudioEngineForFormatChange() {
        let shouldRestartImmediately = engine != nil || playerNode != nil
        engine?.stop()
        playerNode?.stop()
        engine = nil
        playerNode = nil
        outputFormat = nil
        resetSyncState()
        if shouldRestartImmediately {
            setupEngine()
        }
    }

    private func makeOutputFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: playbackSampleRate,
            channels: playbackChannels,
            interleaved: false
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
