// BonjourBrowser.swift
// Discovers Beacon services on the local network via Bonjour.

import Network
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "Bonjour")

final class BonjourBrowser {

    private var browser: NWBrowser?
    private var onHostFound: ((DiscoveredHost) -> Void)?
    private var onHostsChanged: (([DiscoveredHost]) -> Void)?

    // Tracks all currently visible hosts by service name
    private var discoveredHosts: [String: DiscoveredHost] = [:]

    // MARK: - Browsing

    /// Single-host callback — used by the streaming auto-connect path.
    func startBrowsing(onHostFound: @escaping (DiscoveredHost) -> Void) {
        self.onHostFound = onHostFound
        self.onHostsChanged = nil
        startBrowser()
    }

    /// Multi-host callback — used by the pairing picker.
    func startBrowsing(onHostsChanged: @escaping ([DiscoveredHost]) -> Void) {
        self.onHostsChanged = onHostsChanged
        self.onHostFound = nil
        discoveredHosts = [:]
        startBrowser()
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        onHostFound = nil
        onHostsChanged = nil
        discoveredHosts = [:]
        logger.info("Bonjour browser stopped")
    }

    // MARK: - Private

    private func startBrowser() {
        browser?.cancel()

        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: "_beam._tcp", domain: "local."), using: params)

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("Bonjour browser ready")
            case .failed(let error):
                logger.error("Bonjour browser failed: \(error)")
            default:
                break
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    self?.handleDiscoveredResult(result)
                case .removed(let result):
                    if case .service(let name, _, _, _) = result.endpoint {
                        self?.discoveredHosts.removeValue(forKey: name)
                        let hosts = Array(self?.discoveredHosts.values ?? [:].values)
                        Task { @MainActor in self?.onHostsChanged?(hosts) }
                    }
                default:
                    break
                }
            }
        }

        browser?.start(queue: .global(qos: .userInitiated))
        logger.info("Bonjour browser started for _beam._tcp")
    }

    // MARK: - Result Handling

    private func handleDiscoveredResult(_ result: NWBrowser.Result) {
        guard case .service(let serviceName, _, _, _) = result.endpoint else { return }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let innerEndpoint = connection.currentPath?.remoteEndpoint,
                      case .hostPort(_, let port) = innerEndpoint else {
                    connection.cancel()
                    return
                }
                let host = DiscoveredHost(name: serviceName, endpoint: result.endpoint, port: port.rawValue)
                logger.info("Discovered Beacon: \(serviceName) on port \(port.rawValue)")
                self?.discoveredHosts[serviceName] = host
                let allHosts = Array(self?.discoveredHosts.values ?? [:].values)
                Task { @MainActor in
                    self?.onHostFound?(host)
                    self?.onHostsChanged?(allHosts)
                }
                connection.cancel()
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
}
