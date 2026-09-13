import UIKit

@MainActor
final class PomoGemAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let scene = window?.windowScene else { return .portrait }
        return TimerSceneOrientation.shared.supportedOrientations(for: scene)
    }
}

/// Scope the orientation override to the presenting scene and timer instance.
/// Inactive scenes retain it so Control Center uses the same system geometry.
@MainActor
final class TimerSceneOrientation {
    static let shared = TimerSceneOrientation()

    private struct Request {
        weak var owner: TimerOrientationController?
        let mask: UIInterfaceOrientationMask
    }

    private var requests: [String: Request] = [:]

    func supportedOrientations(for scene: UIWindowScene) -> UIInterfaceOrientationMask {
        guard let request = requests[scene.session.persistentIdentifier], request.owner != nil else {
            return .portrait
        }
        return request.mask
    }

    func isOwner(_ owner: TimerOrientationController, of scene: UIWindowScene) -> Bool {
        requests[scene.session.persistentIdentifier]?.owner === owner
    }

    func claim(_ scene: UIWindowScene, owner: TimerOrientationController, mask: UIInterfaceOrientationMask) {
        requests[scene.session.persistentIdentifier] = Request(owner: owner, mask: mask)
        invalidateControllers(in: scene)
    }

    func release(_ scene: UIWindowScene, owner: TimerOrientationController) {
        guard isOwner(owner, of: scene) else { return }
        requests.removeValue(forKey: scene.session.persistentIdentifier)
        // Let SwiftUI finish removing the full-screen timer. A replacement
        // timer may claim the scene before this restoration reaches UIKit.
        DispatchQueue.main.async { [weak self, weak scene] in
            guard let self, let scene,
                  self.requests[scene.session.persistentIdentifier] == nil else { return }
            self.invalidateControllers(in: scene)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }

    private func invalidateControllers(in scene: UIWindowScene) {
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
    }
}
