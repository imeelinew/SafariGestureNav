import ApplicationServices
import AppKit

final class NavigationHUD {
    private let panel: NSPanel
    private let arrow = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?
    private var presentationID = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 90, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 90))
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.font = .systemFont(ofSize: 68, weight: .medium)
        arrow.textColor = NSColor.white.withAlphaComponent(0.7)
        arrow.alignment = .center
        arrow.shadow = NSShadow()
        arrow.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.55)
        arrow.shadow?.shadowBlurRadius = 7
        arrow.shadow?.shadowOffset = NSSize(width: 0, height: -1)
        content.addSubview(arrow)
        NSLayoutConstraint.activate([
            arrow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        panel.contentView = content
        panel.setAccessibilityElement(false)
    }

    func show(_ action: NavigationAction, duration: TimeInterval = 0.35) {
        precondition(Thread.isMainThread)
        presentationID += 1
        let currentID = presentationID
        hideWorkItem?.cancel()
        arrow.stringValue = action == .back ? "←" : "→"
        positionPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 1
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.presentationID == currentID else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                guard self.presentationID == currentID else { return }
                self.panel.orderOut(nil)
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    private func positionPanel() {
        let target = safariWindowFrame() ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: target.midX - panel.frame.width / 2,
            y: target.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func safariWindowFrame() -> NSRect? {
        guard
            let safari = NSRunningApplication.runningApplications(
                withBundleIdentifier: SafariBridge.safariBundleIdentifier
            ).first,
            let primaryScreen = NSScreen.screens.first
        else {
            return nil
        }

        let application = AXUIElementCreateApplication(safari.processIdentifier)
        var windowValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                application,
                kAXFocusedWindowAttribute as CFString,
                &windowValue
            ) == .success,
            let windowValue
        else {
            return nil
        }
        let window = windowValue as! AXUIElement

        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue,
            let sizeValue
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return NSRect(
            x: position.x,
            y: primaryScreen.frame.maxY - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}
