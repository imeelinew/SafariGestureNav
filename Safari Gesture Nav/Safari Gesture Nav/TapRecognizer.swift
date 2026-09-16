import Foundation

enum NavigationAction: String {
    case back
    case forward
}

final class TapRecognizer {
    var onAction: ((NavigationAction, String) -> Void)?
    var onCandidateChanged: ((Int?, Bool) -> Void)?

    private let gatherWindow: TimeInterval = 0.080
    private let maxDuration: TimeInterval = 0.220
    private let debounce: TimeInterval = 0.300
    // TODO(eli): 双指滑动防误触。滑动起手也是两指，短距离一抬就会走 finish() 变成 back。
    // 请改 movedTooFar(_:) 和 finish(_:at:)：用速度、位移方向是否一致、纵向分量，把 scroll 和轻点分开。不要只靠这个毫米阈值。
    private let movementMM: Float = 3.6

    private struct Candidate {
        var deviceID: UInt
        var startTime: TimeInterval
        var startPositions: [Int32: (x: Float, y: Float)]
        var widthMM: Float
        var heightMM: Float
        var lockedCount: Int?
        var maxCount: Int
        var cancelled = false
    }

    private var candidate: Candidate?
    private var lastActionAt: TimeInterval = -1
    private var lastActionID = ""

    func reset(reason: String) {
        if candidate != nil {
            AppLog.info("tap reset: \(reason)")
        }
        candidate = nil
        lastActionAt = -1
        onCandidateChanged?(nil, false)
    }

    func notePhysicalClick() {
        guard var current = candidate, !current.cancelled else { return }
        current.cancelled = true
        candidate = current
        onCandidateChanged?(current.lockedCount ?? current.maxCount, false)
        AppLog.info("tap cancelled: physical click")
    }

    func handle(_ frame: TrackpadFrame) {
        let onSurface = frame.contacts.filter(\.isOnSurface)
        let count = onSurface.count

        if count >= 4 {
            reset(reason: "four-or-more fingers")
            return
        }

        if candidate == nil {
            guard count >= 1 else { return }
            candidate = Candidate(
                deviceID: frame.deviceID,
                startTime: frame.timestamp,
                startPositions: Dictionary(uniqueKeysWithValues: onSurface.map { ($0.identifier, ($0.x, $0.y)) }),
                widthMM: frame.widthMM,
                heightMM: frame.heightMM,
                lockedCount: nil,
                maxCount: count
            )
            onCandidateChanged?(count, true)
            return
        }

        guard var current = candidate else { return }

        if current.deviceID != frame.deviceID {
            reset(reason: "device changed")
            return
        }

        if count == 0 {
            finish(current, at: frame.timestamp)
            return
        }

        if current.cancelled {
            return
        }

        let elapsed = frame.timestamp - current.startTime
        if elapsed <= gatherWindow {
            current.maxCount = max(current.maxCount, count)
            for contact in onSurface where current.startPositions[contact.identifier] == nil {
                current.startPositions[contact.identifier] = (contact.x, contact.y)
            }
        } else if current.lockedCount == nil {
            current.lockedCount = current.maxCount
            if count > current.maxCount {
                current.cancelled = true
                candidate = current
                onCandidateChanged?(current.lockedCount, false)
                AppLog.info("tap cancelled: finger added after lock")
                return
            }
        } else if count > (current.lockedCount ?? current.maxCount) {
            current.cancelled = true
            candidate = current
            onCandidateChanged?(current.lockedCount, false)
            AppLog.info("tap cancelled: extra finger after lock")
            return
        }

        if elapsed > maxDuration {
            current.cancelled = true
            candidate = current
            onCandidateChanged?(current.lockedCount ?? current.maxCount, false)
            AppLog.info("tap cancelled: held too long")
            return
        }

        if movedTooFar(onSurface, current: current) {
            current.cancelled = true
            candidate = current
            onCandidateChanged?(current.lockedCount ?? current.maxCount, false)
            AppLog.info("tap cancelled: moved")
            return
        }

        candidate = current
        onCandidateChanged?(current.lockedCount ?? current.maxCount, true)
    }

    private func movedTooFar(_ contacts: [TrackpadContact], current: Candidate) -> Bool {
        for contact in contacts {
            guard let start = current.startPositions[contact.identifier] else { continue }
            let dx = (contact.x - start.x) * current.widthMM
            let dy = (contact.y - start.y) * current.heightMM
            if hypot(dx, dy) > movementMM {
                return true
            }
        }
        return false
    }

    private func finish(_ current: Candidate, at timestamp: TimeInterval) {
        candidate = nil
        onCandidateChanged?(nil, false)
        guard !current.cancelled else { return }

        let fingers = current.lockedCount ?? current.maxCount
        let elapsed = timestamp - current.startTime
        guard elapsed <= maxDuration, fingers == 2 || fingers == 3 else { return }
        guard timestamp - lastActionAt >= debounce else {
            AppLog.info("tap ignored: debounce")
            return
        }

        let action: NavigationAction = fingers == 2 ? .back : .forward
        let id = UUID().uuidString
        lastActionAt = timestamp
        lastActionID = id
        AppLog.info("recognized \(action.rawValue) fingers=\(fingers) id=\(id)")
        onAction?(action, id)
    }
}

extension TapRecognizer {
    static func runSelfTest() -> [String] {
        let recognizer = TapRecognizer()
        var actions: [NavigationAction] = []
        recognizer.onAction = { action, _ in actions.append(action) }

        func emit(_ frames: [TrackpadFrame]) {
            actions.removeAll()
            recognizer.reset(reason: "test")
            frames.forEach { recognizer.handle($0) }
        }

        func frame(t: Double, fingers: Int, yOffset: Float = 0, device: UInt = 1) -> TrackpadFrame {
            let contacts = (0..<fingers).map { index in
                TrackpadContact(
                    identifier: Int32(index + 1),
                    x: 0.4 + Float(index) * 0.05,
                    y: 0.5 + yOffset,
                    size: 0.1,
                    state: 4,
                    isOnSurface: true
                )
            }
            return TrackpadFrame(deviceID: device, timestamp: t, contacts: contacts, widthMM: 160, heightMM: 115)
        }

        var failures: [String] = []

        emit([frame(t: 0, fingers: 2), frame(t: 0.05, fingers: 2), frame(t: 0.12, fingers: 0)])
        if actions != [.back] { failures.append("two-finger tap should back, got \(actions)") }

        emit([frame(t: 0, fingers: 3), frame(t: 0.05, fingers: 3), frame(t: 0.12, fingers: 0)])
        if actions != [.forward] { failures.append("three-finger tap should forward, got \(actions)") }

        emit([
            frame(t: 0, fingers: 1),
            frame(t: 0.02, fingers: 2),
            frame(t: 0.05, fingers: 3),
            frame(t: 0.12, fingers: 2),
            frame(t: 0.13, fingers: 1),
            frame(t: 0.14, fingers: 0)
        ])
        if actions != [.forward] { failures.append("three-finger lift must not emit back, got \(actions)") }

        emit([frame(t: 0, fingers: 2), frame(t: 0.05, fingers: 2, yOffset: 0.2), frame(t: 0.12, fingers: 0)])
        if !actions.isEmpty { failures.append("movement should cancel, got \(actions)") }

        emit([frame(t: 0, fingers: 2), frame(t: 0.25, fingers: 2), frame(t: 0.26, fingers: 0)])
        if !actions.isEmpty { failures.append("long press should cancel, got \(actions)") }

        emit([frame(t: 0, fingers: 4), frame(t: 0.05, fingers: 0)])
        if !actions.isEmpty { failures.append("four fingers should cancel, got \(actions)") }

        emit([frame(t: 0, fingers: 2), frame(t: 0.04, fingers: 2)])
        recognizer.notePhysicalClick()
        recognizer.handle(frame(t: 0.12, fingers: 0))
        if !actions.isEmpty { failures.append("physical click should cancel, got \(actions)") }

        return failures
    }
}
