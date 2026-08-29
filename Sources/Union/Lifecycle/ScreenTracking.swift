import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
import ObjectiveC

/// Opt-in automatic `$screen_view` via `UIViewController.viewDidAppear` swizzling. Container and system
/// controllers are ignored; SwiftUI apps should prefer the `.trackScreen("Name")` modifier.
enum AutomaticScreenTracking {
    @MainActor private static var installed = false
    private static let ignoredPrefixes = ["UINavigationController", "UITabBarController", "UISplitViewController", "UIPageViewController", "UIInputWindowController", "UIAlertController", "UIHostingController", "_UI", "UICompatibilityInputViewController"]

    @MainActor
    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIViewController.self
        guard let original = class_getInstanceMethod(cls, #selector(UIViewController.viewDidAppear(_:))),
              let swizzled = class_getInstanceMethod(cls, #selector(UIViewController.av_viewDidAppear(_:)))
        else { return }
        method_exchangeImplementations(original, swizzled)
    }

    static func shouldTrack(_ vc: UIViewController) -> Bool {
        let name = NSStringFromClass(type(of: vc))
        return !ignoredPrefixes.contains { name.hasPrefix($0) }
    }

    static func screenName(_ vc: UIViewController) -> String {
        var name = NSStringFromClass(type(of: vc))
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        if name.hasSuffix("ViewController") { name.removeLast("ViewController".count) }
        return String(name.prefix(Limits.screenNameMaxLength))
    }
}

extension UIViewController {
    @objc fileprivate func av_viewDidAppear(_ animated: Bool) {
        av_viewDidAppear(animated) // calls the original implementation (swapped)
        if AutomaticScreenTracking.shouldTrack(self) {
            Union.screen(AutomaticScreenTracking.screenName(self))
        }
    }
}
#endif

#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Emits `$screen_view` when the view appears. The preferred way to track screens in SwiftUI apps.
    func trackScreen(_ name: String, properties: [String: PropertyValue] = [:]) -> some View {
        onAppear { Union.screen(name, properties: properties) }
    }
}
#endif
