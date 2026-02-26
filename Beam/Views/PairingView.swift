// PairingView.swift
// First-time pairing flow: QR scanner + manual 6-digit code entry.

import SwiftUI
import AVFoundation

struct PairingView: View {
    @Environment(BeamAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showQRScanner = true
    @State private var manualCode = ""
    @State private var cameraPermissionDenied = false

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
                        scannerView
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
        .onChange(of: pairingManager.isPairSuccess) { _, success in
            if success {
                appState.pairedMac = KeyStore.shared.loadPairedMac()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Views

    @ViewBuilder
    private var scannerView: some View {
        VStack(spacing: 24) {
            if showQRScanner {
                // QR Scanner
                VStack(spacing: 16) {
                    Text("Scan the QR code shown on your Mac")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)

                    if cameraPermissionDenied {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Camera access required to scan QR code")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(BeamSecondaryButtonStyle())
                        }
                        .padding(.top, 40)
                    } else {
                        QRScannerView { scannedString in
                            handleQRCode(scannedString)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 24)
                        .onAppear { checkCameraPermission() }
                    }
                }
            }

            Divider().background(.secondary.opacity(0.3))

            // Manual code entry toggle
            VStack(spacing: 16) {
                Text("Or enter the code manually")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("6-digit code", text: $manualCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .onChange(of: manualCode) { _, val in
                            if val.count > 6 { manualCode = String(val.prefix(6)) }
                        }

                    Button("Connect") {
                        if manualCode.count == 6 {
                            handleManualCode()
                        }
                    }
                    .buttonStyle(BeamPrimaryButtonStyle())
                    .disabled(manualCode.count != 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
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
    private var connectingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .tint(.orange)
                .scaleEffect(1.5)
            Text("Connecting to Mac…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
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

    // MARK: - Helpers

    private func handleQRCode(_ string: String) {
        // Parse: beamlink://pair?id=<deviceID>&code=<code>
        guard let url = URL(string: string),
              url.scheme == "beamlink",
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "id" })?.value != nil,
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return
        }

        if let host = appState.discoveredHost {
            pairingManager.startPairing(with: host)
        }
        manualCode = code
        pairingManager.submitCode(code)
    }

    private func handleManualCode() {
        guard let host = appState.discoveredHost else {
            // Need to find the Mac first
            if appState.pairedMac == nil {
                // Searching...
                appState.startBrowsing()
            }
            return
        }
        pairingManager.startPairing(with: host)
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            cameraPermissionDenied = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    cameraPermissionDenied = !granted
                }
            }
        default:
            break
        }
    }
}
