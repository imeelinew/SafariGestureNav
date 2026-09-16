import CoreFoundation
import Foundation

// Unpublished Apple API. Encapsulated here on purpose: MultitouchSupport is a
// private system framework. It is not an official public trackpad API.

typealias MTDeviceRef = UnsafeMutableRawPointer

typealias MTContactCallbackFunction = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

@_silgen_name("MTDeviceCreateDefault")
func MTDeviceCreateDefault() -> MTDeviceRef?

@_silgen_name("MTDeviceCreateList")
func MTDeviceCreateList() -> CFArray?

@_silgen_name("MTDeviceStart")
func MTDeviceStart(_ device: MTDeviceRef, _ mode: Int32)

@_silgen_name("MTDeviceStop")
func MTDeviceStop(_ device: MTDeviceRef)

@_silgen_name("MTDeviceIsRunning")
func MTDeviceIsRunning(_ device: MTDeviceRef) -> Bool

@_silgen_name("MTDeviceGetSensorSurfaceDimensions")
func MTDeviceGetSensorSurfaceDimensions(
    _ device: MTDeviceRef,
    _ width: UnsafeMutablePointer<Int32>,
    _ height: UnsafeMutablePointer<Int32>
)

@_silgen_name("MTRegisterContactFrameCallback")
func MTRegisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactCallbackFunction)

@_silgen_name("MTUnregisterContactFrameCallback")
func MTUnregisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactCallbackFunction?)

struct MTPoint {
    var x: Float
    var y: Float
}

struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

enum TouchState {
    static let make: UInt32 = 3
    static let touching: UInt32 = 4
    static let breakTouch: UInt32 = 5

    static func isOnSurface(_ state: UInt32) -> Bool {
        state == make || state == touching || state == breakTouch
    }
}

struct TrackpadContact: Equatable {
    let identifier: Int32
    let x: Float
    let y: Float
    let size: Float
    let state: UInt32
    let isOnSurface: Bool
}

struct TrackpadFrame {
    let deviceID: UInt
    let timestamp: TimeInterval
    let contacts: [TrackpadContact]
    let widthMM: Float
    let heightMM: Float

    var onSurfaceCount: Int {
        contacts.filter(\.isOnSurface).count
    }
}

private nonisolated(unsafe) var gInput: GestureInput?
private nonisolated(unsafe) var gInputEnabled = false
private nonisolated(unsafe) var gInputLock = os_unfair_lock()

private let contactCallback: MTContactCallbackFunction = { device, touches, numTouches, timestamp, _ in
    os_unfair_lock_lock(&gInputLock)
    guard gInputEnabled, let input = gInput, let touches else {
        os_unfair_lock_unlock(&gInputLock)
        return 0
    }
    let handler = input.onFrame
    let size = input.surfaceSize(for: device)
    let deviceID = device.map { UInt(truncatingIfNeeded: Int(bitPattern: $0)) } ?? 0
    os_unfair_lock_unlock(&gInputLock)

    let pointer = touches.assumingMemoryBound(to: MTTouch.self)
    var contacts: [TrackpadContact] = []
    contacts.reserveCapacity(Int(numTouches))
    for index in 0..<Int(numTouches) {
        let touch = pointer[index]
        contacts.append(
            TrackpadContact(
                identifier: touch.pathIndex,
                x: touch.normalizedVector.position.x,
                y: touch.normalizedVector.position.y,
                size: touch.zTotal,
                state: touch.state,
                isOnSurface: TouchState.isOnSurface(touch.state)
            )
        )
    }
    handler?(
        TrackpadFrame(
            deviceID: deviceID,
            timestamp: timestamp,
            contacts: contacts,
            widthMM: size.widthMM,
            heightMM: size.heightMM
        )
    )
    return 0
}

final class GestureInput: @unchecked Sendable {
    struct SurfaceSize {
        var widthMM: Float
        var heightMM: Float
    }

    static let fallbackSize = SurfaceSize(widthMM: 160, heightMM: 115)

    var onFrame: ((TrackpadFrame) -> Void)?

    private let stateLock = NSLock()
    private var running = false
    private var devices: [MTDeviceRef] = []
    private var deviceSizes: [(device: MTDeviceRef, size: SurfaceSize)] = []

    var attachedDeviceCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return devices.count
    }

    func surfaceSize(for device: MTDeviceRef?) -> SurfaceSize {
        guard let device else { return Self.fallbackSize }
        for entry in deviceSizes where entry.device == device {
            return entry.size
        }
        return Self.fallbackSize
    }

    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return !devices.isEmpty }

        var collectedDevices: [MTDeviceRef] = []
        var sizes: [(device: MTDeviceRef, size: SurfaceSize)] = []

        func register(_ device: MTDeviceRef) {
            _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
            let size = physicalSize(of: device)
            if size.widthMM < 60 {
                AppLog.info("skip small multitouch device \(size.widthMM)x\(size.heightMM) mm")
                return
            }
            sizes.append((device, size))
            MTRegisterContactFrameCallback(device, contactCallback)
            MTDeviceStart(device, 0)
            collectedDevices.append(device)
            AppLog.info("trackpad \(size.widthMM)x\(size.heightMM) mm device=\(UInt(bitPattern: device))")
        }

        if let list = MTDeviceCreateList() {
            for index in 0..<CFArrayGetCount(list) {
                guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
                register(UnsafeMutableRawPointer(mutating: raw))
            }
        }
        if collectedDevices.isEmpty, let device = MTDeviceCreateDefault() {
            register(device)
        }

        devices = collectedDevices
        deviceSizes = sizes
        running = !collectedDevices.isEmpty

        os_unfair_lock_lock(&gInputLock)
        gInput = self
        gInputEnabled = running
        os_unfair_lock_unlock(&gInputLock)

        if running {
            AppLog.info("GestureInput started with \(collectedDevices.count) device(s)")
        } else {
            AppLog.error("GestureInput found no trackpad devices")
        }
        return running
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running else { return }
        running = false

        os_unfair_lock_lock(&gInputLock)
        gInputEnabled = false
        if gInput === self { gInput = nil }
        os_unfair_lock_unlock(&gInputLock)

        for device in devices {
            MTUnregisterContactFrameCallback(device, contactCallback)
            if MTDeviceIsRunning(device) {
                MTDeviceStop(device)
            }
        }
        devices.removeAll()
        AppLog.info("GestureInput stopped")
    }

    private func physicalSize(of device: MTDeviceRef) -> SurfaceSize {
        var width: Int32 = 0
        var height: Int32 = 0
        MTDeviceGetSensorSurfaceDimensions(device, &width, &height)
        guard width > 0, height > 0 else { return Self.fallbackSize }
        return SurfaceSize(widthMM: Float(width) / 100, heightMM: Float(height) / 100)
    }
}
