// VideoRenderer.swift
// AVSampleBufferDisplayLayer wrapper for low-latency H.264 video rendering.
// Designed for PiP from the start: exposes the layer for AVPictureInPictureController.

import AVFoundation
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "VideoRenderer")

// MARK: - VideoRenderer

final class VideoRenderer: UIView {

    // The display layer - used directly by PiPController
    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.preventsCapture = false  // Allow screen recording of received content
        return layer
    }()

    private var hasReceivedFirstFrame = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        layer.addSublayer(displayLayer)
        backgroundColor = .black
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    // MARK: - Frame Delivery

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // AVSampleBufferDisplayLayer must receive frames on main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.enqueue(sampleBuffer) }
            return
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
            logger.warning("Display layer was in failed state, flushed")
        }

        displayLayer.enqueue(sampleBuffer)

        if !hasReceivedFirstFrame {
            hasReceivedFirstFrame = true
            logger.info("First video frame displayed")
        }
    }

    func flush() {
        DispatchQueue.main.async {
            self.displayLayer.flush()
            self.hasReceivedFirstFrame = false
        }
    }
}

// MARK: - SwiftUI Bridge

import SwiftUI

struct VideoRendererView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> VideoRenderer {
        renderer
    }

    func updateUIView(_ uiView: VideoRenderer, context: Context) {
        // Nothing to update - renderer handles itself
    }
}
