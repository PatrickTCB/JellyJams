import Foundation
import Network
import Observation

/// Reports changes to the device's connectivity: whether any network
/// interface is up. The monitor fires immediately with the current path
/// when the process starts, then on every path change. Whether the *server*
/// is reachable is a separate question, answered by pinging it.
@MainActor
@Observable
final class NetworkStatus {
    private(set) var isOnline = true
    /// How many path updates the monitor has delivered. A change of network
    /// that leaves ``isOnline`` as it was — home Wi-Fi to cellular — still
    /// counts here, which is what lets it be noticed at all: assigning a
    /// property the value it already holds tells its observers nothing.
    private(set) var pathUpdateCount = 0

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = isOnline
                self?.pathUpdateCount += 1
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.aseriesoftubes.JellyJams.connectivity"))
    }
}
