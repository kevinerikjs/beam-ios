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
import Phoros
import PhorosNetwork
import PhorosSession
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
        let link = PhorosConnection(to: host.endpoint, queue: .global(qos: .userInitiated))

        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                try await run(link: link, pairedMac: pairedMac)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.timedOut
            }
            guard let result = try await group.next() else { throw Failure.timedOut }
            group.cancelAll()
            link.cancel()
            return result
        }
    }

    // MARK: - Exchange

    private static func run(link: PhorosConnection, pairedMac: PairedMac) async throws -> [String] {
        guard let secret = SharedSecret(bytes: pairedMac.sharedSecret) else {
            throw Failure.rejected("The stored pairing is damaged. Pair this iPhone again.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            /// The continuation must be resumed exactly once; the connection can deliver a
            /// failure state and a receive error for the same underlying problem.
            func finish(_ result: Result<[String], Error>) {
                let alreadyDone = finished.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                guard !alreadyDone else { return }
                link.cancel()
                continuation.resume(with: result)
            }

            link.onReady = {
                let auth = ClientCapabilities(
                    deviceName: UIDevice.current.name,
                    deviceID: KeyStore.shared.stableDeviceID
                ).authRequest(secret: secret)
                guard let data = try? JSONEncoder().encode(auth) else { return }
                link.send(data)
            }
            link.onFrame = { frame in
                // The auth reply is a .control packet. Anything else (media, if the host
                // starts streaming before we cancel) is skipped while we wait for it.
                guard case .packet(let packet) = frame, packet.type == .control,
                      let message = try? JSONDecoder().decode(PairingMessage.self, from: packet.payload)
                else { return }
                switch PairingClient.interpret(message) {
                case .authenticated(let host, _, _, _):
                    logger.info("Remote setup probe got \(host.remoteHosts.count) address(es)")
                    finish(host.remoteHosts.isEmpty ? .failure(Failure.hostHasNoTailscale) : .success(host.remoteHosts))
                case .failed(let reason):
                    finish(.failure(Failure.rejected(reason)))
                case .unpaired:
                    finish(.failure(Failure.rejected("This iPhone is no longer paired with your Mac.")))
                case .codeRequested, .paired, .unexpected:
                    break
                }
            }
            link.onEnd = { reason in
                switch reason {
                case .transportFailed(let error): finish(.failure(error))
                case .closedByPeer, .protocolViolation, .cancelled: finish(.failure(Failure.timedOut))
                }
            }
            link.start()
        }
    }
}
