import ApplicationServices
import AppKit
import Foundation
import IOKit.hid

final class GestureEngine {
    let bridge = SafariBridge()
    private let input = GestureInput()
    private let recognizer = TapRecognizer()
    private let navigationHUD = NavigationHUD()

    var isRunning: Bool {
        bridge.gesturesEnabled && input.attachedDeviceCount > 0
    }

    var deviceCount: Int {
        input.attachedDeviceCount
    }

    func start() {
        requestPermissions()
        recognizer.onAction = { [weak self] action, id in
            guard let self else { return }
            DispatchQueue.main.async {
                self.bridge.send(action: action, id: id) { succeeded in
                    guard succeeded else { return }
                    DispatchQueue.main.async {
                        self.navigationHUD.show(action)
                    }
                }
            }
        }

        input.onFrame = { [weak self] frame in
            self?.handle(frame)
        }

        let started = input.start()
        if !started {
            AppLog.error("no trackpad input; gestures will not fire")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if bundle != SafariBridge.safariBundleIdentifier {
                self?.recognizer.reset(reason: "frontmost app changed")
            }
        }

        let failures = TapRecognizer.runSelfTest()
        if failures.isEmpty {
            AppLog.info("TapRecognizer self-test passed")
        } else {
            AppLog.error("TapRecognizer self-test failed: \(failures.joined(separator: "; "))")
        }
    }

    func stop() {
        input.stop()
        recognizer.reset(reason: "engine stop")
    }

    func test(_ action: NavigationAction) {
        bridge.send(action: action, id: UUID().uuidString, activateSafari: true) { succeeded in
            guard succeeded else { return }
            DispatchQueue.main.async {
                self.navigationHUD.show(action)
            }
        }
    }

    private func handle(_ frame: TrackpadFrame) {
        guard bridge.gesturesEnabled else {
            recognizer.reset(reason: "disabled")
            return
        }
        guard bridge.isSafariFrontmost() else {
            recognizer.reset(reason: "safari not frontmost")
            return
        }

        recognizer.handle(frame)
    }

    private func requestPermissions() {
        let accessPrompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(accessPrompt)
        AppLog.info("accessibility trusted=\(trusted)")

        let inputOK = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        AppLog.info("input monitoring granted=\(inputOK)")
    }
}
