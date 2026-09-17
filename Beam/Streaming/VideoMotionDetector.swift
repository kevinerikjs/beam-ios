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
//   7. Edge refinement: the coarse rect can only land on 20px cell boundaries and
//      the blur/trim pair is tuned for "close", so each edge is re-found on a 4×
//      finer change map inside a narrow band around the coarse edge, snapping to
//      where change frequency steps from "moving" to "still". Nothing outside
//      the band can move an edge, so a loading bar elsewhere cannot skew it.

import Foundation
import CoreMedia
import VideoToolbox
import CoreVideo
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

final class VideoMotionDetector: ObservableObject {

    // MARK: - Observable (main thread)

    @Published private(set) var detectedRect: CGRect? = nil
    @Published private(set) var isConfident: Bool = false
    @Published private(set) var isDetecting: Bool = false

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
    private static let confidenceFrames = 2

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

    /// Weight of the edge-contrast signal relative to motion.
    /// Edge detection is a secondary, less reliable signal — it helps capture static
    /// borders/chrome of content regions but is kept small to avoid false positives.
    private static let edgeWeight: Float = 0.12

    /// Analyse every Nth decoded frame. At 30 fps input this gives ~10 fps analysis.
    private static let analyzeEveryNFrames = 3

    // Edge refinement (step 7)
    /// Fine map is this many samples per coarse cell along each axis (4 → 384×216, ~5px).
    private static let fineScale = 4
    static let fineW = gridW * fineScale
    static let fineH = gridH * fineScale
    /// Luma delta for a fine sample to count as changed. Lower than fineThreshold on
    /// purpose: dark or slow film edges still need to register as "moving".
    private static let fineRefineThreshold: Int = 6
    /// How far (in fine samples) each side of the coarse edge to search. 2 cells.
    private static let refineBand = fineScale * 2
    /// Rows/cols averaged on each side of a candidate boundary when scoring it.
    private static let refineWindow = 3
    /// A boundary is only accepted when the inside is this much more active than
    /// the outside; otherwise the coarse edge stands.
    private static let refineMinInside: Float = 0.12
    private static let refineContrastRatio: Float = 2.0

    // MARK: - Queue-Confined State

    private let queue = DispatchQueue(label: "com.beam.ios.motiondetector", qos: .utility)
    private var session: VTDecompressionSession?

    private var prevGrid: [UInt8] = []
    /// Per-cell count of active frames in which the cell changed.
    private var changeCount: [Int] = []
    /// Fine-grid luma and change counts for edge refinement (fineW × fineH).
    private var prevFine: [UInt8] = []
    private var currentFine: [UInt8] = []
    private var fineChangeCount: [Int] = []
    private var activeFrameCount = 0
    private var lastPublishedRect: CGRect? = nil
    private var stableCount = 0
    /// True once the first IDR frame has been decoded — P-frames can be submitted after this.
    private var hasSeenFirstKeyframe = false
    /// Counts decoded frames; analysis runs every analyzeEveryNFrames frames.
    private var framesSinceAnalysis = 0

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
        // Check keyframe status on the caller's thread (avoids touching CMSampleBuffer off-thread).
        let isKeyframe = isKeyframeSample(sampleBuffer)
        queue.async { [weak self] in
            guard let self, self.session != nil else { return }
            // We must receive at least one IDR before submitting P-frames, otherwise
            // the VTDecompressionSession has no reference frame and decode fails.
            if isKeyframe { self.hasSeenFirstKeyframe = true }
            guard self.hasSeenFirstKeyframe else { return }
            // Submit every frame so the decoder can maintain its reference chain.
            // Analysis is throttled inside processPixelBuffer.
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

    /// Keyframe test for both codecs. H.264: NAL type (low 5 bits) 5 = IDR. HEVC: NAL type is
    /// bits 1-6 of the first header byte; 16-21 are the IRAP pictures (IDR/CRA/BLA), any of
    /// which starts a decodable sequence. Checking only the H.264 layout meant that on an HEVC
    /// stream the detector never saw a "first keyframe" and never decoded a single frame.
    private func isKeyframeSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        // The sync flag is authoritative when present (StreamReceiver stamps it on IDR frames).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0,
           let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as? [CFString: Any],
           let notSync = dict[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        let isHEVC: Bool
        if let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
            isHEVC = CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC
        } else {
            isHEVC = false
        }
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
            let header = UInt8(bitPattern: ptr[off+4])
            if isHEVC {
                let nalType = (header >> 1) & 0x3F
                if (16...21).contains(nalType) { return true }
            } else if header & 0x1F == 5 {
                return true
            }
            off += 4 + len
        }
        return false
    }

    // MARK: - Analysis

    func processPixelBuffer(_ pixelBuffer: CVImageBuffer) {
        framesSinceAnalysis += 1
        guard framesSinceAnalysis >= Self.analyzeEveryNFrames else { return }
        framesSinceAnalysis = 0
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

        // ── Fine grid (4× per axis) for edge refinement ───────────────────────
        let fW = Self.fineW, fH = Self.fineH, fSize = fW * fH
        var fine = [UInt8](repeating: 0, count: fSize)
        for fy in 0..<fH {
            let py = min(fy * pH / fH, pH - 1)
            let row = py * stride
            for fx in 0..<fW {
                fine[fy * fW + fx] = luma[row + min(fx * pW / fW, pW - 1)]
            }
        }

        guard prevGrid.count == size else { prevGrid = current; prevFine = fine; return }

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
        if prevFine.count == fSize {
            for i in 0..<fSize where abs(Int(fine[i]) - Int(prevFine[i])) > Self.fineRefineThreshold {
                fineChangeCount[i] += 1
            }
        }
        prevFine = fine
        currentFine = fine

        guard activeFrameCount >= Self.minActiveFrames else { return }

        // ── Edge contrast map (current frame) ────────────────────────────────
        // Mean absolute luma difference with 4-connected neighbours, normalised
        // to [0, 1]. High at content boundaries (video player chrome, window
        // borders), low inside uniform regions. Added as a weak secondary signal.
        var edgeScore = [Float](repeating: 0, count: size)
        for gy in 0..<gH {
            for gx in 0..<gW {
                let i = gy * gW + gx
                var eSum: Float = 0; var eCount: Float = 0
                for (dx, dy): (Int, Int) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let nx = gx + dx, ny = gy + dy
                    guard nx >= 0, nx < gW, ny >= 0, ny < gH else { continue }
                    eSum += Float(abs(Int(current[i]) - Int(current[ny * gW + nx])))
                    eCount += 1
                }
                edgeScore[i] = (eSum / eCount) / 255.0
            }
        }

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
            // Edge contrast is a secondary, less reliable signal. It gives a small
            // boost to high-contrast boundary cells (video player chrome, window
            // borders) helping them survive the 95% percentile trim. Kept at 0.12×
            // so an edge-only cell (zero motion) can't cross hotCellThreshold alone.
            score[i] = base * w + edgeScore[i] * Self.edgeWeight
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

        // ── 95th-percentile bounding box, then snap edges on the fine map ─────
        let coarseRect = percentileBoundingBox(cells: bestBlob, blurred: blurred, gW: gW, gH: gH)
        let normRect = refineEdges(coarseRect)

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

    // MARK: - Edge Refinement

    /// Re-finds each edge of `rect` (normalised) on the fine change map. For one edge,
    /// every candidate boundary within `refineBand` gets a score: how much more often
    /// the samples just inside it change than the samples just outside, plus a small
    /// luma-contrast term so a hard player border wins a tie. The best boundary is
    /// accepted only if the inside is clearly active and clearly more active than the
    /// outside; otherwise the coarse edge stands, so refinement can never make a
    /// result worse than before.
    private func refineEdges(_ rect: CGRect) -> CGRect {
        let fW = Self.fineW, fH = Self.fineH
        guard activeFrameCount > 0, fineChangeCount.count == fW * fH, currentFine.count == fW * fH else { return rect }
        let inv = 1.0 / Float(activeFrameCount)
        func freq(_ x: Int, _ y: Int) -> Float { Float(fineChangeCount[y * fW + x]) * inv }
        func luma(_ x: Int, _ y: Int) -> Float { Float(currentFine[y * fW + x]) }

        var x0 = Int((rect.minX * CGFloat(fW)).rounded()), x1 = Int((rect.maxX * CGFloat(fW)).rounded())
        var y0 = Int((rect.minY * CGFloat(fH)).rounded()), y1 = Int((rect.maxY * CGFloat(fH)).rounded())
        x0 = max(0, min(x0, fW - 1)); x1 = max(x0 + 1, min(x1, fW))
        y0 = max(0, min(y0, fH - 1)); y1 = max(y0 + 1, min(y1, fH))

        // Profile along one axis: mean change frequency per line, over the interior of the
        // other axis (10% inset so corners and adjacent chrome don't leak in).
        func profile(horizontalLines: Bool, from a: Int, to b: Int) -> ([Float], [Float]) {
            let spanLo = horizontalLines ? x0 : y0, spanHi = horizontalLines ? x1 : y1
            let inset = max(1, (spanHi - spanLo) / 10)
            let lo = spanLo + inset, hi = max(lo + 1, spanHi - inset)
            var f = [Float](repeating: 0, count: b - a), e = [Float](repeating: 0, count: b - a)
            for line in a..<b {
                var fs: Float = 0, es: Float = 0
                for k in lo..<hi {
                    if horizontalLines {
                        fs += freq(k, line)
                        if line > 0 { es += abs(luma(k, line) - luma(k, line - 1)) }
                    } else {
                        fs += freq(line, k)
                        if line > 0 { es += abs(luma(line, k) - luma(line - 1, k)) }
                    }
                }
                let n = Float(hi - lo)
                f[line - a] = fs / n; e[line - a] = es / n / 255
            }
            return (f, e)
        }

        // Pick the boundary in [lo, hi) with the strongest inside-vs-outside step.
        // `insideIsAfter` = true for top/left edges (inside lies at higher indices).
        func bestBoundary(coarse: Int, limit: Int, horizontalLines: Bool, insideIsAfter: Bool) -> Int {
            let w = Self.refineWindow
            let a = max(w, coarse - Self.refineBand), b = min(limit - w, coarse + Self.refineBand)
            guard b > a else { return coarse }
            let (f, e) = profile(horizontalLines: horizontalLines, from: a - w, to: b + w)
            var best = coarse, bestScore: Float = -1
            for cand in a..<b {
                let i = cand - (a - w)
                var before: Float = 0, after: Float = 0
                for k in 1...w { before += f[i - k]; after += f[i + k - 1] }
                before /= Float(w); after /= Float(w)
                let inside = insideIsAfter ? after : before
                let outside = insideIsAfter ? before : after
                guard inside >= Self.refineMinInside, inside >= outside * Self.refineContrastRatio else { continue }
                let score = (inside - outside) + e[i] * 0.5
                if score > bestScore { bestScore = score; best = cand }
            }
            return best
        }

        let ny0 = bestBoundary(coarse: y0, limit: fH, horizontalLines: true, insideIsAfter: true)
        let ny1 = bestBoundary(coarse: y1, limit: fH, horizontalLines: true, insideIsAfter: false)
        let nx0 = bestBoundary(coarse: x0, limit: fW, horizontalLines: false, insideIsAfter: true)
        let nx1 = bestBoundary(coarse: x1, limit: fW, horizontalLines: false, insideIsAfter: false)
        guard nx1 > nx0 + Self.fineScale, ny1 > ny0 + Self.fineScale else { return rect }
        return CGRect(x: CGFloat(nx0) / CGFloat(fW), y: CGFloat(ny0) / CGFloat(fH),
                      width: CGFloat(nx1 - nx0) / CGFloat(fW), height: CGFloat(ny1 - ny0) / CGFloat(fH))
    }

    private func resetState() {
        let size = Self.gridW * Self.gridH
        prevGrid = []
        prevFine = []
        currentFine = []
        fineChangeCount = [Int](repeating: 0, count: Self.fineW * Self.fineH)
        changeCount = [Int](repeating: 0, count: size)
        activeFrameCount = 0
        lastPublishedRect = nil
        stableCount = 0
        paintedCells = []
        hasSeenFirstKeyframe = false
        framesSinceAnalysis = 0
    }
}
