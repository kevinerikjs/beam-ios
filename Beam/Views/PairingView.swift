// PairingView.swift
// Pairing flow: discover nearby Macs, user picks one, then enter 6-digit code.
//
// Flow:
//  1. PairingView appears → browses for all Beacon instances on the network
//  2. User sees a list and taps the Mac they want to pair with
//  3. Mac generates a 6-digit code, shows it in its pairing window
//  4. iPhone receives "challenge" → shows code-entry screen
//  5. User types the code shown on Mac
//  6. Mac verifies → sends shared secret → paired ✅

import SwiftUI

struct PairingView: View {
    @EnvironmentObject var appState: BeamAppState
    @Environment(\.dismiss) private var dismiss

    @State private var manualCode = ""
    @ObservedObject private var pairingManager = PairingManager.shared
    @State private var didCopyDownloadLink = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    if pairingManager.isPairSuccess {
                        successView
                    } else if pairingManager.isAwaitingCodeEntry {
                        codeEntryView
                    } else if pairingManager.isPairing {
                        connectingView
                    } else {
                        deviceListView
                    }
                }
            }
            .navigationTitle("Pair Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pairingManager.cancelPairing()
                        appState.stopBrowsing()
                        dismiss()
                    }
                    .foregroundStyle(.orange)
                }
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            appState.startBrowsingForPairing()
        }
        .onDisappear {
            if !pairingManager.isPairSuccess {
                appState.stopBrowsing()
            }
        }
        .onChange(of: pairingManager.isPairSuccess) { success in
            if success {
                appState.pairedMac = KeyStore.shared.loadPairedMac()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Device List

    @ViewBuilder
    private var deviceListView: some View {
        VStack(spacing: 0) {
            Spacer()

            if appState.discoveredHosts.isEmpty {
                // Searching state
                VStack(spacing: 20) {
                    ProgressView()
                        .tint(.orange)
                        .scaleEffect(1.5)
                    Text("Looking for Macs running Beacon…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Make sure both devices are on the same Wi-Fi network.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                // Device picker
                VStack(spacing: 16) {
                    Text("Select your Mac")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("Tap the Mac you want to pair with.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 10) {
                        ForEach(appState.discoveredHosts, id: \.name) { host in
                            Button {
                                pairingManager.startPairing(with: host)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.orange)
                                        .frame(width: 32)
                                    Text(host.name)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 16)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            Spacer()

            // Mac app download link
            VStack(spacing: 8) {
                Text("Need the Mac app?")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    withAnimation(.spring(duration: 0.2)) {
                        UIPasteboard.general.string = "https://beamscreen.app/#download"
                        didCopyDownloadLink = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.spring(duration: 0.2)) { didCopyDownloadLink = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: didCopyDownloadLink ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                        Text(didCopyDownloadLink ? "Copied!" : "beamscreen.app/#download")
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                    }
                    .foregroundStyle(didCopyDownloadLink ? .green : .orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background((didCopyDownloadLink ? Color.green : Color.orange).opacity(0.12))
                    .clipShape(Capsule())
                    .animation(.spring(duration: 0.2), value: didCopyDownloadLink)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Connecting

    @ViewBuilder
    private var connectingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .tint(.orange)
                .scaleEffect(1.5)
            Text("Connecting to Mac…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Check the Beam pairing window on your Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - Code Entry

    @ViewBuilder
    private var codeEntryView: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "keyboard")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Enter the code from your Mac")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Look for the 6-digit code displayed in the Beam pairing window on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 16) {
                TextField("6-digit code", text: $manualCode)
                    .keyboardType(.numberPad)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .frame(height: 60)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 48)
                    .onChange(of: manualCode) { val in
                        if val.count > 6 { manualCode = String(val.prefix(6)) }
                    }

                Button("Verify Code") {
                    pairingManager.submitCode(manualCode)
                }
                .buttonStyle(BeamPrimaryButtonStyle())
                .disabled(manualCode.count != 6)
            }

            if let error = pairingManager.pairingError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Success

    @ViewBuilder
    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Paired Successfully!")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Beam is ready to use.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
