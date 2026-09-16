import ApplicationServices
import AppKit
import Foundation
import SafariServices

final class SafariBridge {
    static let extensionIdentifier = "dev.eli.safari.gesturenav.Extension"
    static let safariBundleIdentifier = "com.apple.Safari"

    private let defaults = UserDefaults.standard
    private let nativeOnlyKey = "nativeNavigationOnly"

    var gesturesEnabled = true
    private(set) var lastMessage: String = "idle"

    var prefersNativeNavigation: Bool {
        get { defaults.object(forKey: nativeOnlyKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: nativeOnlyKey) }
    }

    func isSafariFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.safariBundleIdentifier
    }

    func send(action: NavigationAction, id: String, timestamp: TimeInterval = Date().timeIntervalSince1970 * 1000, activateSafari: Bool = false) {
        guard gesturesEnabled || activateSafari else {
            lastMessage = "disabled"
            return
        }

        if activateSafari {
            activateSafariApp()
        }

        guard isSafariFrontmost() || activateSafari else {
            lastMessage = "safari-not-frontmost"
            AppLog.info("discard \(action.rawValue): Safari is not frontmost")
            return
        }

        let useNative = prefersNativeNavigation || activateSafari
        let payload: [String: Any] = [
            "id": id,
            "action": action.rawValue,
            "timestamp": timestamp,
            "execute": !useNative
        ]

        dispatchToExtension(name: "navigate", userInfo: payload)

        if useNative {
            let nativeOK = NativeSafariNavigator.perform(action)
            lastMessage = nativeOK ? "native-\(action.rawValue)" : "native-failed-\(action.rawValue)"
            AppLog.info("native \(action.rawValue) ok=\(nativeOK) id=\(id)")
        }
    }

    private func dispatchToExtension(name: String, userInfo: [String: Any]) {
        SFSafariApplication.dispatchMessage(
            withName: name,
            toExtensionWithIdentifier: Self.extensionIdentifier,
            userInfo: userInfo
        ) { error in
            if let error {
                AppLog.error("dispatchMessage failed: \(error.localizedDescription)")
            } else {
                AppLog.info("dispatchMessage delivered \(name)")
            }
        }
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
        if javascriptHistory(action) {
            return true
        }
        if clickToolbarButton(for: action) {
            return true
        }
        if clickHistoryMenu(for: action) {
            return true
        }
        return pressShortcut(for: action)
    }

    private static func javascriptHistory(_ action: NavigationAction) -> Bool {
        let js = action == .back ? "history.back()" : "history.forward()"
        let script = """
            tell application "Safari"
              if (count of windows) is 0 then return "no"
              do JavaScript "\(js)" in current tab of front window
              return "ok"
            end tell
            """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            return false
        }
        return result.stringValue == "ok"
    }

    private static func clickToolbarButton(for action: NavigationAction) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        let names = action == .back
            ? ["Back", "后退", "Previous Page", "上一页"]
            : ["Forward", "前进", "Next Page", "下一页"]
        let identifiers = action == .back
            ? ["Back", "BackButton", "back"]
            : ["Forward", "ForwardButton", "forward"]
        var visited = 0
        guard let button = findButton(root: app, names: Set(names), identifiers: identifiers, visited: &visited) else {
            return false
        }
        var error = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if error != .success {
            error = AXUIElementPerformAction(button, "AXPress" as CFString)
        }
        return error == .success
    }

    private static func findButton(root: AXUIElement, names: Set<String>, identifiers: [String], visited: inout Int) -> AXUIElement? {
        if visited > 500 { return nil }
        visited += 1

        let role = stringAttribute(root, kAXRoleAttribute as CFString)
        let title = stringAttribute(root, kAXTitleAttribute as CFString)
        let description = stringAttribute(root, kAXDescriptionAttribute as CFString)
        let help = stringAttribute(root, kAXHelpAttribute as CFString)
        let identifier = stringAttribute(root, "AXIdentifier" as CFString)
        let values = [title, description, help, identifier].compactMap { $0 }

        if role == (kAXButtonRole as String) || role == "AXButton" || role == (kAXCheckBoxRole as String) {
            if values.contains(where: { names.contains($0) }) { return root }
            if let identifier, identifiers.contains(where: { identifier.localizedCaseInsensitiveContains($0) }) {
                return root
            }
        }

        guard let children = children(of: root) else { return nil }
        for child in children {
            if let match = findButton(root: child, names: names, identifiers: identifiers, visited: &visited) {
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
                    click menu item "Back" of menu "History" of menu bar 1
                    return "ok"
                  end try
                  try
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
                    click menu item "Forward" of menu "History" of menu bar 1
                    return "ok"
                  end try
                  try
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

    private static func pressShortcut(for action: NavigationAction) -> Bool {
        let key: CGKeyCode = action == .back ? 0x21 : 0x1E
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
