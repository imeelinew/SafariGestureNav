import CoreGraphics
import Foundation
import QuartzCore

private nonisolated(unsafe) var gSuppressLock = os_unfair_lock()
private nonisolated(unsafe) var gTwoFingerCandidate = false
private nonisolated(unsafe) var gThreeFingerCandidate = false
private nonisolated(unsafe) var gOnSurfaceCount = 0
private nonisolated(unsafe) var gCandidateAge: CFTimeInterval = 0
private nonisolated(unsafe) var gSwallowRightUntil: CFTimeInterval = 0
private nonisolated(unsafe) var gSwallowLookupUntil: CFTimeInterval = 0
private nonisolated(unsafe) var gTap: CFMachPort?
private nonisolated(unsafe) var gTapEnabled = false
private nonisolated(unsafe) var gPhysicalClickHandler: (() -> Void)?

private let quickLookType = CGEventType(rawValue: 33)!
private let gestureType = CGEventType(rawValue: 29)!

private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByUserInput {
        os_unfair_lock_lock(&gSuppressLock)
        gTapEnabled = false
        os_unfair_lock_unlock(&gSuppressLock)
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByTimeout {
        os_unfair_lock_lock(&gSuppressLock)
        let tap = gTap
        let shouldEnable = gTwoFingerCandidate || gThreeFingerCandidate || CACurrentMediaTime() < max(gSwallowRightUntil, gSwallowLookupUntil)
        gTapEnabled = shouldEnable
        os_unfair_lock_unlock(&gSuppressLock)
        if shouldEnable, let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let now = CACurrentMediaTime()
    os_unfair_lock_lock(&gSuppressLock)
    let twoFinger = gTwoFingerCandidate
    let threeFinger = gThreeFingerCandidate
    let onSurface = gOnSurfaceCount
    let age = gCandidateAge
    let swallowRight = now < gSwallowRightUntil
    let swallowLookup = now < gSwallowLookupUntil
    let clickHandler = gPhysicalClickHandler
    os_unfair_lock_unlock(&gSuppressLock)

    if type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged {
        if twoFinger && onSurface >= 2 && age > 0.05 {
            clickHandler?()
            return Unmanaged.passUnretained(event)
        }
        if twoFinger || swallowRight {
            return nil
        }
    }

    if type == quickLookType || type == gestureType {
        if threeFinger || swallowLookup {
            return nil
        }
    }

    return Unmanaged.passUnretained(event)
}

final class EventSuppressor {
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard gTap == nil else { return }
        var mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        mask |= CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
        mask |= CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
        mask |= CGEventMask(1 << quickLookType.rawValue)
        mask |= CGEventMask(1 << gestureType.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            AppLog.error("failed to create event tap; Accessibility permission missing?")
            return
        }

        gTap = tap
        gTapEnabled = true
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLog.info("event tap installed")
    }

    func stop() {
        if let tap = gTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        gTap = nil
        runLoopSource = nil
        gTapEnabled = false
    }

    func setPhysicalClickHandler(_ handler: @escaping () -> Void) {
        os_unfair_lock_lock(&gSuppressLock)
        gPhysicalClickHandler = handler
        os_unfair_lock_unlock(&gSuppressLock)
    }

    func updateCandidate(fingerCount: Int?, active: Bool, onSurfaceCount: Int) {
        os_unfair_lock_lock(&gSuppressLock)
        gOnSurfaceCount = onSurfaceCount
        if let fingerCount, active {
            gTwoFingerCandidate = fingerCount == 2
            gThreeFingerCandidate = fingerCount == 3
            gCandidateAge = 0
        } else {
            gTwoFingerCandidate = false
            gThreeFingerCandidate = false
        }
        os_unfair_lock_unlock(&gSuppressLock)
        enableIfNeeded()
    }

    func noteFrameAge(_ age: TimeInterval) {
        os_unfair_lock_lock(&gSuppressLock)
        gCandidateAge = age
        os_unfair_lock_unlock(&gSuppressLock)
    }

    func swallowAfterTap(action: NavigationAction) {
        let until = CACurrentMediaTime() + 0.32
        os_unfair_lock_lock(&gSuppressLock)
        if action == .back {
            gSwallowRightUntil = until
            gTwoFingerCandidate = false
        } else {
            gSwallowLookupUntil = until
            gThreeFingerCandidate = false
        }
        os_unfair_lock_unlock(&gSuppressLock)
        enableIfNeeded()
    }

    private func enableIfNeeded() {
        os_unfair_lock_lock(&gSuppressLock)
        let needed = gTwoFingerCandidate || gThreeFingerCandidate || CACurrentMediaTime() < max(gSwallowRightUntil, gSwallowLookupUntil)
        let tap = gTap
        gTapEnabled = needed
        os_unfair_lock_unlock(&gSuppressLock)
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: needed)
        }
    }
}
