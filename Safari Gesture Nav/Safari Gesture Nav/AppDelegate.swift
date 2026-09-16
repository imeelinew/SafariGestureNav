import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = GestureEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine.start()
        AppLog.info("app launched devices=\(engine.deviceCount) lookup3finger=\(TrackpadLookupSetting.threeFingerLookupEnabled)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }
}
