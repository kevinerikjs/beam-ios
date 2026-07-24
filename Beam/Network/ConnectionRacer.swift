// ConnectionRacer.swift
// Races several candidate endpoints and returns whichever completes a TCP handshake first.
//
// Why (BEAM-26): when a stream drops we do not reliably know WHICH route will come back.
// On a WiFi-to-cellular switch the LAN endpoint is dead and the Tailscale one works; walking
// back through the front door it is the reverse; and during a Tailscale path upgrade either
// might win. Trying them one at a time means the wrong first guess costs a full timeout
// before the right one is even attempted, which is what made handovers feel broken.
//
// This is the Happy Eyeballs idea (RFC 8305) applied to our two routes.
//
// Safe to do here specifically because an unauthenticated connection to Beacon costs nothing:
// every media send on the host is behind `guard isAuthenticated` (StreamSession.swift:389,
// 394, 448), so a losing racer receives no video and no audio. And the host already drops a
// stale duplicate session for the same device on auth (StreamServer.sessionAuthenticated), so
// even a late loser cannot strand a second session.
//
// Only the TCP handshake is raced. The winner is then handed to ConnectionManager which
// authenticates normally. That costs one extra round trip versus adopting the raced socket,
// and in exchange the connection lifecycle stays in exactly one place — which matters, because
// this is the code path where split ownership has already produced two lifecycle bugs.

import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "ConnectionRacer")

enum ConnectionRacer {

    /// How long to wait for any candidate before giving up on the whole race.
    private static let raceTimeout: TimeInterval = 6

    /// Returns the first candidate to complete a TCP handshake, or nil if none did in time.
    /// Cancels every probe before returning, winner included.
    static func firstReachable(among candidates: [DiscoveredHost]) async -> DiscoveredHost? {
        guard candidates.count > 1 else { return candidates.first }

        let names = candidates.map(\.name).joined(separator: ", ")
        DiagnosticLogger.shared.log("Racing \(candidates.count) routes: \(names)", category: "Connection")

        return await withTaskGroup(of: DiscoveredHost?.self) { group in
            for candidate in candidates {
                group.addTask { await probe(candidate) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(raceTimeout * 1_000_000_000))
                return nil
            }

            for await result in group {
                if let winner = result {
                    group.cancelAll()
                    DiagnosticLogger.shared.log(
                        "Route race won by \(describe(winner))",
                        category: "Connection"
                    )
                    return winner
                }
            }
            DiagnosticLogger.shared.log("No route answered within \(Int(raceTimeout))s", category: "Connection")
            return nil
        }
    }

    /// Opens a throwaway TCP connection purely to see whether the endpoint answers.
    private static func probe(_ host: DiscoveredHost) async -> DiscoveredHost? {
        let connection = NWConnection(to: host.endpoint, using: .tcp)
        defer { connection.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DiscoveredHost?, Never>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                func finish(_ value: DiscoveredHost?) {
                    let already = resumed.withLock { done -> Bool in
                        if done { return true }
                        done = true
                        return false
                    }
                    guard !already else { return }
                    continuation.resume(returning: value)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(host)
                    case .failed, .cancelled:
                        finish(nil)
                    case .waiting:
                        // No route via this candidate's interface. Never resolves on its own,
                        // so let the race timeout decide rather than waiting forever.
                        break
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func describe(_ host: DiscoveredHost) -> String {
        if case .hostPort(let h, let p) = host.endpoint { return "\(h):\(p)" }
        return host.name
    }
}
