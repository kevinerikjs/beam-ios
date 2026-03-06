// VideoRenderer.swift
// AVSampleBufferDisplayLayer wrapper for low-latency H.264 video rendering.
// Designed for PiP from the start: exposes the layer for AVPictureInPictureController.

import AVFoundation
import CoreVideo
import VideoToolbox
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "VideoRenderer")

// MARK: - VT Crop Callback

private func videoCropDecompressionCallback(
    outputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refcon = outputRefCon, status == noErr, let imageBuffer else { return }
    Unmanaged<VideoRenderer>.fromOpaque(refcon).takeUnretainedValue()
        .handleCropFrame(imageBuffer)
}

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

    // MARK: - Crop Pipeline

    /// Normalized (0-1) viewport rect to crop to before sending to the display layer.
    /// When non-nil, frames are decoded → cropped → re-enqueued as uncompressed so
    /// both the in-app view and PiP show only the locked viewport.
    var cropRect: CGRect? {
        didSet {
            guard oldValue != cropRect else { return }
            resetCropPipeline()
        }
    }

    private var cropSession: VTDecompressionSession?
    private var cropFormatDesc: CMFormatDescription?
    private var cropPool: CVPixelBufferPool?
    private var cropPoolSize: CGSize = .zero
    /// Written on main thread just before submitting a frame for decoding;
    /// read on the VT callback thread. Sequential ordering makes this safe.
    private var cropRectSnapshot: CGRect = .zero

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

        if let crop = cropRect {
            // Crop path: decode H.264 → crop CVPixelBuffer → enqueue uncompressed.
            // This makes PiP (which reads the display layer directly) show the viewport.
            cropRectSnapshot = crop
            ensureCropSession(for: sampleBuffer)
            submitToCropSession(sampleBuffer)
        } else {
            // Direct path: enqueue compressed H.264 as-is (current behavior)
            displayLayer.enqueue(sampleBuffer)
        }

        // Always pass the original (full-frame) sample to the motion detector
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

    // MARK: - Crop Session Management

    private func resetCropPipeline() {
        // Invalidate synchronously — VTDecompressionSessionInvalidate ensures all
        // in-flight callbacks complete before returning, so cropPool is safe to clear after.
        if let s = cropSession { VTDecompressionSessionInvalidate(s); cropSession = nil }
        cropFormatDesc = nil
        cropPool = nil
        cropPoolSize = .zero
        displayLayer.flush()
    }

    private func ensureCropSession(for sampleBuffer: CMSampleBuffer) {
        guard let newDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        // Reuse existing session if format hasn't changed
        if cropSession != nil,
           let existing = cropFormatDesc,
           CMFormatDescriptionEqual(existing, newDesc) { return }

        if let s = cropSession { VTDecompressionSessionInvalidate(s); cropSession = nil }
        cropFormatDesc = newDesc

        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as [NSString: Any]
        var cb = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: videoCropDecompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newDesc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &cb,
            decompressionSessionOut: &s
        )
        if status == noErr, let s {
            cropSession = s
        } else {
            logger.error("Crop VTDecompressionSession create failed: \(status)")
        }
    }

    private func submitToCropSession(_ sampleBuffer: CMSampleBuffer) {
        guard let session = cropSession else { return }
        var flags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], frameRefcon: nil, infoFlagsOut: &flags
        )
    }

    // MARK: - Crop Callback (called on VT decode thread)

    func handleCropFrame(_ imageBuffer: CVImageBuffer) {
        let crop = cropRectSnapshot
        guard crop.width > 0, crop.height > 0 else { return }

        guard let cropped = cropPixelBuffer(imageBuffer, to: crop) else { return }

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: cropped, formatDescriptionOut: &formatDesc
        )
        guard let formatDesc else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: cropped,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sb
        )
        guard let sb else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.cropRect != nil else { return }
            if self.displayLayer.status == .failed { self.displayLayer.flush() }
            self.displayLayer.enqueue(sb)
        }
    }

    // MARK: - CVPixelBuffer Crop

    private func cropPixelBuffer(_ src: CVImageBuffer, to rect: CGRect) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)

        // Align to even pixels (required for 4:2:0 chroma subsampling)
        let cx = Int(rect.minX * CGFloat(srcW)) & ~1
        let cy = Int(rect.minY * CGFloat(srcH)) & ~1
        let cw = min(max(Int(rect.width  * CGFloat(srcW)) & ~1, 2), srcW - cx)
        let ch = min(max(Int(rect.height * CGFloat(srcH)) & ~1, 2), srcH - cy)
        guard cw > 0, ch > 0 else { return nil }

        // Recreate pool if crop dimensions changed
        if cropPoolSize != CGSize(width: cw, height: ch) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: cw,
                kCVPixelBufferHeightKey: ch,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ]
            cropPool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &cropPool)
            cropPoolSize = CGSize(width: cw, height: ch)
        }
        guard let pool = cropPool else { return nil }

        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
              let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        guard CVPixelBufferGetPlaneCount(src) >= 2,
              let srcY  = CVPixelBufferGetBaseAddressOfPlane(src, 0),
              let srcUV = CVPixelBufferGetBaseAddressOfPlane(src, 1),
              let dstY  = CVPixelBufferGetBaseAddressOfPlane(dst, 0),
              let dstUV = CVPixelBufferGetBaseAddressOfPlane(dst, 1) else { return nil }

        let srcYBPR  = CVPixelBufferGetBytesPerRowOfPlane(src, 0)
        let dstYBPR  = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
        let srcUVBPR = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
        let dstUVBPR = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)

        // Y plane
        for row in 0..<ch {
            memcpy(
                dstY.advanced(by: row * dstYBPR),
                srcY.advanced(by: (cy + row) * srcYBPR + cx),
                cw
            )
        }

        // UV plane: interleaved (NV12) — half height, same byte width as Y
        // Offset: cx bytes (= cx/2 chroma samples × 2 bytes each)
        for row in 0..<(ch / 2) {
            memcpy(
                dstUV.advanced(by: row * dstUVBPR),
                srcUV.advanced(by: (cy / 2 + row) * srcUVBPR + cx),
                cw
            )
        }

        return dst
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
