import ApplicationServices
import AppKit
import Foundation

final class SafariBridge {
    static let safariBundleIdentifier = "com.apple.Safari"

    var gesturesEnabled = true
    private(set) var lastMessage = "idle"

    func isSafariFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.safariBundleIdentifier
    }

    func send(action: NavigationAction, id: String, activateSafari: Bool = false,
              completion: ((Bool) -> Void)? = nil) {
        guard gesturesEnabled || activateSafari else {
            lastMessage = "disabled"
            completion?(false)
            return
        }
        if activateSafari { activateSafariApp() }
        guard isSafariFrontmost() else {
            lastMessage = "safari-not-frontmost"
            completion?(false)
            return
        }

        let navigated = NativeSafariNavigator.perform(action)
        lastMessage = navigated ? "navigated-\(action.rawValue)" : "unavailable-\(action.rawValue)"
        AppLog.info("navigation \(action.rawValue) performed=\(navigated) id=\(id)")
        completion?(navigated)
    }

    private func activateSafariApp() {
        if let safari = NSRunningApplication.runningApplications(withBundleIdentifier: Self.safariBundleIdentifier).first {
            safari.activate()
            Thread.sleep(forTimeInterval: 0.15)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.safariBundleIdentifier) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        Thread.sleep(forTimeInterval: 0.4)
    }
}

enum NativeSafariNavigator {
    static func perform(_ action: NavigationAction) -> Bool {
        // Safari disables these controls when the tab has no entry in that direction.
        // A successful dispatch or history.back() call alone cannot prove navigation.
        clickToolbarButton(for: action) || clickHistoryMenu(for: action)
    }

    private static func clickToolbarButton(for action: NavigationAction) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue else { return false }
        let window = focusedValue as! AXUIElement
        let names = action == .back
            ? ["Back", "后退", "Previous Page", "上一页"]
            : ["Forward", "前进", "Next Page", "下一页"]
        let identifiers = action == .back
            ? ["BackButton"]
            : ["ForwardButton"]
        var visited = 0
        guard let button = findButton(root: window, names: Set(names), identifiers: identifiers, visited: &visited, inToolbar: false) else {
            return false
        }
        var enabledValue: AnyObject?
        guard AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &enabledValue) == .success,
              (enabledValue as? NSNumber)?.boolValue == true else { return false }
        var error = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if error != .success {
            error = AXUIElementPerformAction(button, "AXPress" as CFString)
        }
        return error == .success
    }

    private static func findButton(root: AXUIElement, names: Set<String>, identifiers: [String], visited: inout Int, inToolbar: Bool) -> AXUIElement? {
        if visited > 500 { return nil }
        visited += 1

        let role = stringAttribute(root, kAXRoleAttribute as CFString)
        if role == "AXWebArea" { return nil }
        let isToolbar = inToolbar || role == "AXToolbar"
        let title = stringAttribute(root, kAXTitleAttribute as CFString)
        let description = stringAttribute(root, kAXDescriptionAttribute as CFString)
        let help = stringAttribute(root, kAXHelpAttribute as CFString)
        let identifier = stringAttribute(root, "AXIdentifier" as CFString)
        let values = [title, description, help, identifier].compactMap { $0 }

        if isToolbar && (role == (kAXButtonRole as String) || role == "AXButton" || role == (kAXCheckBoxRole as String)) {
            if values.contains(where: { names.contains($0) }) { return root }
            if let identifier, identifiers.contains(where: { identifier.caseInsensitiveCompare($0) == .orderedSame }) {
                return root
            }
        }

        guard let children = children(of: root) else { return nil }
        for child in children {
            if let match = findButton(root: child, names: names, identifiers: identifiers, visited: &visited, inToolbar: isToolbar) {
                return match
            }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard error == .success, let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private static func clickHistoryMenu(for action: NavigationAction) -> Bool {
        let script = action == .back
            ? #"""
              tell application "System Events"
                tell process "Safari"
                  try
                    if not (enabled of menu item "Back" of menu "History" of menu bar 1) then return "no"
                    click menu item "Back" of menu "History" of menu bar 1
                    return "ok"
                  end try
                  try
                    if not (enabled of menu item "后退" of menu "历史记录" of menu bar 1) then return "no"
                    click menu item "后退" of menu "历史记录" of menu bar 1
                    return "ok"
                  end try
                end tell
              end tell
              return "no"
              """#
            : #"""
              tell application "System Events"
                tell process "Safari"
                  try
                    if not (enabled of menu item "Forward" of menu "History" of menu bar 1) then return "no"
                    click menu item "Forward" of menu "History" of menu bar 1
                    return "ok"
                  end try
                  try
                    if not (enabled of menu item "前进" of menu "历史记录" of menu bar 1) then return "no"
                    click menu item "前进" of menu "历史记录" of menu bar 1
                    return "ok"
                  end try
                end tell
              end tell
              return "no"
              """#
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            return false
        }
        return result.stringValue == "ok"
    }

}
