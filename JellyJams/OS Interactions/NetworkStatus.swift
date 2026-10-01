import Foundation
import Network

/// Reports changes to the device's connectivity: whether any network
/// interface is up. The monitor fires immediately with the current path
/// when the process starts, then on every path change. Whether the *server*
/// is reachable is a separate question, answered by pinging it.
@MainActor
final class NetworkStatus: ObservableObject {
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = isOnline
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.aseriesoftubes.JellyJams.connectivity"))
    }
}
