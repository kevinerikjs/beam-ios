// SettingsView.swift
// App settings — accessible from HomeView at any time, no active stream required.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: BeamAppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var session = SessionManager.shared
    @AppStorage("beam.keepViewportLock") private var keepViewportLock = true
    @AppStorage(ConnectionManager.streamAudioDefaultsKey) private var streamAudio = true
    @AppStorage(BeamAppState.remoteEnabledDefaultsKey) private var remoteEnabled = true
    @AppStorage("beam.flipHorizontal") private var flipHorizontal = false
    @AppStorage("beam.flipVertical") private var flipVertical = false
    @State private var showPaywall = false
    @State private var showFeedback = false
    @State private var showWhatsNew = false
    @State private var manualRemoteHost = ""
    #if DEBUG
    @AppStorage("beam.debug.forceRemoteHost") private var forceRemoteHost = false
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 32) {
                        streamCard
                        teleprompterCard
                        // Away From Home lives under Subscription because it IS a
                        // subscription feature; grouping it with Stream implied it was
                        // available to everyone.
                        subscriptionCard
                        remoteAccessCard
                        supportCard
                        aboutCard
                        #if DEBUG
                        debugCard
                        #endif
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackView()
        }
    }

    // MARK: - Stream card

    private var streamCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Stream")
            VStack(spacing: 0) {
                HStack {
                    Text("Default Quality")
                        .foregroundStyle(.white)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appState.preferredQualityPreset },
                        set: { appState.preferredQualityPreset = $0 }
                    )) {
                        ForEach(StreamQualityPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                cardDivider

                Toggle(isOn: $streamAudio) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stream Audio")
                            .foregroundStyle(.white)
                        Text("Off keeps the Mac from sending sound at all")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .onChange(of: streamAudio) { enabled in
                    appState.connectionManager?.setAudioEnabled(enabled)
                }

                cardDivider

                Toggle(isOn: $keepViewportLock) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep Viewport Lock")
                            .foregroundStyle(.white)
                        Text("Restore your screen crop between sessions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Teleprompter card

    private var teleprompterCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Teleprompter Mode")
            VStack(spacing: 0) {
                Toggle(isOn: $flipHorizontal) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Flip Horizontal")
                            .foregroundStyle(.white)
                        Text("Mirror left↔right for reflective glass setups")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                cardDivider

                Toggle(isOn: $flipVertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Flip Vertical")
                            .foregroundStyle(.white)
                        Text("Mirror top↔bottom")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Subscription card

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Subscription")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscriptionTitle)
                            .foregroundStyle(.white)
                            .fontWeight(.medium)
                        Text(subscriptionSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isPurchased {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if !store.isPurchased {
                    cardDivider
                    Button { showPaywall = true } label: {
                        HStack {
                            Text("Upgrade to Beam Unlimited")
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Debug card

    #if DEBUG
    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Development")
            VStack(spacing: 0) {
                Button {
                    Task { await StoreManager.shared.restore() }
                } label: {
                    HStack {
                        Text("Reset Purchase State")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                cardDivider

                // BEAM-19 debug aid: forces the Tailscale path while still on WiFi. The
                // connection genuinely routes over the tailnet, but the phone stays reachable
                // for log capture — which it isn't when actually off-network.
                Toggle(isOn: $forceRemoteHost) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Force Remote Host")
                            .foregroundStyle(.white)
                        Text("Skip Bonjour, always connect via the stored Tailscale address")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.yellow)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .onChange(of: forceRemoteHost) { _ in appState.startBrowsing() }
            }
            .background(Color.yellow.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow.opacity(0.2), lineWidth: 1))
        }
    }
    #endif

    // MARK: - Remote access card (BEAM-19)

    /// Away-from-home streaming over Tailscale. Only shown once a Mac is paired, since the
    /// address is per-Mac and meaningless before that.
    ///
    /// In the normal case the Mac reports its own tailnet address during pairing and this card
    /// just confirms it's set up. The text field exists for the case the Mac had no Tailscale
    /// when pairing happened — including a fully offline setup — so the user can fill it in
    /// later without having to unpair and start over.
    @ViewBuilder
    private var remoteAccessCard: some View {
        if let mac = appState.pairedMac {
            let autoHosts = mac.remoteHosts ?? []
            // Remote streaming is a Beam Unlimited feature (local streaming stays free).
            let locked = !appState.canUseRemoteStreaming
            let state = remoteState(for: mac)
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Away From Home")
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: locked ? "lock.fill" : remoteStatusIcon(state))
                                .foregroundStyle(.orange)
                            Text(locked ? "Beam Unlimited" : remoteStatusTitle(state))
                                .foregroundStyle(.white)
                        }
                        Text(locked
                             ? "Streaming from outside your home network is part of Beam Unlimited. Local streaming stays free."
                             : remoteStatusDetail(state, macName: mac.name))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if !locked {
                        cardDivider
                        Toggle(isOn: $remoteEnabled) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Connect When Away")
                                    .foregroundStyle(.white)
                                Text(remoteEnabled
                                     ? "Use the Tailscale address when your Mac isn't on this WiFi"
                                     : "Off. Local WiFi only; the address is kept for later")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.orange)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        cardDivider
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Quality When Away")
                                    .foregroundStyle(.white)
                                Text("Mobile and remote links carry far less than home WiFi")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker("", selection: Binding(
                                get: { appState.remoteQualityPreset },
                                set: { appState.remoteQualityPreset = $0 }
                            )) {
                                ForEach(StreamQualityPreset.allCases) { preset in
                                    Text(preset.displayName).tag(preset)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.orange)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        if appState.remoteQualityLikelyTooHigh {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                Text("Your connection right now probably can't carry \(appState.remoteQualityPreset.displayName). Video may stutter and audio may drop out. Auto adjusts to whatever the link can handle.")
                                    .font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                    }

                    if locked {
                        cardDivider
                        Button { showPaywall = true } label: {
                            HStack {
                                Text("Unlock Beam Unlimited").fontWeight(.medium)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                    }

                    if autoHosts.isEmpty && !locked && state != .hostNeedsUpdate {
                        // Preferred path for pairings made before the Mac advertised its
                        // address: one tap while on the same WiFi, no typing.
                        cardDivider
                        Button {
                            Task { await appState.setUpRemoteAccess() }
                        } label: {
                            HStack {
                                if appState.isSettingUpRemoteAccess {
                                    ProgressView().tint(.orange)
                                    Text("Setting Up…")
                                } else {
                                    Image(systemName: "wand.and.stars")
                                    Text("Set Up Automatically")
                                }
                                Spacer()
                            }
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .disabled(appState.isSettingUpRemoteAccess)

                        if let error = appState.remoteSetupError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        } else {
                            Text("Do this while you're on the same WiFi as your Mac.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }

                        cardDivider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Or Enter It Manually")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("100.x.y.z", text: $manualRemoteHost)
                                .textFieldStyle(.plain)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.numbersAndPunctuation)
                                .onSubmit { appState.setManualRemoteHost(manualRemoteHost) }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Find it in Beacon on your Mac under Settings → Paired Devices.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .onAppear { manualRemoteHost = mac.manualRemoteHost ?? "" }
            .onChange(of: manualRemoteHost) { _ in appState.setManualRemoteHost(manualRemoteHost) }
        }
    }

    /// Three genuinely different situations, each needing a different action from the user.
    /// They are indistinguishable from the address list alone, which is why the host reports
    /// `supportsRemoteAccess` (BEAM-19).
    private enum RemoteState {
        case ready              // We have an address; nothing to do.
        case manualOnly         // User typed one in; auto-discovery never supplied one.
        case hostNeedsTailscale // Mac understands remote access but isn't on a tailnet.
        case hostNeedsUpdate    // Mac predates the feature entirely.
    }

    private func remoteState(for mac: PairedMac) -> RemoteState {
        if !(mac.remoteHosts ?? []).isEmpty { return .ready }
        // nil means the Mac never claimed support, i.e. an older Beacon. false shouldn't
        // occur, but treating it as "needs update" is the safe reading.
        if mac.hostSupportsRemoteAccess != true { return .hostNeedsUpdate }
        if mac.manualRemoteHost != nil { return .manualOnly }
        return .hostNeedsTailscale
    }

    private func remoteStatusTitle(_ state: RemoteState) -> String {
        switch state {
        case .ready:              return "Ready"
        case .manualOnly:         return "Set Up Manually"
        case .hostNeedsTailscale: return "Not Set Up"
        case .hostNeedsUpdate:    return "Update Your Mac"
        }
    }

    private func remoteStatusIcon(_ state: RemoteState) -> String {
        switch state {
        case .ready, .manualOnly: return "globe"
        case .hostNeedsTailscale: return "house.slash"
        case .hostNeedsUpdate:    return "arrow.down.circle"
        }
    }

    private func remoteStatusDetail(_ state: RemoteState, macName: String) -> String {
        switch state {
        case .ready, .manualOnly:
            return "Your Mac shared its Tailscale address, so Beam can reach it when you're "
                 + "away. Keep Tailscale running on both devices."
        case .hostNeedsTailscale:
            return "Install Tailscale on \(macName) and sign in with the same account as this "
                 + "\(UIDevice.deviceNoun), then tap Set Up Automatically."
        case .hostNeedsUpdate:
            return "\(macName) is running a version of Beacon that doesn't support streaming "
                 + "from outside your network yet. Update Beacon on your Mac (Beacon → Check "
                 + "for Updates), then start a stream once at home to finish setup."
        }
    }

    // MARK: - Support card

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Support")
            VStack(spacing: 0) {
                Button {
                    showFeedback = true
                } label: {
                    HStack {
                        rowLabel("Send Feedback", systemImage: "bubble.left.and.bubble.right")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                cardDivider

                // Setting up a second Mac means installing Beacon on it, and until now the app
                // never said where to get it. Pairing is the one flow that starts on the other
                // device, so the download link has to be reachable from this one.
                Link(destination: URL(string: "https://beamscreen.app")!) {
                    HStack {
                        rowLabel("Get Beacon for a Mac", systemImage: "laptopcomputer.and.arrow.down")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                cardDivider

                Link(destination: URL(string: "https://beamscreen.app/guide/mirror-mac-to-iphone")!) {
                    HStack {
                        rowLabel("Setup Guide", systemImage: "book")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - About card (BEAM-27)

    /// AGPL-3.0 section 5 requires an interactive program to carry Appropriate Legal Notices:
    /// the licence it is under, and where the corresponding source can be had. That is the
    /// compliance floor. It sits in Settings rather than buried in a web page because for a
    /// screen-streaming app the honest answer to "what is this thing doing with my screen"
    /// is "read it yourself", and that is worth saying out loud.
    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("About")
            VStack(spacing: 0) {
                // Tapping the version reopens this release's notes.
                Button {
                    showWhatsNew = true
                } label: {
                    HStack {
                        Text("Version")
                            .foregroundStyle(.white)
                        Spacer()
                        Text(WhatsNewManager.appVersion)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Version \(WhatsNewManager.appVersion), show what's new")
                .sheet(isPresented: $showWhatsNew) {
                    WhatsNewView(
                        entries: WhatsNewManager.versionEntries,
                        subtitle: "Version \(WhatsNewManager.appVersion)"
                    ) {
                        showWhatsNew = false
                    }
                }

                cardDivider

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Open Source")
                            .foregroundStyle(.white)
                            .fontWeight(.medium)
                    }
                    Text("Beam is free software under the GNU Affero General Public License, version 3. You can read the source, build it yourself, and pass it on under the same licence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                cardDivider

                Link(destination: URL(string: "https://github.com/kevinerikjs/beam-ios")!) {
                    HStack {
                        Text("View Source on GitHub")
                            .fontWeight(.medium)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                cardDivider

                Link(destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!) {
                    HStack {
                        Text("Read the AGPL-3.0 Licence")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Helpers

    private var subscriptionTitle: String {
        if store.isPurchased { return "Beam Unlimited" }
        if session.isInTrial { return "Free Trial Active" }
        return "Free Tier"
    }

    private var subscriptionSubtitle: String {
        if store.isPurchased { return "Unlimited streaming, no restrictions" }
        if session.isInTrial {
            let d = session.trialDaysRemaining
            return "\(d) day\(d == 1 ? "" : "s") remaining in trial"
        }
        return "30 minutes of streaming per day"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
            .padding(.horizontal, 4)
    }

    /// Label whose icon sits in a fixed-width slot, so rows with different SF Symbols line up.
    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 26)
            Text(title)
        }
        .foregroundStyle(.white)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}
