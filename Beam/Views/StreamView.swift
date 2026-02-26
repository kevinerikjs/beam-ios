// StreamView.swift
// Full-screen streaming view. Shows the Mac's screen with an auto-hiding overlay.

import SwiftUI
import AVFoundation

struct StreamView: View {
    @Environment(BeamAppState.self) private var appState
    @State private var showOverlay = true
    @State private var overlayHideTask: Task<Void, Never>? = nil
    @State private var showPaywall = false

    // Renderer and PiP are created once and persist
    @State private var renderer = VideoRenderer(frame: .zero)
    @State private var pipController = PiPController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video content
            VideoRendererView(renderer: renderer)
                .ignoresSafeArea()
                .onTapGesture {
                    toggleOverlay()
                }

            // Controls overlay
            if showOverlay {
                StreamOverlay(
                    appState: appState,
                    pipController: pipController,
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
            pipController.teardown()
            renderer.flush()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .onChange(of: appState.isStreaming) { _, isStreaming in
            if !isStreaming {
                // Stream ended externally
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

    // MARK: - Overlay

    private func toggleOverlay() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showOverlay.toggle()
        }
        if showOverlay { scheduleOverlayHide() }
    }

    private func scheduleOverlayHide() {
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

// MARK: - Notification Extension

extension Notification.Name {
    static let sessionExpired = Notification.Name("BeamSessionExpired")
}
