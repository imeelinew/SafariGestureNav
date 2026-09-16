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
    private let movementMM: Float = 3.6

    private struct Candidate {
        var deviceID: UInt
        var startTime: TimeInterval
        var startPositions: [Int32: (x: Float, y: Float)]
        var widthMM: Float
        var heightMM: Float
        var lastTime: TimeInterval
        var lastPositions: [Int32: (x: Float, y: Float)]
        var travelXMM: Float = 0
        var travelYMM: Float = 0
        var pathMM: Float = 0
        var coherentPathMM: Float = 0
        var peakSpeedMMPerSecond: Float = 0
        var motionSamples = 0
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
                lastTime: frame.timestamp,
                lastPositions: Dictionary(uniqueKeysWithValues: onSurface.map { ($0.identifier, ($0.x, $0.y)) }),
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

        if movedTooFar(onSurface, current: &current, at: frame.timestamp) {
            current.cancelled = true
            candidate = current
            onCandidateChanged?(current.lockedCount ?? current.maxCount, false)
            AppLog.info("tap cancelled: scroll-like movement \(motionSummary(current, at: frame.timestamp))")
            return
        }

        candidate = current
        onCandidateChanged?(current.lockedCount ?? current.maxCount, true)
    }

    private func movedTooFar(
        _ contacts: [TrackpadContact],
        current: inout Candidate,
        at timestamp: TimeInterval
    ) -> Bool {
        var exceededHardLimit = false
        for contact in contacts {
            guard let start = current.startPositions[contact.identifier] else { continue }
            let dx = (contact.x - start.x) * current.widthMM
            let dy = (contact.y - start.y) * current.heightMM
            if hypot(dx, dy) > movementMM {
                exceededHardLimit = true
            }
        }

        let elapsed = timestamp - current.lastTime
        let deltas: [(x: Float, y: Float)] = contacts.compactMap { contact in
            guard let previous = current.lastPositions[contact.identifier] else { return nil }
            return (
                (contact.x - previous.x) * current.widthMM,
                (contact.y - previous.y) * current.heightMM
            )
        }

        // Adding or lifting a finger must not look like centroid movement. Only
        // compare frames that share at least two contact identifiers.
        if elapsed > 0, deltas.count >= 2 {
            let count = Float(deltas.count)
            let stepX = deltas.reduce(0) { $0 + $1.x } / count
            let stepY = deltas.reduce(0) { $0 + $1.y } / count
            let stepDistance = hypot(stepX, stepY)
            let meanFingerDistance = deltas.reduce(0) { $0 + hypot($1.x, $1.y) } / count
            let coherence = meanFingerDistance > 0.01 ? stepDistance / meanFingerDistance : 0

            // Ignore sub-0.04 mm sensor noise. A scroll moves both contacts in
            // the same direction; a tap's landing jitter is usually incoherent
            // or reverses direction before the fingers leave the surface.
            if stepDistance >= 0.04 {
                current.travelXMM += stepX
                current.travelYMM += stepY
                current.pathMM += stepDistance
                current.peakSpeedMMPerSecond = max(
                    current.peakSpeedMMPerSecond,
                    stepDistance / Float(elapsed)
                )
                current.motionSamples += 1
                if coherence >= 0.72 {
                    current.coherentPathMM += stepDistance
                }
            }
        }

        current.lastTime = timestamp
        current.lastPositions = Dictionary(
            uniqueKeysWithValues: contacts.map { ($0.identifier, ($0.x, $0.y)) }
        )

        return exceededHardLimit || looksLikeScroll(current, duration: timestamp - current.startTime)
    }

    private func finish(_ current: Candidate, at timestamp: TimeInterval) {
        candidate = nil
        onCandidateChanged?(nil, false)
        guard !current.cancelled else { return }

        let fingers = current.lockedCount ?? current.maxCount
        let elapsed = timestamp - current.startTime
        guard elapsed <= maxDuration, fingers == 2 || fingers == 3 else { return }
        guard !looksLikeScroll(current, duration: elapsed) else {
            AppLog.info("tap ignored: scroll-like finish \(motionSummary(current, at: timestamp))")
            return
        }
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

    private func looksLikeScroll(_ current: Candidate, duration: TimeInterval) -> Bool {
        guard current.motionSamples > 0, current.pathMM > 0 else { return false }

        let displacement = hypot(current.travelXMM, current.travelYMM)
        let directionConsistency = displacement / current.pathMM
        let coherentShare = current.coherentPathMM / current.pathMM
        let verticalShare = displacement > 0 ? abs(current.travelYMM) / displacement : 0
        let averageSpeed = displacement / Float(max(duration, 0.001))

        guard directionConsistency >= 0.76, coherentShare >= 0.72 else { return false }

        let fastVerticalScroll = abs(current.travelYMM) >= 0.75
            && verticalShare >= 0.62
            && current.peakSpeedMMPerSecond >= 12
            && averageSpeed >= 6
        let deliberateVerticalScroll = abs(current.travelYMM) >= 1.10
            && verticalShare >= 0.58
            && current.peakSpeedMMPerSecond >= 6
        let directionalScroll = displacement >= 1.20
            && current.peakSpeedMMPerSecond >= 10
        let slowButClearScroll = displacement >= 1.55

        return fastVerticalScroll || deliberateVerticalScroll || directionalScroll || slowButClearScroll
    }

    private func motionSummary(_ current: Candidate, at timestamp: TimeInterval) -> String {
        let displacement = hypot(current.travelXMM, current.travelYMM)
        let consistency = current.pathMM > 0 ? displacement / current.pathMM : 0
        let verticalShare = displacement > 0 ? abs(current.travelYMM) / displacement : 0
        let averageSpeed = displacement / Float(max(timestamp - current.startTime, 0.001))
        return String(
            format: "distance=%.2fmm vertical=%.2f consistency=%.2f peak=%.1fmm/s avg=%.1fmm/s",
            displacement,
            verticalShare,
            consistency,
            current.peakSpeedMMPerSecond,
            averageSpeed
        )
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

        func frame(
            t: Double,
            fingers: Int,
            xOffset: Float = 0,
            yOffset: Float = 0,
            device: UInt = 1
        ) -> TrackpadFrame {
            let contacts = (0..<fingers).map { index in
                TrackpadContact(
                    identifier: Int32(index + 1),
                    x: 0.4 + Float(index) * 0.05 + xOffset,
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

        emit([
            frame(t: 0, fingers: 2),
            frame(t: 0.025, fingers: 2, yOffset: 0.007),
            frame(t: 0.050, fingers: 2, yOffset: 0.012),
            frame(t: 0.060, fingers: 0)
        ])
        if !actions.isEmpty { failures.append("short fast vertical scroll should cancel, got \(actions)") }

        emit([
            frame(t: 0, fingers: 2),
            frame(t: 0.060, fingers: 2, xOffset: 0.004, yOffset: 0.006),
            frame(t: 0.110, fingers: 2, xOffset: 0.008, yOffset: 0.012),
            frame(t: 0.120, fingers: 0)
        ])
        if !actions.isEmpty { failures.append("short diagonal scroll should cancel, got \(actions)") }

        emit([
            frame(t: 0, fingers: 2),
            frame(t: 0.040, fingers: 2, yOffset: 0.004),
            frame(t: 0.080, fingers: 2, yOffset: -0.001),
            frame(t: 0.120, fingers: 0)
        ])
        if actions != [.back] { failures.append("small reversing tap jitter should still back, got \(actions)") }

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
