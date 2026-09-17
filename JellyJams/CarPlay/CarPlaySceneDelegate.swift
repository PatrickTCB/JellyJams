#if os(iOS)
import CarPlay
import UIKit

/// Connects the CarPlay scene to ``CarPlayController``, which builds and owns
/// the template hierarchy.
///
/// Deliberately thin: UIKit instantiates this object from the scene manifest in
/// `Info.plist`, and everything else lives in ``CarPlayController`` so the
/// templates can share the app's service objects.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlayController.shared.connect(interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CarPlayController.shared.disconnect(interfaceController)
    }
}
#endif
