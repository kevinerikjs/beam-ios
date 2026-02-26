// ControlChannel.swift
// Convenience wrapper for sending control commands to the macOS host.
// Delegates to ConnectionManager for actual transmission.

import Foundation

/// Thin wrapper used from UI views to send media commands.
struct ControlChannel {
    weak var connectionManager: ConnectionManager?

    func sendMediaKey(_ key: BeamMediaKeyPayload.Key) {
        connectionManager?.sendMediaKey(key)
    }
}
