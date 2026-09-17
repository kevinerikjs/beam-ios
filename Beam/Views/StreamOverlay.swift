// StreamOverlay.swift
// Controls overlay shown during streaming. Auto-hides after 3 seconds.
// Uses Liquid Glass (iOS 26+) with ultraThinMaterial fallback.

import SwiftUI

struct StreamOverlay: View {
    @ObservedObject var appState: BeamAppState
    @ObservedObject var pipController: PiPController
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var session = SessionManager.shared
    let isViewportLocked: Bool
    let isSelectingViewportLock: Bool
    let onStartViewportLockSelection: () -> Void
    let onCancelViewportLockSelection: () -> Void
    let onConfirmViewportLockSelection: () -> Void
    let onUnlockViewport: () -> Void
    let onOpenQualityPicker: () -> Void
    let onOpenStreamSettings: () -> Void
    let onOpenWindowPicker: () -> Void
    let onUpgrade: () -> Void
    let onDisconnect: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPhone in portrait. The one layout where the bottom bar's full set of controls is
    /// wider than the screen, so it stacks into two rows there.
    private var isNarrowPortrait: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .regular
    }

    var body: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 44)
        // Never wider than the screen: an overflowing HStack would otherwise centre itself
        // and push both bars' outer buttons off the edges.
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top Bar

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 12) {
            connectionQualityIndicator

            if appState.usingRemoteHost {
                remoteLinkIndicator
            }

            if appState.isControllerConnected {
                controllerIndicator
            }

            Spacer()

            if !store.isPurchased, let remaining = session.secondsRemaining {
                sessionTimerBadge(remaining: remaining, onUpgrade: onUpgrade)
            }

            Spacer()

            // In narrow portrait these two live in the bottom bar instead; there is no room
            // up here next to the free-tier timer.
            if !isNarrowPortrait {
                if appState.hostSupportsWindowSelection {
                    windowPickerButton
                }
                audioToggleButton
            }

            // Quality indicator button
            Button {
                onOpenQualityPicker()
            } label: {
                Text(isNarrowPortrait ? compactQualityName : appState.currentQualityPreset.displayName)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .beamGlass()
            }

            Button {
                onOpenStreamSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .beamGlass()
            }

            disconnectButton
        }
    }

    // MARK: - Window Picker (BEAM-35)

    /// Only offered when the host said it can do this; an older Beacon never shows it.
    @ViewBuilder
    private var windowPickerButton: some View {
        Button {
            onOpenWindowPicker()
        } label: {
            Image(systemName: appState.isHostInWindowMode ? "macwindow.on.rectangle" : "macwindow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(appState.isHostInWindowMode ? Color.orange : .white)
                .frame(width: 32, height: 32)
                .beamGlass()
        }
        .accessibilityLabel(appState.isHostInWindowMode ? "Change Captured Window" : "Capture a Window")
    }

    // MARK: - Audio Toggle (BEAM-34)

    @AppStorage(ConnectionManager.streamAudioDefaultsKey) private var streamAudio = true

    /// Same switch as Settings → Stream Audio, just within reach mid-session. It is one
    /// preference, not a per-session override, so what you set here is what the next session
    /// starts with.
    @ViewBuilder
    private var audioToggleButton: some View {
        Button {
            streamAudio.toggle()
            appState.connectionManager?.setAudioEnabled(streamAudio)
        } label: {
            Image(systemName: streamAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(streamAudio ? .white : Color.orange)
                .frame(width: 32, height: 32)
                .beamGlass()
        }
        .accessibilityLabel(streamAudio ? "Mute Stream Audio" : "Unmute Stream Audio")
    }

    /// "1080p · 30 fps" → "1080p"; the fps half doesn't fit an iPhone in portrait.
    private var compactQualityName: String {
        let name = appState.currentQualityPreset.displayName
        return String(name.split(separator: " ").first ?? Substring(name))
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        if isNarrowPortrait {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    if appState.hostSupportsWindowSelection {
                        windowPickerButton
                    }
                    audioToggleButton
                    Spacer()
                    lockViewportControls
                    pipButton
                }
                HStack {
                    mediaControls
                    Spacer()
                }
            }
        } else {
            HStack(spacing: 0) {
                mediaControls
                Spacer()
                HStack(spacing: 10) {
                    lockViewportControls
                    pipButton
                }
            }
        }
    }

    // MARK: - Media Controls

    @ViewBuilder
    private var mediaControls: some View {
        HStack(spacing: 4) {
            MediaButton(systemName: "arrow.counterclockwise", label: "Seek Backward") { appState.connectionManager?.sendMediaKey(.seekBackward) }
            MediaButton(systemName: "backward.fill",   label: "Previous") { appState.connectionManager?.sendMediaKey(.previous) }
            MediaButton(systemName: "playpause.fill",  label: "Play/Pause", large: true) { appState.connectionManager?.sendMediaKey(.playPause) }
            MediaButton(systemName: "forward.fill",    label: "Next") { appState.connectionManager?.sendMediaKey(.next) }
            MediaButton(systemName: "arrow.clockwise", label: "Seek Forward") { appState.connectionManager?.sendMediaKey(.seekForward) }
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

    // MARK: - Controller Indicator

    @ViewBuilder
    private var controllerIndicator: some View {
        Image(systemName: "gamecontroller.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .beamGlass()
            .accessibilityLabel("Controller connected")
    }

    // MARK: - Remote Link Indicator (BEAM-23)

    /// Shown only on remote (Tailscale) sessions, and deliberately unlike the plain LAN
    /// signal bars: a globe plus a colour-coded state, because "connected but relayed" and
    /// "connected and direct" are the same word to the user yet completely different
    /// experiences. Tailscale starts relayed and upgrades, so the amber "Negotiating…" state
    /// is the honest answer to "why is it bad for the first few seconds".
    @ViewBuilder
    private var remoteLinkIndicator: some View {
        let quality = appState.remoteLinkQuality
        HStack(spacing: 5) {
            Image(systemName: quality == .direct ? "globe.badge.chevron.backward" : "globe")
                .font(.caption2.weight(.semibold))
            Text(quality.label)
                .font(.caption2.weight(.semibold))
            if quality == .connecting || quality == .marginal {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
            }
        }
        .foregroundStyle(remoteLinkColor(quality))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(remoteLinkColor(quality).opacity(0.16))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(remoteLinkColor(quality).opacity(0.35), lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: quality)
        .accessibilityLabel("Remote connection: \(quality.label)")
    }

    private func remoteLinkColor(_ q: BeamAppState.RemoteLinkQuality) -> Color {
        switch q {
        case .direct:     return .green
        case .marginal:   return .yellow
        case .relayed:    return .orange
        case .connecting: return .white.opacity(0.7)
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
    private func sessionTimerBadge(remaining: TimeInterval, onUpgrade: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.caption2)
                Text(session.formattedTimeRemaining)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .fixedSize()
            }
            .foregroundStyle(remaining < 60 ? Color.orange : Color.white)
            .lineLimit(1)

            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 8)

            Button {
                onUpgrade()
            } label: {
                Image(systemName: "crown.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
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
            List {
                // On a remote stream this picker edits the REMOTE setting, not the LAN one.
                // They are separate because the links are, and a value chosen for home WiFi is
                // usually wrong on cellular. Say which one is being changed so it is not a
                // surprise that the setting reverts when you get home.
                if appState.usingRemoteHost {
                    Section {
                        if appState.remoteQualityLikelyTooHigh {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Your connection right now probably can't carry \(appState.remoteQualityPreset.displayName). Video may stutter and audio may drop out. Auto adjusts to whatever the link can handle.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else {
                            Label("Setting the quality used over Tailscale", systemImage: "globe")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                ForEach(StreamQualityPreset.allCases) { preset in
                    qualityRow(preset)
                }
            }
            .tint(.orange)
            .listStyle(.plain)
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
            if appState.activeQualityPreset == preset {
                Image(systemName: "checkmark")
                    .foregroundStyle(.orange)
                    .fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Write to whichever route we are actually on.
            if appState.usingRemoteHost {
                appState.remoteQualityPreset = preset
            } else {
                appState.preferredQualityPreset = preset
            }
            dismiss()
        }
    }
}

// MARK: - Host Window Picker Sheet (BEAM-35)

struct HostWindowPickerSheet: View {
    @ObservedObject var appState: BeamAppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        appState.connectionManager?.selectHostWindow(0)
                        dismiss()
                    } label: {
                        row(title: "Full Display", subtitle: "Everything on the Mac's screen",
                            systemImage: "display", selected: !appState.isHostInWindowMode)
                    }
                }

                Section {
                    if appState.isLoadingHostWindows && appState.hostWindows.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().tint(.white)
                            Spacer()
                        }
                    } else if appState.hostWindows.isEmpty {
                        Text("No windows to show. Open something on the Mac and pull to refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.hostWindows) { window in
                            Button {
                                appState.connectionManager?.selectHostWindow(window.id)
                                dismiss()
                            } label: {
                                row(title: window.title.isEmpty ? window.app : window.title,
                                    subtitle: window.title.isEmpty ? "" : window.app,
                                    systemImage: "macwindow",
                                    selected: appState.hostCaptureMode?.windowID == window.id)
                            }
                        }
                    }
                } header: {
                    Text("Windows")
                } footer: {
                    Text("Locks the stream to one window, even when it is behind others on the Mac.")
                }
            }
            .tint(.orange)
            .refreshable { appState.connectionManager?.requestWindowList() }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { appState.connectionManager?.requestWindowList() }
    }

    @ViewBuilder
    private func row(title: String, subtitle: String, systemImage: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(selected ? Color.orange : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Stream Settings Sheet

struct StreamSettingsSheet: View {
    let appState: BeamAppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("beam.keepViewportLock") private var keepViewportLock = true
    @AppStorage(ConnectionManager.streamAudioDefaultsKey) private var streamAudio = true
    @AppStorage("beam.flipHorizontal") private var flipHorizontal = false
    @AppStorage("beam.flipVertical") private var flipVertical = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Stream Audio", isOn: $streamAudio)
                        .tint(.orange)
                        .onChange(of: streamAudio) { enabled in
                            appState.connectionManager?.setAudioEnabled(enabled)
                        }
                } header: {
                    Text("Audio")
                } footer: {
                    if !streamAudio, let cm = appState.connectionManager, !cm.hostSupportsAudioToggle {
                        Text("This Mac's Beacon is too old to stop sending audio, so it is muted on the phone instead. Update Beacon to save bandwidth.")
                    } else {
                        Text("Off keeps the Mac from sending sound at all.")
                    }
                }

                Section("Stream") {
                    Picker("Quality", selection: Binding(
                        get: { appState.preferredQualityPreset },
                        set: { appState.preferredQualityPreset = $0 }
                    )) {
                        ForEach(StreamQualityPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .tint(.orange)

                    Toggle("Keep Viewport Lock", isOn: $keepViewportLock)
                        .tint(.orange)
                }

                Section {
                    Toggle("Flip Horizontal", isOn: $flipHorizontal)
                        .tint(.orange)
                    Toggle("Flip Vertical", isOn: $flipVertical)
                        .tint(.orange)
                } header: {
                    Text("Teleprompter Mode")
                } footer: {
                    Text("Mirrors the image for use with reflective teleprompter glass.")
                }
            }
            .tint(.orange)
            .navigationTitle("Stream Settings")
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
