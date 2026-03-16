// HomeView.swift
// Main screen shown when not streaming. Displays connection status and "Start Beam" button.

import SwiftUI

struct HomeView: View {
    @Environment(BeamAppState.self) private var appState
    @State private var showPairing = false
    @State private var showPaywall = false
    @State private var showSettings = false
    @State private var showTrialExpiredModal = false
    @State private var showSetupGuide = false
    @State private var linkCopied = false
    @AppStorage("beam.trialExpiredModalShown") private var trialExpiredModalShown = false

    // Drives real-time cooldown countdown without requiring SessionManager to own a display timer.
    @State private var now = Date()
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App icon / logo area
                logoSection

                Spacer().frame(height: 48)

                // Status + action
                statusSection

                Spacer()

                // Bottom toolbar
                bottomBar
            }
            .padding(.horizontal, 32)
            .overlay(alignment: .topTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(24)
                }
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingView()
                .environment(appState)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .onAppear {
            if appState.pairedMac != nil {
                appState.startBrowsing()
            }
        }
        .onReceive(clockTick) { tick in
            now = tick
            checkTrialExpiry()
        }
        .onAppear {
            checkTrialExpiry()
        }
        .sheet(isPresented: $showTrialExpiredModal) {
            trialExpiredModal
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(appState)
        }
    }

    // MARK: - Trial Expiry Check

    private func checkTrialExpiry() {
        guard !trialExpiredModalShown,
              !StoreManager.shared.isPurchased,
              SessionManager.shared.hasTrialStarted,
              !SessionManager.shared.isInTrial else { return }
        trialExpiredModalShown = true
        showTrialExpiredModal = true
    }

    // MARK: - Trial Expired Modal

    @ViewBuilder
    private var trialExpiredModal: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 80, height: 80)
                        Image(systemName: "timer")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                    }
                    Text("Your free trial has ended")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text("You can still stream up to 30 minutes per day for free, or upgrade for unlimited access.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                VStack(spacing: 12) {
                    Button("See Beam Unlimited") {
                        showTrialExpiredModal = false
                        showPaywall = true
                    }
                    .buttonStyle(BeamPrimaryButtonStyle())

                    Button("Continue with free tier") {
                        showTrialExpiredModal = false
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Logo

    @ViewBuilder
    private var logoSection: some View {
        VStack(spacing: 10) {
            Image("BrandFullIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .shadow(color: Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255).opacity(0.15), radius: 3)

            Text("beam")
                .font(.custom("Plus Jakarta Sans", size: 30))
                .fontWeight(.black)
                .kerning(-1.2)
                .foregroundStyle(Color(red: 240 / 255, green: 240 / 255, blue: 242 / 255))
                .textCase(.lowercase)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        VStack(spacing: 24) {
            if appState.pairedMac == nil {
                // Not paired — show value prop + setup guide
                unpairedSection
            } else if !appState.isPurchased && appState.sessionManager.isInCooldown {
                // Daily free limit reached — show countdown + upgrade CTA
                dailyLimitSection
            } else if appState.isSearchingForMac {
                // Searching
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.orange)
                    Text("Looking for \(appState.pairedMac?.name ?? "your Mac")…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let mac = appState.pairedMac, appState.discoveredHost != nil {
                // Ready to stream
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("\(mac.name) is ready")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                StartBeamButton(appState: appState)

            } else if let mac = appState.pairedMac {
                // Mac not found on network
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(.secondary).frame(width: 8, height: 8)
                        Text("\(mac.name) not found")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Make sure your Mac is on and on the same WiFi")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }

                Button("Search Again") {
                    appState.startBrowsing()
                }
                .buttonStyle(BeamSecondaryButtonStyle())

                // Show the start button grayed out so layout doesn't shift
                StartBeamButton(appState: appState)
                    .disabled(true)
                    .opacity(0.4)
            }
        }
    }

    // MARK: - Unpaired Section

    @ViewBuilder
    private var unpairedSection: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Stream your screen to your phone")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Mirror your computer's display over your local WiFi network")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Expandable setup guide
            DisclosureGroup(isExpanded: $showSetupGuide) {
                VStack(alignment: .leading, spacing: 14) {
                    setupStep(1, "Download Beacon on your Mac", "Free companion app at beamscreen.app")
                    setupStep(2, "Tap \"Pair Your Mac\" below", "Enter the 6-digit code shown in Beacon")
                    setupStep(3, "Tap \"Start Beam\"", "Your Mac's screen appears instantly")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("How to get started")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(BeamDrawerStyle())

            // Mac app download link — matches PairingView style
            VStack(spacing: 8) {
                Text("Need the Mac app?")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    withAnimation(.spring(duration: 0.2)) {
                        UIPasteboard.general.string = "https://beamscreen.app/#download"
                        linkCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.spring(duration: 0.2)) { linkCopied = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: linkCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                        Text(linkCopied ? "Copied!" : "beamscreen.app/#download")
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                    }
                    .foregroundStyle(linkCopied ? .green : .orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background((linkCopied ? Color.green : Color.orange).opacity(0.12))
                    .clipShape(Capsule())
                    .animation(.spring(duration: 0.2), value: linkCopied)
                }
                .buttonStyle(.plain)
            }

            Button("Pair Your Mac") {
                showPairing = true
            }
            .buttonStyle(BeamPrimaryButtonStyle())
        }
    }

    private func setupStep(_ number: Int, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(Color.orange)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Daily Limit Section

    @ViewBuilder
    private var dailyLimitSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.orange.opacity(0.75))
                        .frame(width: 8, height: 8)
                    Text("Daily limit reached")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Available in \(appState.sessionManager.formattedCooldownRemaining)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.85))
                    .id(now)
            }

            Button("Unlock Beam Unlimited") {
                showPaywall = true
            }
            .buttonStyle(BeamPrimaryButtonStyle())
        }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if StoreManager.shared.isPurchased {
                // Subtle "Beam Unlimited" indicator
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.75))
                    Text("Beam Unlimited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if SessionManager.shared.isInTrial || !SessionManager.shared.hasTrialStarted {
                // Trial chip: days remaining + subtle upgrade link
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.75))
                        Text(appState.sessionManager.formattedTrialDaysRemaining)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("Upgrade →")
                            .font(.caption)
                            .foregroundStyle(.orange.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
                .id(now)
            } else {
                // Free tier status
                if SessionManager.shared.isInCooldown {
                    Label("Available in \(appState.sessionManager.formattedCooldownRemaining)", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .id(now)
                } else {
                    Label(SessionManager.shared.formattedFreeTimeRemainingToday, systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .id(now)
                }
            }
            Spacer()
        }
        .padding(.bottom, 24)
    }
}

// MARK: - Start Button

struct StartBeamButton: View {
    let appState: BeamAppState
    @State private var isStarting = false

    var body: some View {
        Button {
            guard !isStarting else { return }
            isStarting = true
            Task {
                await appState.startStream()
                isStarting = false
            }
        } label: {
            HStack(spacing: 10) {
                if isStarting {
                    ProgressView().tint(.black).scaleEffect(0.8)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(isStarting ? "Connecting…" : "Start Beam")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [.orange, Color(red: 1, green: 0.6, blue: 0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: 280)
    }
}

// MARK: - Drawer Disclosure Style

struct BeamDrawerStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack {
                    configuration.label
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: configuration.isExpanded)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            configuration.content
                .padding(16)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(height: configuration.isExpanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(configuration.isExpanded ? 1 : 0)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: configuration.isExpanded)
        }
    }
}

// MARK: - Button Styles

struct BeamPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .padding(.horizontal, 32)
            .background(Color.orange)
            .foregroundStyle(.black)
            .fontWeight(.semibold)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.15), value: configuration.isPressed)
    }
}

struct BeamSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .background(Color.white.opacity(0.08))
            .foregroundStyle(.white)
            .fontWeight(.medium)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.15), value: configuration.isPressed)
    }
}
