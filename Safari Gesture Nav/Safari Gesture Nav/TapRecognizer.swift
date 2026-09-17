import Foundation

enum NavigationAction: String {
    case back
    case forward
}

final class TapRecognizer {
    var onAction: ((NavigationAction, String) -> Void)?

    private let gatherWindow: TimeInterval = 0.080
    private let maxDuration: TimeInterval = 0.220
    private let debounce: TimeInterval = 0.300
    private let movementMM: Float = 3.6

    private struct Candidate {
        let deviceID: UInt
        let startTime: TimeInterval
        var positions: [Int32: (x: Float, y: Float)]
        let widthMM: Float
        let heightMM: Float
        var fingerCount: Int
        var lockedCount: Int?
        var cancelled = false
    }

    private var candidate: Candidate?
    private var lastActionAt: TimeInterval = -.infinity

    func reset(reason: String) {
        if candidate != nil {
            AppLog.info("tap reset: \(reason)")
        }
        candidate = nil
    }

    func handle(_ frame: TrackpadFrame) {
        let contacts = frame.contacts.filter(\.isOnSurface)
        let count = contacts.count

        if candidate == nil {
            guard (1...4).contains(count) else { return }
            candidate = Candidate(
                deviceID: frame.deviceID,
                startTime: frame.timestamp,
                positions: Dictionary(uniqueKeysWithValues: contacts.map { ($0.identifier, ($0.x, $0.y)) }),
                widthMM: frame.widthMM,
                heightMM: frame.heightMM,
                fingerCount: count
            )
            return
        }

        guard var current = candidate else { return }
        if current.deviceID != frame.deviceID || count > 4 {
            reset(reason: "device changed or too many fingers")
            return
        }
        if count == 0 {
            candidate = nil
            let fingers = current.lockedCount ?? current.fingerCount
            guard !current.cancelled,
                  frame.timestamp - current.startTime <= maxDuration,
                  frame.timestamp - lastActionAt >= debounce,
                  fingers == 3 || fingers == 4 else { return }
            let action: NavigationAction = fingers == 3 ? .back : .forward
            let id = UUID().uuidString
            lastActionAt = frame.timestamp
            AppLog.info("recognized \(action.rawValue) fingers=\(fingers) id=\(id)")
            onAction?(action, id)
            return
        }

        guard !current.cancelled else { return }
        let elapsed = frame.timestamp - current.startTime
        if elapsed > maxDuration {
            current.cancelled = true
        } else if elapsed <= gatherWindow {
            current.fingerCount = max(current.fingerCount, count)
            for contact in contacts where current.positions[contact.identifier] == nil {
                current.positions[contact.identifier] = (contact.x, contact.y)
            }
        } else {
            if current.lockedCount == nil { current.lockedCount = current.fingerCount }
            if count > current.lockedCount! { current.cancelled = true }
        }

        // A tap stays near its landing point; movement means this was a swipe.
        if contacts.contains(where: { contact in
            guard let start = current.positions[contact.identifier] else { return false }
            return hypot((contact.x - start.x) * current.widthMM,
                         (contact.y - start.y) * current.heightMM) > movementMM
        }) {
            current.cancelled = true
        }
        candidate = current
    }
}

extension TapRecognizer {
    static func runSelfTest() -> [String] {
        let recognizer = TapRecognizer()
        var actions: [NavigationAction] = []
        var failures: [String] = []
        recognizer.onAction = { action, _ in actions.append(action) }

        func frame(_ t: Double, _ fingers: Int, offset: Float = 0) -> TrackpadFrame {
            TrackpadFrame(deviceID: 1, timestamp: t, contacts: (0..<fingers).map { index in
                TrackpadContact(identifier: Int32(index + 1), x: 0.3 + Float(index) * 0.08,
                                y: 0.5 + offset, size: 0.1, state: 4, isOnSurface: true)
            }, widthMM: 160, heightMM: 115)
        }
        func check(_ name: String, _ frames: [TrackpadFrame], expected: [NavigationAction]) {
            actions.removeAll()
            recognizer.reset(reason: "test")
            frames.forEach { recognizer.handle($0) }
            if actions != expected { failures.append("\(name): expected \(expected), got \(actions)") }
        }

        check("two fingers", [frame(0, 2), frame(0.12, 0)], expected: [])
        check("three fingers", [frame(1, 3), frame(1.05, 3), frame(1.12, 0)], expected: [.back])
        check("four fingers", [frame(2, 4), frame(2.05, 4), frame(2.12, 0)], expected: [.forward])
        check("four finger lift", [frame(3, 3), frame(3.02, 4), frame(3.1, 3), frame(3.13, 0)], expected: [.forward])
        check("swipe", [frame(4, 3), frame(4.05, 3, offset: 0.1), frame(4.12, 0)], expected: [])
        check("long press", [frame(5, 4), frame(5.25, 4), frame(5.26, 0)], expected: [])
        return failures
    }
}
