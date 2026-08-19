#if os(iOS)
import UIKit
import SwiftUI

/// アプリの画面向きを制御する。
/// 見開きは横長なので、端末を縦に持っていても UI ごと横向きに固定できるようにする。
final class TottaAppDelegate: NSObject, UIApplicationDelegate {
    /// 現在許可している向き。`application(_:supportedInterfaceOrientationsFor:)` から参照される
    static var supportedOrientations: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

enum OrientationLock {
    /// 横向きに固定する / 解除する
    @MainActor
    static func setLandscapeLocked(_ locked: Bool) {
        let mask: UIInterfaceOrientationMask = locked ? .landscape : .all
        guard TottaAppDelegate.supportedOrientations != mask else { return }
        TottaAppDelegate.supportedOrientations = mask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
                // 対応できない構成(iPad のマルチタスクなど)では無視される
            }
            windowScene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
#endif
