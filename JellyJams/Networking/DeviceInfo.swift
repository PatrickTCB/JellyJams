import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Identifies this client instance to the Jellyfin server. The `deviceId` is
/// generated once and persisted so the server recognises the same device
/// across launches.
struct DeviceInfo: Sendable, Hashable {
    var clientName: String
    var version: String
    var deviceName: String
    var deviceId: String

    static let deviceIdDefaultsKey = "jellyjams.deviceId"

    @MainActor
    static func current() -> DeviceInfo {
        let defaults = UserDefaults.standard
        let deviceId: String
        if let existing = defaults.string(forKey: deviceIdDefaultsKey), !existing.isEmpty {
            deviceId = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: deviceIdDefaultsKey)
            deviceId = generated
        }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
        return DeviceInfo(
            clientName: "JellyJams",
            version: version,
            deviceName: Self.currentDeviceName(),
            deviceId: deviceId
        )
    }

    @MainActor
    private static func currentDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

}
