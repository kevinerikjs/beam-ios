// StreamOverlay.swift
// Controls overlay shown during streaming. Auto-hides after 3 seconds.
// Shows: connection quality, media controls, PiP button, timer (free tier), disconnect.

import SwiftUI

struct StreamOverlay: View {
    let appState: BeamAppState
    let pipController: PiPController
    let onDisconnect: () -> Void

    var body: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 40)
    }

    // MARK: - Top Bar

    @ViewBuilder
    private var topBar: some View {
        HStack {
            // Connection quality
            connectionQualityIndicator

            Spacer()

            // Free tier timer
            if !StoreManager.shared.isPurchased, let remaining = SessionManager.shared.secondsRemaining {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.caption2)
                    Text(SessionManager.shared.formattedTimeRemaining)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(remaining < 60 ? .orange : .white)
            }

            Spacer()

            // Disconnect
            Button {
                onDisconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
                    .background(
                        Circle().fill(.black.opacity(0.4))
                    )
            }
        }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Media controls
            mediaControls

            Spacer()

            // PiP button
            Button {
                pipController.start()
            } label: {
                Image(systemName: "pip.enter")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(12)
                    .background(
                        Circle().fill(.black.opacity(0.4))
                    )
            }
            .disabled(!pipController.isPiPPossible)
        }
    }

    // MARK: - Media Controls

    @ViewBuilder
    private var mediaControls: some View {
        HStack(spacing: 8) {
            MediaButton(
                systemName: "backward.fill",
                label: "Previous"
            ) {
                appState.connectionManager?.sendMediaKey(.previous)
            }

            MediaButton(
                systemName: "playpause.fill",
                label: "Play/Pause",
                large: true
            ) {
                appState.connectionManager?.sendMediaKey(.playPause)
            }

            MediaButton(
                systemName: "forward.fill",
                label: "Next"
            ) {
                appState.connectionManager?.sendMediaKey(.next)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Connection Quality

    @ViewBuilder
    private var connectionQualityIndicator: some View {
        let quality = appState.connectionQuality
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(quality > Double(i) / 4 ? Color.green : Color.white.opacity(0.3))
                    .frame(width: 3, height: CGFloat(6 + i * 3))
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Media Button

struct MediaButton: View {
    let systemName: String
    let label: String
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(large ? .title2 : .body)
                .foregroundStyle(.white)
                .frame(width: large ? 52 : 40, height: large ? 52 : 40)
        }
        .accessibilityLabel(label)
    }
}
