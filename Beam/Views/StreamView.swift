// StreamView.swift
// Full-screen streaming view. Shows the Mac's screen with an auto-hiding overlay.

import SwiftUI
import AVFoundation

struct StreamView: View {
    @EnvironmentObject var appState: BeamAppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOverlay = true
    @State private var overlayHideTask: Task<Void, Never>? = nil
    @State private var showPaywall = false
    @State private var paywallTriggeredByExpiry = false
    @State private var showQualityPicker = false

    // Renderer and PiP are created once and persist
    @State private var renderer = VideoRenderer(frame: .zero)
    @StateObject private var pipController = PiPController()

    // Pinch-to-zoom + pan state
    @State private var videoScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var videoOffset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var videoContainerSize: CGSize = .zero
    @State private var isViewportLocked = false
    @State private var isSelectingViewportLock = false

    // Auto video detection
    @StateObject private var motionDetector = VideoMotionDetector()
    @State private var isAutoDetecting = false
    @State private var holdTimer: Task<Void, Never>? = nil
    @State private var detectionStartHaptic = false
    @State private var detectionLockHaptic = false

    // Hex glass reveal + user painting
    @State private var holdLocation: CGPoint? = nil       // current finger position (in container coords)
    @State private var paintedScreenPoints: [CGPoint] = [] // deduplicated finger path during detection
    @State private var paintedGridCells: Set<Int> = []     // corresponding detector grid cells
    @State private var isZooming = false                   // true while MagnificationGesture is active
    @State private var edgePanTask: Task<Void, Never>? = nil // pans video when brush near screen edge

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                // Video content
                VideoRendererView(renderer: renderer)
                    .ignoresSafeArea()
                    .scaleEffect(videoScale)
                    .offset(videoOffset)
                    .onAppear { videoContainerSize = geometry.size }
                    .onChange(of: geometry.size) { newSize in
                        videoContainerSize = newSize
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                // Cancel any pending hold-to-detect — pinch and hold conflict
                                if !isZooming {
                                    isZooming = true
                                    holdTimer?.cancel(); holdTimer = nil
                                    holdLocation = nil
                                }
                                guard !isViewportLocked, !isAutoDetecting else { return }
                                videoScale = max(1.0, min(baseScale * value, 5.0))
                            }
                            .onEnded { value in
                                isZooming = false
                                guard !isViewportLocked, !isAutoDetecting else { return }
                                videoScale = max(1.0, min(baseScale * value, 5.0))
                                baseScale = videoScale
                                if videoScale == 1.0 { resetZoom() }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard !isViewportLocked, !isAutoDetecting, videoScale > 1.0 else { return }
                                let maxX = videoContainerSize.width * (videoScale - 1) / 2
                                let maxY = videoContainerSize.height * (videoScale - 1) / 2
                                videoOffset = CGSize(
                                    width:  (baseOffset.width  + value.translation.width).clamped(to: -maxX...maxX),
                                    height: (baseOffset.height + value.translation.height).clamped(to: -maxY...maxY)
                                )
                            }
                            .onEnded { _ in
                                guard !isViewportLocked, !isAutoDetecting, videoScale > 1.0 else { return }
                                baseOffset = videoOffset
                            }
                    )
                    .onTapGesture(count: 2) {
                        guard !isViewportLocked else { return }
                        withAnimation(.spring(duration: 0.3)) { resetZoom() }
                    }
                    .onTapGesture {
                        toggleOverlay()
                    }
            }
            .ignoresSafeArea()
            // Hold-to-detect + painting:
            //   • Touch down → hex glass reveal appears, hold timer starts (0.6 s)
            //   • Move > 15 pt before timer → cancel (pan takes over), reveal hides
            //   • 0.6 s still → detection starts + haptic; finger movement now PAINTS priority region
            //   • Touch up → finish detection (lock if region found)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isSelectingViewportLock, !isZooming else {
                            holdTimer?.cancel(); holdTimer = nil
                            holdLocation = nil
                            return
                        }
                        holdLocation = value.location

                        if isAutoDetecting {
                            // Painting mode — every drag event extends the priority mask
                            addPaintPoint(value.location)
                            return
                        }

                        if holdTimer == nil {
                            holdTimer = Task {
                                try? await Task.sleep(for: .seconds(0.6))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    guard isSelectingViewportLock, !isAutoDetecting else { return }
                                    detectionStartHaptic.toggle()
                                    startAutoDetection()
                                }
                            }
                        }
                        // Cancel hold if finger moved too much (it's a pan gesture)
                        if hypot(value.translation.width, value.translation.height) > 15 {
                            holdTimer?.cancel(); holdTimer = nil
                            holdLocation = nil
                        }
                    }
                    .onEnded { _ in
                        holdTimer?.cancel(); holdTimer = nil
                        holdLocation = nil
                        if isAutoDetecting { finishAutoDetection() }
                    }
            )

            // Hex glass reveal — visible whenever in selection mode (hold to detect or painting)
            if isSelectingViewportLock {
                HexRevealOverlay(
                    holdLocation: holdLocation,
                    paintedPoints: paintedScreenPoints,
                    videoScale: videoScale,
                    videoOffset: videoOffset
                )
            }

            if isAutoDetecting {
                AutoDetectOverlay(
                    detector: motionDetector,
                    containerSize: videoContainerSize,
                    baseVideoRect: baseVideoRect(in: CGRect(origin: .zero, size: videoContainerSize)),
                    videoScale: videoScale,
                    videoOffset: videoOffset
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // Hide manual-selection overlay while auto-detecting
            if isSelectingViewportLock, !isAutoDetecting {
                ViewportLockSelectionOverlay(selectionFrame: viewportSelectionFrameInContainer())
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Controls overlay
            if showOverlay {
                StreamOverlay(
                    appState: appState,
                    pipController: pipController,
                    isViewportLocked: isViewportLocked,
                    isSelectingViewportLock: isSelectingViewportLock,
                    onStartViewportLockSelection: { startViewportLockSelection() },
                    onCancelViewportLockSelection: { cancelViewportLockSelection() },
                    onConfirmViewportLockSelection: { confirmViewportLockSelection() },
                    onUnlockViewport: { unlockViewport() },
                    onOpenQualityPicker: {
                        guard !isSelectingViewportLock else { return }
                        showOverlay = true
                        showQualityPicker = true
                    },
                    onUpgrade: { paywallTriggeredByExpiry = false; showPaywall = true },
                    onDisconnect: { appState.stopStream() }
                )
                .transition(.opacity)
            }
        }
        .onChange(of: detectionStartHaptic) { _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        .onChange(of: detectionLockHaptic) { _ in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            setupStreaming()
            scheduleOverlayHide()
            // Restore lock UI state from the previous session — the host re-applies
            // the lock on authSuccess, so we just need the button to reflect it.
            isViewportLocked = appState.lockedViewportRect != nil
        }
        .onDisappear {
            // Don't tear down PiP/renderer on view disappearance because this can be triggered
            // during background transitions where PiP should continue.
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(triggeredByExpiry: paywallTriggeredByExpiry)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerSheet(appState: appState)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .onDisappear {
                    scheduleOverlayHide()
                }
        }
        .onChange(of: appState.isStreaming) { isStreaming in
            if isStreaming {
                // Restore UI lock state from previous session — host keeps the lock on its side.
                isViewportLocked = appState.lockedViewportRect != nil
            } else {
                pipController.teardown()
                renderer.flush()
            }
        }
        .onChange(of: scenePhase) { phase in
            guard appState.isStreaming else { return }
            switch phase {
            case .background:
                // Only pause if PiP didn't take over — if PiP is active the user is still watching.
                if !pipController.isPiPActive {
                    SessionManager.shared.pauseSession()
                }
            case .active:
                SessionManager.shared.resumeSession()
            default:
                break
            }
        }
        .onChange(of: pipController.isPiPActive) { isActive in
            // Keep ConnectionManager aware of PiP state so it relaxes inactivity timeouts
            // when running in the background — iOS throttles network delivery for background apps.
            appState.connectionManager?.isPiPActive = isActive
            guard appState.isStreaming else { return }
            if isActive {
                // PiP started — user is still watching, resume if we paused during the transition.
                SessionManager.shared.resumeSession()
            } else if scenePhase == .background {
                // PiP was dismissed while in background — user is no longer watching.
                SessionManager.shared.pauseSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
            paywallTriggeredByExpiry = true
            showPaywall = true
            appState.stopStream()
        }
    }

    // MARK: - Setup

    private func setupStreaming() {
        guard let manager = appState.connectionManager else { return }
        manager.streamReceiver.videoRenderer = renderer
        pipController.setup(with: renderer)

        // Feed sample buffers to motion detector when active
        renderer.onSampleBuffer = { [weak motionDetector] (buf: CMSampleBuffer) in
            motionDetector?.feed(buf)
        }

        // Wire session expiry
        SessionManager.shared.onSessionExpired = {
            NotificationCenter.default.post(name: .sessionExpired, object: nil)
        }
    }

    // MARK: - Zoom

    private func resetZoom() {
        videoScale = 1.0
        baseScale  = 1.0
        videoOffset = .zero
        baseOffset  = .zero
    }

    private func startViewportLockSelection() {
        guard !isViewportLocked else { return }
        isSelectingViewportLock = true
        showOverlay = true
        overlayHideTask?.cancel()
    }

    private func cancelViewportLockSelection() {
        isSelectingViewportLock = false
        scheduleOverlayHide()
    }

    private func confirmViewportLockSelection() {
        guard let manager = appState.connectionManager else { return }
        let lockedRect = currentNormalizedViewportRect(for: viewportSelectionFrameInContainer())
        manager.sendViewportLock(lockedRect)
        appState.lockedViewportRect = lockedRect
        isViewportLocked = true
        isSelectingViewportLock = false
        resetZoom()
        scheduleOverlayHide()
    }

    private func unlockViewport() {
        guard let manager = appState.connectionManager else { return }
        appState.lockedViewportRect = nil
        isViewportLocked = false
        isSelectingViewportLock = false
        manager.sendViewportLock(nil)
    }

    private func startAutoDetection() {
        guard isSelectingViewportLock, !isAutoDetecting else { return }
        guard let formatDesc = appState.connectionManager?.streamReceiver.cachedFormatDesc else { return }
        // Reset paint state for fresh detection session
        paintedScreenPoints = []
        paintedGridCells = []
        isAutoDetecting = true
        motionDetector.start(formatDescription: formatDesc)
    }

    private func finishAutoDetection() {
        isAutoDetecting = false
        holdLocation = nil
        paintedScreenPoints = []
        paintedGridCells = []
        edgePanTask?.cancel(); edgePanTask = nil
        motionDetector.stop()
        if let detected = motionDetector.detectedRect, let manager = appState.connectionManager {
            // Send the raw detected rect — the macOS host's constrained16x9Rect() will expand
            // it to 16:9 in source display space, which is the correct coordinate space.
            // Expanding to 16:9 here (video frame space) causes a double-expansion on non-16:9
            // Mac displays (e.g. 16:10 MacBook Pro) that shifts the locked region rightward.
            manager.sendViewportLock(detected)
            appState.lockedViewportRect = detected
            detectionLockHaptic.toggle()
            isViewportLocked = true
            isSelectingViewportLock = false
            resetZoom()
            scheduleOverlayHide()
        } else {
            // Nothing detected — stay in selection mode so user can try again or select manually
            showOverlay = true
            overlayHideTask?.cancel()
        }
    }

    /// Record a finger paint point during auto-detection.
    /// Deduplicates (min 15 pt spacing), inverse-transforms through current zoom/pan to get
    /// the correct video-normalised coordinate, then pushes the updated mask to the detector.
    /// Also triggers edge-pan when the brush is near the screen boundary.
    private func addPaintPoint(_ screenPoint: CGPoint) {
        let container = CGRect(origin: .zero, size: videoContainerSize)
        let bvr = baseVideoRect(in: container)
        guard bvr.width > 0, bvr.height > 0 else { return }

        // Inverse zoom transform: screen → unzoomed container coords
        // (mirrors inverseTransformedRect but for a single point)
        let cx = container.midX, cy = container.midY
        let scale = max(videoScale, 1.0)
        let ux = cx + (screenPoint.x - videoOffset.width  - cx) / scale
        let uy = cy + (screenPoint.y - videoOffset.height - cy) / scale

        // Deduplicate in unzoomed space so spacing is stable regardless of zoom level
        if let last = paintedScreenPoints.last,
           hypot(ux - last.x, uy - last.y) < 15 { return }
        // Store in unzoomed container coords — HexRevealOverlay re-applies the video
        // transform so the hex trail moves with the video surface when panning.
        paintedScreenPoints.append(CGPoint(x: ux, y: uy))

        let normX = (ux - bvr.minX) / bvr.width
        let normY = (uy - bvr.minY) / bvr.height
        // Allow painting anywhere on the full video, not just the visible viewport
        guard normX >= 0, normX <= 1, normY >= 0, normY <= 1 else {
            startEdgePan(for: screenPoint)
            return
        }

        let gW = VideoMotionDetector.gridW
        let gH = VideoMotionDetector.gridH
        let gcx = Int(normX * CGFloat(gW))
        let gcy = Int(normY * CGFloat(gH))
        for dy in -2...2 {
            for dx in -2...2 {
                let nx = gcx + dx, ny = gcy + dy
                if nx >= 0, nx < gW, ny >= 0, ny < gH {
                    paintedGridCells.insert(ny * gW + nx)
                }
            }
        }
        motionDetector.setPaintMask(paintedGridCells)

        // Edge-pan when brush is near the screen border
        startEdgePan(for: screenPoint)
    }

    /// Starts a continuous pan task when the paint brush is within 60 pt of a screen edge.
    /// Cancels immediately if the finger is not near any edge or the video is not zoomed.
    private func startEdgePan(for location: CGPoint) {
        let zone: CGFloat = 60
        let speed: CGFloat = 8
        var dx: CGFloat = 0, dy: CGFloat = 0

        if location.x < zone                              { dx = +(zone - location.x) / zone * speed }
        else if location.x > videoContainerSize.width - zone  { dx = -(location.x - (videoContainerSize.width  - zone)) / zone * speed }
        if location.y < zone                              { dy = +(zone - location.y) / zone * speed }
        else if location.y > videoContainerSize.height - zone { dy = -(location.y - (videoContainerSize.height - zone)) / zone * speed }

        edgePanTask?.cancel(); edgePanTask = nil
        guard (dx != 0 || dy != 0), videoScale > 1.0 else { return }

        edgePanTask = Task {
            while !Task.isCancelled {
                let maxX = videoContainerSize.width  * (videoScale - 1) / 2
                let maxY = videoContainerSize.height * (videoScale - 1) / 2
                videoOffset = CGSize(
                    width:  (videoOffset.width  + dx).clamped(to: -maxX...maxX),
                    height: (videoOffset.height + dy).clamped(to: -maxY...maxY)
                )
                baseOffset = videoOffset
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func currentNormalizedViewportRect(for selectionFrame: CGRect) -> CGRect {
        let container = CGRect(origin: .zero, size: videoContainerSize)
        guard container.width > 0, container.height > 0, selectionFrame.width > 0, selectionFrame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let baseRect = baseVideoRect(in: container)
        guard baseRect.width > 0, baseRect.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let untransformedRect = inverseTransformedRect(selectionFrame, in: container)
            .intersection(baseRect)

        guard untransformedRect.width > 0, untransformedRect.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let x = ((untransformedRect.minX - baseRect.minX) / baseRect.width).clamped(to: 0...1)
        let y = ((untransformedRect.minY - baseRect.minY) / baseRect.height).clamped(to: 0...1)
        let width = (untransformedRect.width / baseRect.width).clamped(to: 0.05...1)
        let height = (untransformedRect.height / baseRect.height).clamped(to: 0.05...1)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func viewportSelectionFrameInContainer() -> CGRect {
        let container = CGRect(origin: .zero, size: videoContainerSize)
        guard container.width > 0, container.height > 0 else {
            return .zero
        }

        let transformedVideoRect = transformedRect(baseVideoRect(in: container), in: container)
        let visibleVideoRect = transformedVideoRect.intersection(container)
        guard !visibleVideoRect.isNull, visibleVideoRect.width > 0, visibleVideoRect.height > 0 else {
            return largest16x9Rect(in: container)
        }
        return largest16x9Rect(in: visibleVideoRect)
    }

    private func baseVideoRect(in container: CGRect) -> CGRect {
        let aspect: CGFloat = 16.0 / 9.0
        let containerAspect = container.width / max(container.height, 1)
        if containerAspect > aspect {
            let height = container.height
            let width = height * aspect
            return CGRect(
                x: container.midX - width / 2,
                y: container.minY,
                width: width,
                height: height
            )
        } else {
            let width = container.width
            let height = width / aspect
            return CGRect(
                x: container.minX,
                y: container.midY - height / 2,
                width: width,
                height: height
            )
        }
    }

    private func transformedRect(_ rect: CGRect, in container: CGRect) -> CGRect {
        let center = CGPoint(x: container.midX, y: container.midY)
        let transformedOrigin = CGPoint(
            x: center.x + (rect.minX - center.x) * videoScale + videoOffset.width,
            y: center.y + (rect.minY - center.y) * videoScale + videoOffset.height
        )
        return CGRect(
            x: transformedOrigin.x,
            y: transformedOrigin.y,
            width: rect.width * videoScale,
            height: rect.height * videoScale
        )
    }

    private func inverseTransformedRect(_ rect: CGRect, in container: CGRect) -> CGRect {
        let center = CGPoint(x: container.midX, y: container.midY)
        let scale = max(videoScale, 1)

        let minX = center.x + (rect.minX - videoOffset.width - center.x) / scale
        let minY = center.y + (rect.minY - videoOffset.height - center.y) / scale
        let maxX = center.x + (rect.maxX - videoOffset.width - center.x) / scale
        let maxY = center.y + (rect.maxY - videoOffset.height - center.y) / scale

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    private func largest16x9Rect(in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let targetAspect: CGFloat = 16.0 / 9.0
        let rectAspect = rect.width / rect.height
        let width: CGFloat
        let height: CGFloat
        if rectAspect > targetAspect {
            height = rect.height
            width = height * targetAspect
        } else {
            width = rect.width
            height = width / targetAspect
        }
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Overlay

    private func toggleOverlay() {
        guard !isSelectingViewportLock, !isAutoDetecting else {
            showOverlay = true
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            showOverlay.toggle()
        }
        if showOverlay, !showQualityPicker, !isSelectingViewportLock { scheduleOverlayHide() }
    }

    private func scheduleOverlayHide() {
        guard !showQualityPicker, !isSelectingViewportLock, !isAutoDetecting else { return }
        overlayHideTask?.cancel()
        overlayHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                showOverlay = false
            }
        }
    }
}

// MARK: - HexRevealOverlay
// A liquid-glass pill follows the finger — the hex grid is INVISIBLE until painted.
// As the user drags, the hex cells appear in the trail left by the pill, like pressing
// a glass stamp into a surface. The pill is the brush; the hexagons are the ink.

private struct HexRevealOverlay: View {
    let holdLocation: CGPoint?
    let paintedPoints: [CGPoint]   // deduplicated points in UNZOOMED container coords
    let videoScale: CGFloat
    let videoOffset: CGSize

    private static let hexR: CGFloat = 21          // hex circumradius
    private static let pillDiameter: CGFloat = 52  // glass circle diameter
    private static let orange = Color.orange

    @State private var pillScale: CGFloat = 0.5
    @State private var pillOpacity: CGFloat = 0

    var body: some View {
        ZStack {
            // ── Hex trail (only painted cells, invisible elsewhere) ───────────
            // paintedPoints are stored in unzoomed container coords.
            // We apply the same video transform to the Canvas so the hex grid
            // moves with the video surface when the user pans during detection.
            Canvas { ctx, size in
                guard !paintedPoints.isEmpty else { return }
                let r    = Self.hexR
                let hexW = r * sqrt(3.0)
                let colP = hexW
                let rowP = r * 1.5

                // Mirror StreamView.transformedRect: scale from center, then offset.
                // After this transform, drawing in unzoomed container coords renders
                // at the correct zoomed+panned screen position.
                let midX = size.width / 2, midY = size.height / 2
                let videoTransform = CGAffineTransform.identity
                    .translatedBy(x: midX + videoOffset.width, y: midY + videoOffset.height)
                    .scaledBy(x: videoScale, y: videoScale)
                    .translatedBy(x: -midX, y: -midY)
                ctx.concatenate(videoTransform)

                let cols = Int(size.width  / colP) + 3
                let rows = Int(size.height / rowP) + 3

                for row in -1..<rows {
                    for col in -1..<cols {
                        let cx = CGFloat(col) * colP + (row % 2 == 1 ? hexW * 0.5 : 0)
                        let cy = CGFloat(row) * rowP

                        // Proximity check in unzoomed container space — consistent with
                        // how paintedPoints are stored.
                        guard paintedPoints.contains(where: { hypot(cx - $0.x, cy - $0.y) < hexW }) else { continue }

                        var hex = Path()
                        for i in 0..<6 {
                            let angle = CGFloat(i) * .pi / 3.0 + .pi / 6.0
                            let pt = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
                            i == 0 ? hex.move(to: pt) : hex.addLine(to: pt)
                        }
                        hex.closeSubpath()

                        ctx.fill(hex,   with: .color(Self.orange.opacity(0.07)))
                        ctx.stroke(hex, with: .color(Self.orange.opacity(0.72)),
                                   style: StrokeStyle(lineWidth: 1.2))
                    }
                }
            }
            .blendMode(.screen)
            .allowsHitTesting(false)

            // ── Liquid glass circle at finger position ───────────────────────
            if let hold = holdLocation {
                GlassPill()
                    .frame(width: Self.pillDiameter, height: Self.pillDiameter)
                    .scaleEffect(pillScale)
                    .opacity(pillOpacity)
                    .position(hold)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: holdLocation) { newLoc in
            if newLoc != nil {
                withAnimation(.spring(duration: 0.25, bounce: 0.35)) {
                    pillScale = 1.0; pillOpacity = 1.0
                }
            } else {
                withAnimation(.easeIn(duration: 0.18)) {
                    pillScale = 0.7; pillOpacity = 0
                }
            }
        }
    }
}

// MARK: - GlassPill
// iOS 26+: native Liquid Glass circle.
// iOS 17–25: frosted material circle with subtle border (visual parity fallback).

private struct GlassPill: View {
    private static let orange = Color.orange

    var body: some View {
        ZStack {
            // Subtle orange glow behind the glass — gives it the brand identity
            // without tinting the glass itself and killing the transparency.
            Circle()
                .fill(Self.orange.opacity(0.18))
                .blur(radius: 10)
                .scaleEffect(1.3)

            if #available(iOS 26, *) {
                Color.clear
                    .glassEffect(.regular, in: .circle)
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            }
        }
    }
}

private struct ViewportLockSelectionOverlay: View {
    let selectionFrame: CGRect

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            ZStack {
                Path { path in
                    path.addRect(bounds)
                    path.addRoundedRect(in: selectionFrame, cornerSize: CGSize(width: 16, height: 16))
                }
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))

                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.orange.opacity(0.95), lineWidth: 2)
                    .frame(width: selectionFrame.width, height: selectionFrame.height)
                    .position(x: selectionFrame.midX, y: selectionFrame.midY)

                // Tooltip at top
                VStack {
                    VStack(spacing: 2) {
                        Text("Lock viewport to a screen area")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Use Cancel/Confirm above · or hold to auto-detect video")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 16)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - AutoDetectOverlay
// Shows a live-growing blue transparent box over detected motion regions.
// Marching-ants border while scanning; solid glow border when confident.

private struct AutoDetectOverlay: View {
    @ObservedObject var detector: VideoMotionDetector
    let containerSize: CGSize
    let baseVideoRect: CGRect
    let videoScale: CGFloat
    let videoOffset: CGSize

    private static let orange = Color.orange

    @State private var dashPhase: CGFloat = 0
    @State private var glowPulse: CGFloat = 1.0

    var body: some View {
        ZStack {
            if let normRect = detector.detectedRect {
                let sr = screenRect(from: normRect)
                detectionBox(in: sr)
                    // spring(duration:bounce:) — smooth physical expand, slight snap at confidence
                    .animation(.spring(duration: detector.isConfident ? 0.3 : 0.4,
                                       bounce: detector.isConfident ? 0.12 : 0.0), value: sr)
            }

            // Bottom tooltip
            VStack {
                Spacer()
                bottomTooltip
                    .padding(.bottom, 48)
            }
        }
        .onAppear { startAnimations() }
        .onChange(of: detector.isConfident) { confident in
            if confident {
                // Switch to slow glow pulse
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    glowPulse = 1.6
                }
            }
        }
    }

    // MARK: - Detection box

    private func detectionBox(in sr: CGRect) -> some View {
        ZStack {
            // Transparent blue fill — video still fully visible underneath
            RoundedRectangle(cornerRadius: 8)
                .fill(Self.orange.opacity(detector.isConfident ? 0.13 : 0.07))
                .frame(width: sr.width, height: sr.height)
                .position(x: sr.midX, y: sr.midY)

            // Marching ants → solid glow on confidence
            if detector.isConfident {
                // Solid glowing border — 3 shadow layers for neon bloom
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Self.orange, lineWidth: 2.5)
                    .shadow(color: Self.orange.opacity(0.9), radius: 5)           // inner glow
                    .shadow(color: Self.orange.opacity(0.45 * glowPulse), radius: 14 * glowPulse) // mid
                    .shadow(color: Self.orange.opacity(0.15), radius: 28)         // outer bloom
                    .frame(width: sr.width, height: sr.height)
                    .position(x: sr.midX, y: sr.midY)

                // Corner brackets
                ForEach(CornerBracketShape.Corner.allCases, id: \.self) { corner in
                    CornerBracketShape(corner: corner)
                        .stroke(Self.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 20, height: 20)
                        .position(cornerPos(corner, in: sr))
                        .shadow(color: Self.orange.opacity(0.7), radius: 4)
                }
            } else {
                // Marching-ants dashed border (scanning state)
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        Self.orange.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8, 6], dashPhase: dashPhase)
                    )
                    .shadow(color: Self.orange.opacity(0.6), radius: 8)
                    .frame(width: sr.width, height: sr.height)
                    .position(x: sr.midX, y: sr.midY)
            }
        }
    }

    // MARK: - Tooltip

    private var bottomTooltip: some View {
        Group {
            if detector.isConfident {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Self.orange)
                    Text("Video found · release to lock · still refining…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            } else if detector.detectedRect != nil {
                HStack(spacing: 7) {
                    ProgressView().progressViewStyle(.circular).tint(Self.orange).scaleEffect(0.75)
                    Text("Locking onto video area…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
            } else {
                HStack(spacing: 7) {
                    ProgressView().progressViewStyle(.circular).tint(Self.orange).scaleEffect(0.75)
                    Text("Scanning for video…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.spring(duration: 0.3), value: detector.isConfident)
        .animation(.spring(duration: 0.3), value: detector.detectedRect != nil)
    }

    // MARK: - Helpers

    private func startAnimations() {
        // dash: [8, 6] → phase must move by -(8+6)=-14 per cycle for seamless loop
        withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
            dashPhase -= 14
        }
    }

    private func screenRect(from normRect: CGRect) -> CGRect {
        // Step 1: normalized video coords → unzoomed container rect
        let unzoomed = CGRect(
            x: baseVideoRect.minX + normRect.minX * baseVideoRect.width,
            y: baseVideoRect.minY + normRect.minY * baseVideoRect.height,
            width: normRect.width  * baseVideoRect.width,
            height: normRect.height * baseVideoRect.height
        )
        // Step 2: apply current zoom transform (mirrors StreamView.transformedRect)
        let cx = containerSize.width / 2, cy = containerSize.height / 2
        let ox = cx + (unzoomed.minX - cx) * videoScale + videoOffset.width
        let oy = cy + (unzoomed.minY - cy) * videoScale + videoOffset.height
        return CGRect(x: ox, y: oy,
                      width: unzoomed.width  * videoScale,
                      height: unzoomed.height * videoScale)
    }

    private func cornerPos(_ corner: CornerBracketShape.Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

// MARK: - CornerBracketShape

private struct CornerBracketShape: Shape {
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    let corner: Corner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        switch corner {
        case .topLeft:
            path.move(to: CGPoint(x: rect.minX + w, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h))
        case .topRight:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h))
        case .bottomLeft:
            path.move(to: CGPoint(x: rect.minX + w, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - h))
        case .bottomRight:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - h))
        }

        return path
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let sessionExpired = Notification.Name("BeamSessionExpired")
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
