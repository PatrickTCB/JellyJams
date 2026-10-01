import Foundation
import Network

/// Reports changes to the active network path (Wi-Fi, cellular, offline).
/// Fires immediately with the current path when the process starts, then on
/// every interface change.
@MainActor
final class NetworkStatus: ObservableObject {
    @Published private(set) var isOnCellular = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isCellular = path.usesInterfaceType(.cellular)
            Task { @MainActor in
                self?.isOnCellular = isCellular
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.aseriesoftubes.JellyJams.connectivity"))
    }
}
