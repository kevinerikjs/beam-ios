// HomeView.swift
// Main screen shown when not streaming. Displays connection status and "Start Beam" button.

import SwiftUI

struct HomeView: View {
    @Environment(BeamAppState.self) private var appState
    @State private var showPairing = false
    @State private var showPaywall = false

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
        }
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
                // Not paired
                VStack(spacing: 12) {
                    Text("No Mac paired")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button("Pair Your Mac") {
                        showPairing = true
                    }
                    .buttonStyle(BeamPrimaryButtonStyle())
                }
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
