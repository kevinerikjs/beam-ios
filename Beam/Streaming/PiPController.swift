// PiPController.swift
// Manages AVPictureInPictureController for the streaming view.
// PiP is first-class in Beam - set up from the start, not bolted on later.

import AVFoundation
import AVKit
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "PiP")

// MARK: - PiPController

@Observable
final class PiPController: NSObject {

    var isPiPActive: Bool = false
    var isPiPPossible: Bool = false
    var isPiPSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()

    private var pipController: AVPictureInPictureController?
    private weak var renderer: VideoRenderer?
    private var pipPossibleObservation: NSKeyValueObservation?

    // MARK: - Setup

    func setup(with renderer: VideoRenderer) {
        self.renderer = renderer

        guard isPiPSupported else {
            logger.warning("PiP not supported on this device")
            return
        }

        // AVPictureInPictureController needs an AVSampleBufferDisplayLayer
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: renderer.displayLayer,
            playbackDelegate: self
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.requiresLinearPlayback = false  // Don't show skip/rewind in PiP
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        self.pipController = controller
        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                self?.isPiPPossible = observed.isPictureInPicturePossible
            }
        }
        logger.info("PiPController set up")
    }

    func teardown() {
        if isPiPActive {
            pipController?.stopPictureInPicture()
        }
        pipPossibleObservation = nil
        pipController = nil
        renderer = nil
        isPiPActive = false
        isPiPPossible = false
    }

    // MARK: - Control

    func start() {
        guard isPiPSupported else {
            logger.warning("PiP not supported")
            return
        }
        pipController?.startPictureInPicture()
    }

    func stop() {
        pipController?.stopPictureInPicture()
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        logger.info("PiP will start")
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isPiPActive = true
        Analytics.pipActivated()
        logger.info("PiP started")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isPiPActive = false
        logger.info("PiP stopped")
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        logger.error("PiP failed to start: \(error)")
        isPiPActive = false
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // Called when user taps the PiP window to return to full screen
        completionHandler(true)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // We don't control playback from PiP - stream is live
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Live stream - use a 1-second window to keep PiP happy
        CMTimeRange(start: .negativeInfinity, duration: CMTime(seconds: 1, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false  // Stream is always "playing"
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // Nothing needed
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
