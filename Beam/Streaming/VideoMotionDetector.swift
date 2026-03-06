// VideoMotionDetector.swift
// Frequency-based video region detector.
//
// Core idea: only keyframes are decoded (I-frames are self-contained; P-frames
// cause -12909 without reference context). For each decoded keyframe we compare
// it to the previous one using temporal difference. A frame is "active" only if
// enough cells changed — this spatial filter throws away clock ticks (~3 cells),
// loading spinners (~15 cells) and cursor jitter.  For active frames we track
// *how often* each grid cell changed.  Cells that change frequently (>= requiredRatio
// of active frames) are classified as video content.  The bounding box of those
// cells is the detected region.  This is precise because:
//   • Video content  → changes on almost every active frame  (~80-100%)
//   • Occasional UI  → changes rarely                        (~5-20%)
//   • Static UI      → never changes                         (0%)

import Foundation
import CoreMedia
import VideoToolbox
import CoreVideo
import Observation
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "VideoMotionDetector")

// MARK: - VT Callback

private func vtDecompressionCallback(
    outputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refcon = outputRefCon, status == noErr, let imageBuffer else { return }
    Unmanaged<VideoMotionDetector>.fromOpaque(refcon).takeUnretainedValue()
        .processPixelBuffer(imageBuffer)
}

// MARK: - VideoMotionDetector

@Observable
final class VideoMotionDetector {

    // MARK: - Observable (main thread)

    private(set) var detectedRect: CGRect? = nil
    private(set) var isConfident: Bool = false
    private(set) var isDetecting: Bool = false

    // MARK: - Tuning

    /// Luma grid size. 96×54 = 5184 cells over a 1920×1080 frame → each cell ≈ 20×20px.
    /// Internal (not private) so StreamView can convert screen coords to grid cells for the paint mask.
    static let gridW = 96
    static let gridH = 54

    /// Minimum luma delta for a cell to count as "changed" within an active frame.
    private static let fineThreshold: Int = 10

    /// Minimum luma delta for the spatial activity count (coarser — filters encoding noise).
    private static let coarseThreshold: Int = 22

    /// Minimum number of coarse-changed cells for a frame to be counted as "active".
    /// Clock digit flip:  ~4 cells.  Loading spinner: ~15 cells.  Video frame: 200+ cells.
    private static let minCellsForActiveFrame = 30

    /// Minimum active frames before we publish any detection.
    private static let minActiveFrames = 2

    /// Active frames required without rect change before `isConfident` flips true.
    private static let confidenceFrames = 3

    /// Border of bounding box (in grid cells) added around hot region.
    private static let cellPadding = 0

    /// Rects closer than this (normalised) are considered the same for stability tracking.
    private static let stableEpsilon: CGFloat = 0.02

    /// Fraction of active frames a cell must have changed to be classified as "video".
    /// Adaptive — stricter with few frames (less data), relaxed with more.
    private static func requiredRatio(activeFrames: Int) -> Float {
        switch activeFrames {
        case 2:    return 0.55   // both frames changed
        case 3...4: return 0.45
        default:   return 0.35   // enough frames → 35% is reliably above noise
        }
    }

    // MARK: - Queue-Confined State

    private let queue = DispatchQueue(label: "com.beam.ios.motiondetector", qos: .utility)
    private var session: VTDecompressionSession?

    private var prevGrid: [UInt8] = []
    /// Per-cell count of active frames in which the cell changed.
    private var changeCount: [Int] = []
    private var activeFrameCount = 0
    private var lastPublishedRect: CGRect? = nil
    private var stableCount = 0

    /// User-painted grid cell indices. Painted cells get a significantly lower detection threshold
    /// so the algorithm locks onto the painted region's exact edges (including static border pixels).
    /// Cells outside the painted region get a raised threshold to suppress noise elsewhere.
    private var paintedCells: Set<Int> = []

    // MARK: - Public API

    func start(formatDescription: CMFormatDescription) {
        queue.async { [weak self] in
            guard let self else { return }
            self.resetState()
            self.createSession(formatDescription: formatDescription)
            DispatchQueue.main.async {
                self.isDetecting = true
                self.detectedRect = nil
                self.isConfident = false
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if let s = self.session {
                VTDecompressionSessionInvalidate(s)
                self.session = nil
            }
            self.resetState()
        }
        DispatchQueue.main.async { [weak self] in self?.isDetecting = false }
    }

    /// Update the paint mask from the main thread. Painted cells bias detection toward
    /// the user-indicated region — lowering their threshold and raising it elsewhere.
    func setPaintMask(_ cells: Set<Int>) {
        queue.async { [weak self] in self?.paintedCells = cells }
    }

    func feed(_ sampleBuffer: CMSampleBuffer) {
        guard isKeyframeSample(sampleBuffer) else { return }
        queue.async { [weak self] in
            guard let self, self.session != nil else { return }
            self.submitFrame(sampleBuffer)
        }
    }

    // MARK: - Session

    private func createSession(formatDescription: CMFormatDescription) {
        if let old = session { VTDecompressionSessionInvalidate(old); session = nil }

        var cb = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: vtDecompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &cb,
            decompressionSessionOut: &s
        )
        if status == noErr, let s { session = s; logger.info("VTDecompressionSession ready") }
        else { logger.error("VTDecompressionSession create failed: \(status)") }
    }

    private func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let session else { return }
        var outFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
                                          flags: [], frameRefcon: nil, infoFlagsOut: &outFlags)
    }

    // MARK: - Keyframe Detection
    // Walks AVCC NAL units (4-byte big-endian length prefix) looking for IDR (type 5).
    // Beacon prepends SPS (7) + PPS (8) before the IDR in every keyframe packet, so
    // checking only byte 4 always reads SPS and misses the IDR — must scan them all.

    private func isKeyframeSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let db = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        var totalLen = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(db, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLen,
                                          dataPointerOut: &ptr) == noErr,
              let ptr, totalLen >= 5 else { return false }
        var off = 0
        while off + 4 < totalLen {
            let len = (Int(UInt8(bitPattern: ptr[off])) << 24)
                    | (Int(UInt8(bitPattern: ptr[off+1])) << 16)
                    | (Int(UInt8(bitPattern: ptr[off+2])) << 8)
                    |  Int(UInt8(bitPattern: ptr[off+3]))
            guard len > 0, off + 4 + len <= totalLen else { break }
            if UInt8(bitPattern: ptr[off+4]) & 0x1F == 5 { return true }
            off += 4 + len
        }
        return false
    }

    // MARK: - Analysis

    func processPixelBuffer(_ pixelBuffer: CVImageBuffer) {
        // Synchronous VT decode → already on queue
        analyzePixelBuffer(pixelBuffer)
    }

    private func analyzePixelBuffer(_ pixelBuffer: CVImageBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }

        let pW   = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let pH   = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let gW   = Self.gridW, gH = Self.gridH
        let size = gW * gH

        // Sample luma at grid positions
        var current = [UInt8](repeating: 0, count: size)
        for gy in 0..<gH {
            let py = min(gy * pH / gH, pH - 1)
            for gx in 0..<gW {
                let px = min(gx * pW / gW, pW - 1)
                current[gy * gW + gx] = luma[py * stride + px]
            }
        }

        // Need a previous frame to diff against
        guard prevGrid.count == size else { prevGrid = current; return }

        // Compute per-cell absolute luma diffs
        var diffs = [Int](repeating: 0, count: size)
        var coarseChanged = 0
        for i in 0..<size {
            let d = abs(Int(current[i]) - Int(prevGrid[i]))
            diffs[i] = d
            if d > Self.coarseThreshold { coarseChanged += 1 }
        }
        prevGrid = current

        // ── Spatial filter ───────────────────────────────────────────────────────
        // If fewer than minCellsForActiveFrame cells changed coarsely, this is a
        // noise frame (clock tick, spinner, cursor) — skip it entirely so those
        // cells never accumulate frequency credit.
        guard coarseChanged >= Self.minCellsForActiveFrame else { return }

        // ── Active frame ─────────────────────────────────────────────────────────
        activeFrameCount += 1
        for i in 0..<size where diffs[i] > Self.fineThreshold {
            changeCount[i] += 1
        }

        guard activeFrameCount >= Self.minActiveFrames else { return }

        // ── Frequency thresholding ────────────────────────────────────────────────
        // When the user has painted a region, bias thresholds toward that area:
        //   • Painted cells   → 55% of base ratio  (captures static borders too)
        //   • Unpainted cells → 150% of base ratio (suppresses unrelated motion)
        let baseRatio = Self.requiredRatio(activeFrames: activeFrameCount)
        let hasMask = !paintedCells.isEmpty
        var minX = gW, maxX = -1, minY = gH, maxY = -1

        for gy in 0..<gH {
            for gx in 0..<gW {
                let i = gy * gW + gx
                let f = Float(changeCount[i]) / Float(activeFrameCount)
                let cellRatio: Float = hasMask
                    ? (paintedCells.contains(i) ? baseRatio * 0.55 : baseRatio * 1.5)
                    : baseRatio
                if f >= cellRatio {
                    if gx < minX { minX = gx }; if gx > maxX { maxX = gx }
                    if gy < minY { minY = gy }; if gy > maxY { maxY = gy }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return }

        let pad = Self.cellPadding
        let x0 = max(0, minX - pad),  y0 = max(0, minY - pad)
        let x1 = min(gW, maxX + pad + 1), y1 = min(gH, maxY + pad + 1)

        let normRect = CGRect(
            x: CGFloat(x0) / CGFloat(gW),
            y: CGFloat(y0) / CGFloat(gH),
            width:  CGFloat(x1 - x0) / CGFloat(gW),
            height: CGFloat(y1 - y0) / CGFloat(gH)
        )

        // ── Stability / confidence ────────────────────────────────────────────────
        if let last = lastPublishedRect, rectsAreSimilar(normRect, last) {
            stableCount += 1
        } else {
            stableCount = 0
        }
        lastPublishedRect = normRect
        let confident = stableCount >= Self.confidenceFrames

        DispatchQueue.main.async { [weak self] in
            self?.detectedRect = normRect
            self?.isConfident = confident
        }
    }

    // MARK: - Helpers

    private func rectsAreSimilar(_ a: CGRect, _ b: CGRect) -> Bool {
        let e = Self.stableEpsilon
        return abs(a.minX - b.minX) < e && abs(a.minY - b.minY) < e
            && abs(a.maxX - b.maxX) < e && abs(a.maxY - b.maxY) < e
    }

    private func resetState() {
        let size = Self.gridW * Self.gridH
        prevGrid = []
        changeCount = [Int](repeating: 0, count: size)
        activeFrameCount = 0
        lastPublishedRect = nil
        stableCount = 0
        paintedCells = []
    }
}
