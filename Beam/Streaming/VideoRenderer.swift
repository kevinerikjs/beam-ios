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

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

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

        // Tie the display layer's clock to the iOS host clock so frame PTSs
        // (which we stamp with the local iOS time) render immediately.
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if let timebase {
            CMTimebaseSetRate(timebase, rate: 1.0)
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            displayLayer.controlTimebase = timebase
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    // MARK: - Frame Delivery

    /// Called just before a frame is handed to the display layer with its age in seconds
    /// (host capture to here), when the receiver knows the host's clock. The last hop the
    /// app can measure; decode and the refresh come after.
    var onEnqueueAge: ((TimeInterval) -> Void)?

    /// Debug: hand frames to the display layer from the receiver's queue instead of hopping
    /// to the main thread first. Read once per frame; the Latency Meter shows the difference.
    static var enqueuesOffMainThread: Bool {
        UserDefaults.standard.bool(forKey: "beam.debug.enqueueOffMain")
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, capturedAtLocal: Int64? = nil) {
        // The display layer has always been fed from the main thread here. It is not
        // documented as main-thread-only; the debug switch above lets that be measured.
        guard Thread.isMainThread || Self.enqueuesOffMainThread else {
            DispatchQueue.main.async { self.enqueue(sampleBuffer, capturedAtLocal: capturedAtLocal) }
            return
        }
        if let capturedAtLocal, let onEnqueueAge {
            let t = CMClockGetTime(CMClockGetHostTimeClock())
            let now = Int64(Double(t.value) * 1_000_000 / Double(t.timescale))
            onEnqueueAge(Double(now - capturedAtLocal) / 1_000_000)
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
            logger.warning("Display layer was in failed state, flushed")
        }

        displayLayer.enqueue(sampleBuffer)
        onSampleBuffer?(sampleBuffer)

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
