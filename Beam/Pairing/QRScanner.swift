// QRScanner.swift
// Camera-based QR code scanner using AVFoundation.

import AVFoundation
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "QRScanner")

// MARK: - QRScannerView

struct QRScannerView: UIViewRepresentable {
    let onScanned: (String) -> Void

    func makeUIView(context: Context) -> QRCameraView {
        let view = QRCameraView()
        view.onQRCodeScanned = onScanned
        return view
    }

    func updateUIView(_ uiView: QRCameraView, context: Context) {}
}

// MARK: - QRCameraView

final class QRCameraView: UIView, AVCaptureMetadataOutputObjectsDelegate {

    var onQRCodeScanned: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            setupCamera()
        } else {
            captureSession?.stopRunning()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    // MARK: - Setup

    private func setupCamera() {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else {
            logger.warning("Camera access denied")
            return
        }

        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            logger.error("Failed to set up camera input")
            return
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer.addSublayer(previewLayer)

        self.previewLayer = previewLayer
        self.captureSession = session

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    // MARK: - Delegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let qrObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = qrObject.stringValue else { return }

        captureSession?.stopRunning()
        onQRCodeScanned?(value)
        logger.info("QR code scanned: \(value)")
    }
}
