// SettingsView.swift
// App settings — accessible from HomeView at any time, no active stream required.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: BeamAppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var session = SessionManager.shared
    @AppStorage("beam.keepViewportLock") private var keepViewportLock = true
    @State private var showPaywall = false
    @State private var showFeedback = false
    @State private var manualRemoteHost = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 32) {
                        streamCard
                        remoteAccessCard
                        subscriptionCard
                        supportCard
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
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Away From Home")
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: autoHosts.isEmpty && mac.manualRemoteHost == nil
                                  ? "house.slash" : "globe")
                                .foregroundStyle(.orange)
                            Text(remoteStatusTitle(auto: autoHosts, manual: mac.manualRemoteHost))
                                .foregroundStyle(.white)
                        }
                        Text(remoteStatusDetail(auto: autoHosts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if autoHosts.isEmpty {
                        cardDivider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mac's Tailscale Address")
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

    private func remoteStatusTitle(auto: [String], manual: String?) -> String {
        if !auto.isEmpty { return "Ready" }
        if manual != nil { return "Set Up Manually" }
        return "Not Set Up"
    }

    private func remoteStatusDetail(auto: [String]) -> String {
        if !auto.isEmpty {
            return "Your Mac shared its Tailscale address, so Beam can reach it when you're "
                 + "away. Keep Tailscale running on both devices."
        }
        return "Beam can stream from outside your home network when both devices are on the "
             + "same Tailscale account. Your Mac didn't report an address — add it below."
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
                        Label("Send Feedback", systemImage: "bubble.left.and.bubble.right")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
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

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}
