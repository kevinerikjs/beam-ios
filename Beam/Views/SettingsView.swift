// SettingsView.swift
// App settings — accessible from HomeView at any time, no active stream required.

import SwiftUI

struct SettingsView: View {
    @Environment(BeamAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("beam.keepViewportLock") private var keepViewportLock = true
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 32) {
                        streamCard
                        subscriptionCard
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
                    if StoreManager.shared.isPurchased {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if !StoreManager.shared.isPurchased {
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

    // MARK: - Helpers

    private var subscriptionTitle: String {
        if StoreManager.shared.isPurchased { return "Beam Unlimited" }
        if SessionManager.shared.isInTrial { return "Free Trial Active" }
        return "Free Tier"
    }

    private var subscriptionSubtitle: String {
        if StoreManager.shared.isPurchased { return "Unlimited streaming, no restrictions" }
        if SessionManager.shared.isInTrial {
            let d = SessionManager.shared.trialDaysRemaining
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
