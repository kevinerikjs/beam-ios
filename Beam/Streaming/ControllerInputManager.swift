// ControllerInputManager.swift
// Captures the iPhone-paired game controller (GameController framework) and
// streams its state to the host as binary .input packets while streaming.
// The host replays these into a virtual HID gamepad so Mac games see a real controller.

import Foundation
import Phoros
import GameController
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "ControllerInput")

final class ControllerInputManager {

    /// Called on connect/disconnect of a physical controller (dispatched to main).
    var onConnectionChange: ((Bool) -> Void)?

    private weak var connectionManager: ConnectionManager?
    private var activeController: GCController?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.beam.ios.controller-input", qos: .userInteractive)

    private var lastSent: ControllerReport?
    private var lastSentAt: Date = .distantPast
    private let sendInterval: TimeInterval = 1.0 / 60.0
    private let keepaliveInterval: TimeInterval = 1.0

    // MARK: - Lifecycle

    func start(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                self?.attachIfSuitable(controller)
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let self, let controller = note.object as? GCController,
                      controller === self.activeController else { return }
                self.detach()
            },
        ]

        if let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            attachIfSuitable(controller)
        }
    }

    func stop() {
        stopTimer()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if activeController != nil {
            activeController = nil
            onConnectionChange?(false)
        }
        lastSent = nil
        connectionManager = nil
    }

    // MARK: - Attach / Detach

    private func attachIfSuitable(_ controller: GCController) {
        guard controller.extendedGamepad != nil else {
            logger.info("Ignoring controller without extended gamepad profile: \(controller.vendorName ?? "unknown")")
            return
        }
        guard activeController == nil else { return }
        activeController = controller
        logger.info("Controller attached: \(controller.vendorName ?? "unknown")")
        DiagnosticLogger.shared.log("Controller attached: \(controller.vendorName ?? "unknown")", category: "Controller")
        onConnectionChange?(true)
        lastSent = nil
        startTimer()
    }

    private func detach() {
        logger.info("Controller detached")
        DiagnosticLogger.shared.log("Controller detached", category: "Controller")
        stopTimer()
        activeController = nil
        onConnectionChange?(false)
        // Tell the host to tear down the virtual gamepad.
        connectionManager?.sendControllerState(.neutral, connected: false)
        lastSent = nil
    }

    // MARK: - Sampling

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: sendInterval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let pad = activeController?.extendedGamepad else { return }
        let state = snapshot(pad)
        let now = Date()
        guard state != lastSent || now.timeIntervalSince(lastSentAt) >= keepaliveInterval else { return }
        lastSent = state
        lastSentAt = now
        connectionManager?.sendControllerState(state, connected: true)
    }

    private func snapshot(_ pad: GCExtendedGamepad) -> ControllerReport {
        var buttons: ControllerReport.Buttons = []
        if pad.buttonA.isPressed { buttons.insert(.a) }
        if pad.buttonB.isPressed { buttons.insert(.b) }
        if pad.buttonX.isPressed { buttons.insert(.x) }
        if pad.buttonY.isPressed { buttons.insert(.y) }
        if pad.leftShoulder.isPressed { buttons.insert(.leftShoulder) }
        if pad.rightShoulder.isPressed { buttons.insert(.rightShoulder) }
        if pad.leftThumbstickButton?.isPressed == true { buttons.insert(.leftThumbstick) }
        if pad.rightThumbstickButton?.isPressed == true { buttons.insert(.rightThumbstick) }
        if pad.dpad.up.isPressed { buttons.insert(.dpadUp) }
        if pad.dpad.down.isPressed { buttons.insert(.dpadDown) }
        if pad.dpad.left.isPressed { buttons.insert(.dpadLeft) }
        if pad.dpad.right.isPressed { buttons.insert(.dpadRight) }
        if pad.buttonMenu.isPressed { buttons.insert(.menu) }
        if pad.buttonOptions?.isPressed == true { buttons.insert(.options) }
        if pad.buttonHome?.isPressed == true { buttons.insert(.home) }

        return ControllerReport(
            buttons: buttons,
            leftX: Self.axisValue(pad.leftThumbstick.xAxis.value),
            leftY: Self.axisValue(pad.leftThumbstick.yAxis.value),
            rightX: Self.axisValue(pad.rightThumbstick.xAxis.value),
            rightY: Self.axisValue(pad.rightThumbstick.yAxis.value),
            leftTrigger: Self.triggerValue(pad.leftTrigger.value),
            rightTrigger: Self.triggerValue(pad.rightTrigger.value)
        )
    }

    private static func axisValue(_ value: Float) -> Int16 {
        Int16(clamping: Int(value * 32767))
    }

    private static func triggerValue(_ value: Float) -> UInt8 {
        UInt8(clamping: Int(value * 255))
    }
}
