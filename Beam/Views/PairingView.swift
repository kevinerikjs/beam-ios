// PairingView.swift
// First-time pairing flow: QR scanner + manual 6-digit code entry.
//
// Flow:
//  1. PairingView appears → auto-connects to discovered Mac, sends "hello"
//  2. Mac generates 6-digit code, shows it (+ QR) in its pairing window
//  3. iPhone receives "challenge" → shows code-entry screen
//  4a. User types the code shown on Mac  — OR —
//  4b. User scans the QR from the Mac screen (auto-submits the code)
//  5. Mac verifies → sends shared secret → paired ✅

import SwiftUI
import AVFoundation

struct PairingView: View {
    @Environment(BeamAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showQRScanner = false
    @State private var manualCode = ""
    @State private var cameraPermissionDenied = false

    /// Code parsed from a QR scan, held until the challenge arrives.
    @State private var pendingQRCode: String? = nil

    @State private var pairingManager = PairingManager.shared

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
        .onChange(of: pairingManager.isAwaitingCodeEntry) { _, awaiting in
            // If the user already scanned a QR, auto-submit the code now that
            // the challenge has arrived and the connection is ready.
            if awaiting, let code = pendingQRCode {
                pendingQRCode = nil
                pairingManager.submitCode(code)
            }
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

                // QR scan as an alternative
                Button("Scan QR instead") {
                    showQRScanner = true
                }
                .buttonStyle(BeamSecondaryButtonStyle())
            }

            if let error = pairingManager.pairingError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet { scannedString in
                showQRScanner = false
                handleQRCode(scannedString)
            }
        }
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

    // MARK: - QR Handling

    private func handleQRCode(_ string: String) {
        guard let url = URL(string: string),
              url.scheme == "beamlink",
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return
        }

        if pairingManager.isAwaitingCodeEntry {
            // Already connected and waiting — submit immediately
            pairingManager.submitCode(code)
        } else {
            // Store it; will be submitted once the challenge arrives
            pendingQRCode = code
            if !pairingManager.isPairing, let host = appState.discoveredHost {
                pairingManager.startPairing(with: host)
            }
        }
    }

    private func checkCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { completion($0) }
        @unknown default:
            completion(false)
        }
    }
}

// MARK: - QR Scanner Sheet

struct QRScannerSheet: View {
    let onScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if permissionDenied {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Camera access required").foregroundStyle(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } else {
                    QRScannerView(onScanned: onScanned)
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { permissionDenied = !granted }
            }
        }
    }
}
