// VideoMotionDetector.swift
// Motion-heatmap + spatial coherence video region detector.
//
// Algorithm overview:
//   1. Accumulate per-cell luma change frequency over decoded keyframes.
//   2. Build a weighted motion score: painted cells get a 3× boost so they
//      attract the result, but the paint area is a hint not a hard boundary.
//   3. 3×3 mean-blur the scores for spatial coherence — isolated single-cell
//      noise (terminal newline, clock tick) blurs to near-zero while contiguous
//      video blocks stay strong.
//   4. Threshold the blurred map → connected blobs (8-connected BFS).
//   5. Pick the best blob: highest total weighted energy, with an extra boost
//      for overlap with the painted region when a paint mask is active.
//   6. Compute the 95th-percentile bounding box of that blob: iteratively peel
//      rows/columns from all four edges while retaining ≥95% of the blob's
//      motion energy. This trims cold-periphery cells and gives a tight rect.

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
    /// Internal so StreamView can convert screen coords to grid cells for the paint mask.
    static let gridW = 96
    static let gridH = 54

    /// Minimum luma delta for a cell to count as "changed" within an active frame.
    private static let fineThreshold: Int = 10

    /// Minimum luma delta for the spatial activity count (coarser — filters encoding noise).
    private static let coarseThreshold: Int = 22

    /// Minimum coarse-changed cells for a frame to count as "active".
    /// Clock digit flip: ~4. Spinner: ~15. Video frame: 200+.
    private static let minCellsForActiveFrame = 30

    /// Minimum active frames before publishing any detection.
    private static let minActiveFrames = 2

    /// Active frames without rect change before `isConfident` flips true.
    private static let confidenceFrames = 3

    /// Rects closer than this (normalised) are considered the same for stability tracking.
    private static let stableEpsilon: CGFloat = 0.02

    /// Motion weight for painted cells — makes the paint area a warm attractor.
    private static let paintBoost: Float = 3.0

    /// Motion weight for immediate neighbours of painted cells (smooth falloff).
    private static let paintNeighborBoost: Float = 1.5

    /// Minimum blurred motion score for a cell to be considered "hot".
    /// After 3×3 blur, a single isolated cell changing 100% of frames blurs to ~0.11;
    /// a terminal newline cluster (~3 cells at 0.2 rate) blurs to ~0.044–0.067.
    /// Threshold of 0.08 excludes sparse noise while keeping any real video motion.
    private static let hotCellThreshold: Float = 0.08

    /// Fraction of the best blob's motion energy to retain when trimming the bbox.
    private static let motionPercentile: Float = 0.95

    // MARK: - Queue-Confined State

    private let queue = DispatchQueue(label: "com.beam.ios.motiondetector", qos: .utility)
    private var session: VTDecompressionSession?

    private var prevGrid: [UInt8] = []
    /// Per-cell count of active frames in which the cell changed.
    private var changeCount: [Int] = []
    private var activeFrameCount = 0
    private var lastPublishedRect: CGRect? = nil
    private var stableCount = 0

    /// User-painted grid cell indices (set from main thread via setPaintMask).
    /// Used as a warm-zone signal: painted cells get paintBoost weight, neighbours
    /// get paintNeighborBoost. The result is NOT constrained to the painted area.
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

    /// Update the paint mask from the main thread.
    /// Painted cells act as a warmer attractor for the algorithm — they bias
    /// which blob wins without constraining the output rectangle.
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
        analyzePixelBuffer(pixelBuffer)
    }

    private func analyzePixelBuffer(_ pixelBuffer: CVImageBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }

        let pW     = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let pH     = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma   = base.assumingMemoryBound(to: UInt8.self)
        let gW     = Self.gridW, gH = Self.gridH
        let size   = gW * gH

        // ── Sample luma at grid positions ─────────────────────────────────────
        var current = [UInt8](repeating: 0, count: size)
        for gy in 0..<gH {
            let py = min(gy * pH / gH, pH - 1)
            for gx in 0..<gW {
                let px = min(gx * pW / gW, pW - 1)
                current[gy * gW + gx] = luma[py * stride + px]
            }
        }

        guard prevGrid.count == size else { prevGrid = current; return }

        // ── Per-cell luma diffs ────────────────────────────────────────────────
        var diffs = [Int](repeating: 0, count: size)
        var coarseChanged = 0
        for i in 0..<size {
            let d = abs(Int(current[i]) - Int(prevGrid[i]))
            diffs[i] = d
            if d > Self.coarseThreshold { coarseChanged += 1 }
        }
        prevGrid = current

        // ── Spatial filter: skip noise frames ─────────────────────────────────
        // Fewer than minCellsForActiveFrame coarse-changed cells = clock tick,
        // loading spinner, cursor blink — skip so they get no frequency credit.
        guard coarseChanged >= Self.minCellsForActiveFrame else { return }

        // ── Accumulate change frequency ────────────────────────────────────────
        activeFrameCount += 1
        for i in 0..<size where diffs[i] > Self.fineThreshold {
            changeCount[i] += 1
        }

        guard activeFrameCount >= Self.minActiveFrames else { return }

        // ── Build paint-weighted motion scores ────────────────────────────────
        // Painted cells get paintBoost (3×) and their immediate neighbours get
        // paintNeighborBoost (1.5×). This makes the painted area a warm attractor
        // without hard-constraining the output rectangle.
        let hasMask = !paintedCells.isEmpty

        // Pre-compute neighbour ring of painted cells for the boost falloff.
        var paintNeighbors = Set<Int>()
        if hasMask {
            for i in paintedCells {
                let cx = i % gW, cy = i / gW
                for dy in -1...1 { for dx in -1...1 {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, nx < gW, ny >= 0, ny < gH else { continue }
                    let ni = ny * gW + nx
                    if !paintedCells.contains(ni) { paintNeighbors.insert(ni) }
                }}
            }
        }

        var score = [Float](repeating: 0, count: size)
        for i in 0..<size {
            let base = Float(changeCount[i]) / Float(activeFrameCount)
            let w: Float = hasMask
                ? (paintedCells.contains(i)  ? Self.paintBoost
                :  paintNeighbors.contains(i) ? Self.paintNeighborBoost
                :  1.0)
                : 1.0
            score[i] = base * w
        }

        // ── 3×3 mean blur for spatial coherence ───────────────────────────────
        // Isolated cells (terminal newline = 1–3 cells) blur to ~0.04–0.07 and
        // fall below hotCellThreshold. Contiguous video blocks (100+ cells) stay
        // at their full weighted value, reflecting localised correlated movement.
        var blurred = [Float](repeating: 0, count: size)
        for gy in 0..<gH {
            for gx in 0..<gW {
                var s: Float = 0; var n: Float = 0
                for dy in -1...1 { for dx in -1...1 {
                    let nx = gx + dx, ny = gy + dy
                    guard nx >= 0, nx < gW, ny >= 0, ny < gH else { continue }
                    s += score[ny * gW + nx]; n += 1
                }}
                blurred[gy * gW + gx] = s / n
            }
        }

        // ── Find hot cells and their connected blobs ──────────────────────────
        var hotSet = Set<Int>()
        for i in 0..<size where blurred[i] >= Self.hotCellThreshold { hotSet.insert(i) }
        guard !hotSet.isEmpty else { return }

        let bestBlob = findBestBlob(hotCells: hotSet, blurred: blurred, gW: gW, gH: gH)

        // ── 95th-percentile bounding box ──────────────────────────────────────
        let normRect = percentileBoundingBox(cells: bestBlob, blurred: blurred, gW: gW, gH: gH)

        // ── Stability / confidence ────────────────────────────────────────────
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

    // MARK: - Blob Detection

    /// BFS over hot cells to find all connected blobs (8-connectivity).
    /// Scores each blob by total blurred motion energy, with an extra boost for
    /// overlap with the painted region when a mask is active.
    /// Returns the blob with the highest score.
    private func findBestBlob(hotCells: Set<Int>, blurred: [Float], gW: Int, gH: Int) -> Set<Int> {
        let hasMask = !paintedCells.isEmpty
        var visited = Set<Int>(minimumCapacity: hotCells.count)
        var bestBlob = Set<Int>()
        var bestScore: Float = 0

        for start in hotCells where !visited.contains(start) {
            var blob = Set<Int>()
            var queue = [start]
            visited.insert(start)
            var energy: Float = 0

            while !queue.isEmpty {
                let cell = queue.removeLast()
                blob.insert(cell)
                energy += blurred[cell]
                let cx = cell % gW, cy = cell / gW
                for dy in -1...1 { for dx in -1...1 {
                    guard dx != 0 || dy != 0 else { continue }
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, nx < gW, ny >= 0, ny < gH else { continue }
                    let ni = ny * gW + nx
                    guard hotCells.contains(ni), !visited.contains(ni) else { continue }
                    visited.insert(ni)
                    queue.append(ni)
                }}
            }

            // Boost score by painted-region overlap: a blob that fully overlaps
            // the painted area gets up to 4× its raw energy.
            var blobScore = energy
            if hasMask, !paintedCells.isEmpty {
                let overlapCount = Float(blob.filter { paintedCells.contains($0) }.count)
                let paintFraction = overlapCount / Float(paintedCells.count)
                blobScore *= (1.0 + paintFraction * 3.0)
            }

            if blobScore > bestScore { bestScore = blobScore; bestBlob = blob }
        }
        return bestBlob
    }

    // MARK: - Percentile Bounding Box

    /// Iteratively peels rows and columns from the bounding box of `cells` while
    /// the remaining cells still account for ≥ motionPercentile of total energy.
    /// This trims cold-periphery cells (scattered noise near the blob edge) to
    /// produce a tight rectangle around the densest motion region.
    private func percentileBoundingBox(cells: Set<Int>, blurred: [Float], gW: Int, gH: Int) -> CGRect {
        var rowSum = [Float](repeating: 0, count: gH)
        var colSum = [Float](repeating: 0, count: gW)
        var total: Float = 0

        for i in cells {
            let gx = i % gW, gy = i / gW
            let v = blurred[i]
            rowSum[gy] += v; colSum[gx] += v; total += v
        }

        guard total > 0 else {
            var minX = gW, maxX = 0, minY = gH, maxY = 0
            for i in cells {
                let gx = i % gW, gy = i / gW
                minX = min(minX, gx); maxX = max(maxX, gx)
                minY = min(minY, gy); maxY = max(maxY, gy)
            }
            return CGRect(x: CGFloat(minX) / CGFloat(gW), y: CGFloat(minY) / CGFloat(gH),
                          width: CGFloat(maxX - minX + 1) / CGFloat(gW),
                          height: CGFloat(maxY - minY + 1) / CGFloat(gH))
        }

        let target = total * Self.motionPercentile
        var included = total

        var r0 = (0..<gH).first(where: { rowSum[$0] > 0 }) ?? 0
        var r1 = (0..<gH).last(where:  { rowSum[$0] > 0 }) ?? (gH - 1)
        var c0 = (0..<gW).first(where: { colSum[$0] > 0 }) ?? 0
        var c1 = (0..<gW).last(where:  { colSum[$0] > 0 }) ?? (gW - 1)

        // Keep peeling the cheapest edge until no more can be removed.
        var changed = true
        while changed {
            changed = false
            if r0 < r1, included - rowSum[r0] >= target { included -= rowSum[r0]; r0 += 1; changed = true }
            if r1 > r0, included - rowSum[r1] >= target { included -= rowSum[r1]; r1 -= 1; changed = true }
            if c0 < c1, included - colSum[c0] >= target { included -= colSum[c0]; c0 += 1; changed = true }
            if c1 > c0, included - colSum[c1] >= target { included -= colSum[c1]; c1 -= 1; changed = true }
        }

        return CGRect(
            x:      CGFloat(c0)          / CGFloat(gW),
            y:      CGFloat(r0)          / CGFloat(gH),
            width:  CGFloat(c1 - c0 + 1) / CGFloat(gW),
            height: CGFloat(r1 - r0 + 1) / CGFloat(gH)
        )
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
