// RemoteSetupProbe.swift
// One-tap remote-access setup for Macs paired before BEAM-19 existed.
//
// Normally the phone learns the Mac's Tailscale address for free: Beacon reports it on
// pairSuccess and on every authSuccess, so simply streaming once over the LAN sets it up.
// That leaves one awkward group — people who paired long ago and don't happen to start a
// stream — staring at a "type your Mac's IP address" box, which is exactly the kind of
// setup step this feature was designed to avoid.
//
// This probe closes that gap. It performs the smallest possible exchange that yields the
// address: connect over the LAN, authenticate, read the host's reply, save the addresses it
// advertises, disconnect. No stream is started and no session is consumed.

import Foundation
import Network
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "RemoteSetup")

enum RemoteSetupProbe {

    enum Failure: LocalizedError {
        case macNotOnNetwork
        case timedOut
        case rejected(String)
        case hostHasNoTailscale

        var errorDescription: String? {
            switch self {
            case .macNotOnNetwork:
                return "Your Mac wasn't found on this network. Connect to the same WiFi as your Mac and try again."
            case .timedOut:
                return "Your Mac didn't respond in time. Make sure Beacon is running and try again."
            case .rejected(let reason):
                return reason
            case .hostHasNoTailscale:
                return "Your Mac isn't on a Tailscale network yet. Install Tailscale on your Mac, sign in, then try again."
            }
        }
    }

    private static let timeout: TimeInterval = 8

    /// Connects to `host`, authenticates, and returns the remote addresses it advertises.
    /// Throws `hostHasNoTailscale` when the Mac answers but has no tailnet address, which is a
    /// genuinely different problem from a failed connection and deserves its own message.
    static func fetchRemoteHosts(from host: DiscoveredHost, pairedMac: PairedMac) async throws -> [String] {
        let connection = NWConnection(to: host.endpoint, using: .tcp)

        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                try await run(connection: connection, pairedMac: pairedMac)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.timedOut
            }
            guard let result = try await group.next() else { throw Failure.timedOut }
            group.cancelAll()
            connection.cancel()
            return result
        }
    }

    // MARK: - Exchange

    private static func run(connection: NWConnection, pairedMac: PairedMac) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            /// The continuation must be resumed exactly once; NWConnection can deliver a
            /// failure state and a receive error for the same underlying problem.
            func finish(_ result: Result<[String], Error>) {
                let alreadyDone = finished.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                guard !alreadyDone else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    sendAuth(on: connection, pairedMac: pairedMac)
                    receiveHeader(on: connection, finish: finish)
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(Failure.timedOut))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func sendAuth(on connection: NWConnection, pairedMac: PairedMac) {
        let secretHex = pairedMac.sharedSecret.map { String(format: "%02x", $0) }.joined()
        let auth = BeamPairingMessage(
            type: .authRequest,
            deviceName: UIDevice.current.name,
            deviceID: KeyStore.shared.stableDeviceID,
            code: nil,
            sharedSecret: secretHex,
            error: nil
        )
        guard let data = try? JSONEncoder().encode(auth) else { return }
        connection.send(content: data.lengthPrefixed(), completion: .idempotent)
    }

    /// Host replies are BeamPacketHeader-framed: 10-byte header, then payload.
    private static func receiveHeader(
        on connection: NWConnection,
        finish: @escaping (Result<[String], Error>) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: BeamPacketHeader.size,
            maximumLength: BeamPacketHeader.size
        ) { data, _, _, error in
            if let error { return finish(.failure(error)) }
            guard let data, let header = BeamPacketHeader.parse(from: data) else {
                return finish(.failure(Failure.timedOut))
            }
            receivePayload(on: connection, header: header, finish: finish)
        }
    }

    private static func receivePayload(
        on connection: NWConnection,
        header: BeamPacketHeader,
        finish: @escaping (Result<[String], Error>) -> Void
    ) {
        let length = Int(header.payloadLength)
        guard length > 0, length < 1_000_000 else { return finish(.failure(Failure.timedOut)) }

        connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
            if let error { return finish(.failure(error)) }
            guard let data else { return finish(.failure(Failure.timedOut)) }

            guard header.type == .control,
                  let message = try? JSONDecoder().decode(BeamPairingMessage.self, from: data) else {
                // Some other packet type arrived first; keep waiting for the auth reply.
                return receiveHeader(on: connection, finish: finish)
            }

            switch message.type {
            case .authSuccess:
                let hosts = message.tailscaleHosts ?? []
                logger.info("Remote setup probe got \(hosts.count) address(es)")
                finish(hosts.isEmpty ? .failure(Failure.hostHasNoTailscale) : .success(hosts))
            case .authFailed:
                finish(.failure(Failure.rejected(message.error ?? "Your Mac rejected the connection.")))
            case .unpaired:
                finish(.failure(Failure.rejected("This iPhone is no longer paired with your Mac.")))
            default:
                receiveHeader(on: connection, finish: finish)
            }
        }
    }
}
