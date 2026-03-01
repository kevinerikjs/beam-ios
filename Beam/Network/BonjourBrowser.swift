// BonjourBrowser.swift
// Discovers Beacon services on the local network via Bonjour.

import Network
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "Bonjour")

final class BonjourBrowser {

    private var browser: NWBrowser?
    private var onHostFound: ((DiscoveredHost) -> Void)?

    // MARK: - Browsing

    func startBrowsing(onHostFound: @escaping (DiscoveredHost) -> Void) {
        self.onHostFound = onHostFound

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
                case .removed:
                    break
                default:
                    break
                }
            }
        }

        browser?.start(queue: .global(qos: .userInitiated))
        logger.info("Bonjour browser started for _beam._tcp")
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        onHostFound = nil
        logger.info("Bonjour browser stopped")
    }

    // MARK: - Result Handling

    private func handleDiscoveredResult(_ result: NWBrowser.Result) {
        guard case .service(let serviceName, _, _, _) = result.endpoint else { return }

        // Resolve the endpoint to get host + port
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let innerEndpoint = connection.currentPath?.remoteEndpoint,
                      case .hostPort(_, let port) = innerEndpoint else {
                    connection.cancel()
                    return
                }
                let discoveredHost = DiscoveredHost(
                    name: serviceName,
                    endpoint: result.endpoint,
                    port: port.rawValue
                )
                logger.info("Discovered Beacon: \(serviceName) on port \(port.rawValue)")
                self?.onHostFound?(discoveredHost)
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
