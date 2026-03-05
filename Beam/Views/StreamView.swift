// StreamView.swift
// Full-screen streaming view. Shows the Mac's screen with an auto-hiding overlay.

import SwiftUI
import AVFoundation

struct StreamView: View {
    @Environment(BeamAppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOverlay = true
    @State private var overlayHideTask: Task<Void, Never>? = nil
    @State private var showPaywall = false
    @State private var showQualityPicker = false

    // Renderer and PiP are created once and persist
    @State private var renderer = VideoRenderer(frame: .zero)
    @State private var pipController = PiPController()

    // Pinch-to-zoom + pan state
    @State private var videoScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var videoOffset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var videoContainerSize: CGSize = .zero
    @State private var isViewportLocked = false
    @State private var isSelectingViewportLock = false

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
                    .onChange(of: geometry.size) { _, newSize in
                        videoContainerSize = newSize
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                guard !isViewportLocked else { return }
                                videoScale = max(1.0, min(baseScale * value, 5.0))
                            }
                            .onEnded { value in
                                guard !isViewportLocked else { return }
                                videoScale = max(1.0, min(baseScale * value, 5.0))
                                baseScale = videoScale
                                if videoScale == 1.0 { resetZoom() }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard !isViewportLocked, videoScale > 1.0 else { return }
                                let maxX = videoContainerSize.width * (videoScale - 1) / 2
                                let maxY = videoContainerSize.height * (videoScale - 1) / 2
                                videoOffset = CGSize(
                                    width:  (baseOffset.width  + value.translation.width).clamped(to: -maxX...maxX),
                                    height: (baseOffset.height + value.translation.height).clamped(to: -maxY...maxY)
                                )
                            }
                            .onEnded { _ in
                                guard !isViewportLocked, videoScale > 1.0 else { return }
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

            if isSelectingViewportLock {
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
                    onUpgrade: { showPaywall = true },
                    onDisconnect: { appState.stopStream() }
                )
                .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            setupStreaming()
            scheduleOverlayHide()
        }
        .onDisappear {
            // Don't tear down PiP/renderer on view disappearance because this can be triggered
            // during background transitions where PiP should continue.
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(triggeredByExpiry: true)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerSheet(appState: appState)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .onDisappear {
                    scheduleOverlayHide()
                }
        }
        .onChange(of: appState.isStreaming) { _, isStreaming in
            if !isStreaming {
                pipController.teardown()
                renderer.flush()
            }
        }
        .onChange(of: scenePhase) { _, phase in
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
        .onChange(of: pipController.isPiPActive) { _, isActive in
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
            showPaywall = true
            appState.stopStream()
        }
    }

    // MARK: - Setup

    private func setupStreaming() {
        guard let manager = appState.connectionManager else { return }
        manager.streamReceiver.videoRenderer = renderer
        pipController.setup(with: renderer)

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
        isViewportLocked = true
        isSelectingViewportLock = false
        resetZoom()
        scheduleOverlayHide()
    }

    private func unlockViewport() {
        guard let manager = appState.connectionManager else { return }
        isViewportLocked = false
        isSelectingViewportLock = false
        manager.sendViewportLock(nil)
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
        guard !isSelectingViewportLock else {
            showOverlay = true
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            showOverlay.toggle()
        }
        if showOverlay, !showQualityPicker, !isSelectingViewportLock { scheduleOverlayHide() }
    }

    private func scheduleOverlayHide() {
        guard !showQualityPicker, !isSelectingViewportLock else { return }
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
            }
        }
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
