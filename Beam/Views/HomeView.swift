// HomeView.swift
// Main screen shown when not streaming. Displays connection status and "Start Beam" button.

import SwiftUI

struct HomeView: View {
    @Environment(BeamAppState.self) private var appState
    @State private var showPairing = false

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
        .onAppear {
            if appState.pairedMac != nil {
                appState.startBrowsing()
            }
        }
    }

    // MARK: - Logo

    @ViewBuilder
    private var logoSection: some View {
        VStack(spacing: 16) {
            // Beam icon - radiating arcs
            ZStack {
                ForEach([0, 1, 2], id: \.self) { i in
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.orange, .yellow.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: CGFloat(60 + i * 28), height: CGFloat(60 + i * 28))
                        .opacity(1.0 - Double(i) * 0.25)
                }
                Image(systemName: "dot.radiowaves.right")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .yellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 116, height: 116)

            Text("Beam")
                .font(.system(size: 36, weight: .bold, design: .default))
                .foregroundStyle(.white)
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

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if !StoreManager.shared.isPurchased {
                // Free tier status
                if SessionManager.shared.isInCooldown {
                    Label("Available in \(SessionManager.shared.formattedCooldownRemaining)", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("10 min free session", systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Settings gear (placeholder - opens sheet in v2)
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
