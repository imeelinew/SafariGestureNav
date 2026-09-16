import ApplicationServices
import AppKit
import Foundation
import IOKit.hid

final class GestureEngine {
    let bridge = SafariBridge()
    private let input = GestureInput()
    private let recognizer = TapRecognizer()
    private let suppressor = EventSuppressor()

    var isRunning: Bool {
        bridge.gesturesEnabled && input.attachedDeviceCount > 0
    }

    var deviceCount: Int {
        input.attachedDeviceCount
    }

    func start() {
        requestPermissions()
        suppressor.start()
        suppressor.setPhysicalClickHandler { [weak self] in
            self?.recognizer.notePhysicalClick()
        }

        recognizer.onCandidateChanged = { [weak self] count, active in
            guard let self else { return }
            self.suppressor.updateCandidate(fingerCount: count, active: active, onSurfaceCount: count ?? 0)
        }
        recognizer.onAction = { [weak self] action, id in
            guard let self else { return }
            self.suppressor.swallowAfterTap(action: action)
            DispatchQueue.main.async {
                self.bridge.send(action: action, id: id)
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
        suppressor.stop()
        recognizer.reset(reason: "engine stop")
    }

    func test(_ action: NavigationAction) {
        bridge.send(action: action, id: UUID().uuidString, activateSafari: true)
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

        suppressor.noteFrameAge(0)
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

enum TrackpadLookupSetting {
    static var threeFingerLookupEnabled: Bool {
        let defaults = UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad")
        return defaults?.object(forKey: "TrackpadThreeFingerTapGesture") as? Int == 2
    }
}
