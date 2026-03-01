// PairingView.swift
// First-time pairing flow: 6-digit code entry.
//
// Flow:
//  1. PairingView appears → auto-connects to discovered Mac, sends "hello"
//  2. Mac generates 6-digit code, shows it in its pairing window
//  3. iPhone receives "challenge" → shows code-entry screen
//  4. User types the code shown on Mac
//  5. Mac verifies → sends shared secret → paired ✅

import SwiftUI

struct PairingView: View {
    @Environment(BeamAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var manualCode = ""
    @State private var pairingManager = PairingManager.shared
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
                        waitingView
                    }
                }
            }
            .navigationTitle("Pair Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pairingManager.cancelPairing()
                        dismiss()
                    }
                    .foregroundStyle(.orange)
                }
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            autoConnect()
        }
        .onChange(of: pairingManager.isPairSuccess) { _, success in
            if success {
                appState.pairedMac = KeyStore.shared.loadPairedMac()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Auto-connect

    /// Immediately connect to the discovered Mac and send "hello" so it
    /// generates the pairing code and shows it on screen.
    private func autoConnect() {
        guard !pairingManager.isPairing else { return }

        if let host = appState.discoveredHost {
            pairingManager.startPairing(with: host)
        } else {
            // Mac not found yet — start browsing and retry when discovered
            appState.startBrowsing()
        }
    }

    // MARK: - Views

    @ViewBuilder
    private var waitingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .tint(.orange)
                .scaleEffect(1.5)
            Text("Looking for your Mac…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Make sure both devices are on the same Wi-Fi network.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
                        withAnimation(.spring(duration: 0.2)) {
                            didCopyDownloadLink = false
                        }
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
                    .background(
                        (didCopyDownloadLink ? Color.green : Color.orange).opacity(0.12)
                    )
                    .clipShape(Capsule())
                    .animation(.spring(duration: 0.2), value: didCopyDownloadLink)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)
        }
        .onChange(of: appState.discoveredHost) { _, host in
            if let host, !pairingManager.isPairing {
                pairingManager.startPairing(with: host)
            }
        }
    }

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
                    .onChange(of: manualCode) { _, val in
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
