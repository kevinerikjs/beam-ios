// StreamOverlay.swift
// Controls overlay shown during streaming. Auto-hides after 3 seconds.
// Uses Liquid Glass (iOS 26+) with ultraThinMaterial fallback.

import SwiftUI

struct StreamOverlay: View {
    let appState: BeamAppState
    let pipController: PiPController
    let isViewportLocked: Bool
    let isSelectingViewportLock: Bool
    let onStartViewportLockSelection: () -> Void
    let onCancelViewportLockSelection: () -> Void
    let onConfirmViewportLockSelection: () -> Void
    let onUnlockViewport: () -> Void
    let onOpenQualityPicker: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 44)
    }

    // MARK: - Top Bar

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 12) {
            connectionQualityIndicator

            Spacer()

            if !StoreManager.shared.isPurchased, let remaining = SessionManager.shared.secondsRemaining {
                sessionTimerBadge(remaining: remaining)
            }

            Spacer()

            // Quality indicator button
            Button {
                onOpenQualityPicker()
            } label: {
                Text(appState.currentQualityPreset.displayName)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .beamGlass()
            }

            disconnectButton
        }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 0) {
            mediaControls
            Spacer()
            HStack(spacing: 10) {
                lockViewportControls
                pipButton
            }
        }
    }

    // MARK: - Media Controls

    @ViewBuilder
    private var mediaControls: some View {
        HStack(spacing: 4) {
            MediaButton(systemName: "backward.fill",   label: "Previous") { appState.connectionManager?.sendMediaKey(.previous) }
            MediaButton(systemName: "playpause.fill",  label: "Play/Pause", large: true) { appState.connectionManager?.sendMediaKey(.playPause) }
            MediaButton(systemName: "forward.fill",    label: "Next") { appState.connectionManager?.sendMediaKey(.next) }
        }
        .padding(10)
        .beamGlass()
    }

    // MARK: - PiP Button

    @ViewBuilder
    private var pipButton: some View {
        Button {
            pipController.start()
        } label: {
            Image(systemName: "pip.enter")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .beamGlass()
        }
        .disabled(!pipController.isPiPSupported)
    }

    // MARK: - Viewport Lock Button

    @ViewBuilder
    private var lockViewportControls: some View {
        Group {
            if isSelectingViewportLock {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            onCancelViewportLockSelection()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .beamGlass()
                    }
                    .accessibilityLabel("Cancel Viewport Selection")

                    Button {
                        withAnimation(.spring(duration: 0.28, bounce: 0.22)) {
                            onConfirmViewportLockSelection()
                        }
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 48, height: 48)
                            .beamGlass()
                    }
                    .accessibilityLabel("Confirm Viewport Selection")
                }
            } else {
                Button {
                    withAnimation(.spring(duration: 0.28, bounce: 0.22)) {
                        if isViewportLocked {
                            onUnlockViewport()
                        } else {
                            onStartViewportLockSelection()
                        }
                    }
                } label: {
                    Image(systemName: isViewportLocked ? "lock.fill" : "lock.open.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.title3)
                        .foregroundStyle(isViewportLocked ? Color.orange : .white)
                        .frame(width: 48, height: 48)
                        .beamGlass()
                }
                .accessibilityLabel(isViewportLocked ? "Unlock Viewport" : "Lock Viewport")
            }
        }
    }

    // MARK: - Disconnect Button

    @ViewBuilder
    private var disconnectButton: some View {
        Button {
            onDisconnect()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .beamGlass()
        }
    }

    // MARK: - Connection Quality

    @ViewBuilder
    private var connectionQualityIndicator: some View {
        let quality = appState.connectionQuality
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(quality > Double(i) / 4 ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 3, height: CGFloat(6 + i * 3))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .beamGlass()
    }

    // MARK: - Session Timer

    @ViewBuilder
    private func sessionTimerBadge(remaining: TimeInterval) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.caption2)
            Text(SessionManager.shared.formattedTimeRemaining)
                .font(.system(.caption, design: .monospaced).weight(.medium))
        }
        .foregroundStyle(remaining < 60 ? Color.orange : Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .beamGlass()
    }
}

// MARK: - Quality Picker Sheet

struct QualityPickerSheet: View {
    let appState: BeamAppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(StreamQualityPreset.allCases) { preset in
                qualityRow(preset)
            }
            .tint(.orange)
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .navigationTitle("Stream Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func qualityRow(_ preset: StreamQualityPreset) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                    .foregroundStyle(.white)
                if preset == .auto {
                    Text("Adapts to connection quality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(preset.width)×\(preset.height) · \(String(format: "%.1f", preset.bitrateMbps)) Mbps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if appState.preferredQualityPreset == preset {
                Image(systemName: "checkmark")
                    .foregroundStyle(.orange)
                    .fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.preferredQualityPreset = preset
            dismiss()
        }
    }
}

// MARK: - Beam Glass modifier

/// Applies Liquid Glass (iOS 26+) with ultraThinMaterial fallback for older OS.
struct BeamGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

extension View {
    func beamGlass() -> some View { modifier(BeamGlassModifier()) }
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
