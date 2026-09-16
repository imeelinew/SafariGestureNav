import Cocoa
import SafariServices

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = GestureEngine()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()
        setupStatusItem()
        AppLog.info("app launched devices=\(engine.deviceCount) lookup3finger=\(TrackpadLookupSetting.threeFingerLookupEnabled)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "↩↪"
        item.button?.toolTip = "Safari Gesture Nav"
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let enabled = engine.bridge.gesturesEnabled
        let toggle = menu.addItem(
            withTitle: enabled ? "手势导航：开" : "手势导航：关",
            action: #selector(toggleGestures),
            keyEquivalent: ""
        )
        toggle.target = self

        menu.addItem(NSMenuItem.separator())
        addMenuItem(menu, title: "测试后退", action: #selector(testBack))
        addMenuItem(menu, title: "测试前进", action: #selector(testForward))
        menu.addItem(NSMenuItem.separator())
        addMenuItem(menu, title: "打开 Safari 扩展设置…", action: #selector(openSafariSettings))
        if TrackpadLookupSetting.threeFingerLookupEnabled {
            let warning = menu.addItem(
                withTitle: "系统三指轻点仍是「查询」",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
        }
        menu.addItem(NSMenuItem.separator())
        addMenuItem(menu, title: "退出", action: #selector(quit))
        statusItem?.menu = menu
    }

    private func addMenuItem(_ menu: NSMenu, title: String, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    @objc private func toggleGestures() {
        engine.bridge.gesturesEnabled.toggle()
        rebuildMenu()
    }

    @objc private func testBack() {
        engine.test(.back)
    }

    @objc private func testForward() {
        engine.test(.forward)
    }

    @objc private func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: SafariBridge.extensionIdentifier) { error in
            if let error {
                AppLog.error("open Safari settings failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
