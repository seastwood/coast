import Foundation
import CoreFoundation

// MultitouchSupport (private framework): detects actual finger contact for instant braking.
// Only the finger COUNT argument is read, never the per-finger structs, so a change to the private
// Finger layout can't break it.

/// int callback(MTDeviceRef device, Finger *data, int nFingers, double timestamp, int frame)
typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

/// Runs on the multitouch frame thread; keep it tiny.
private let contactCallback: MTContactCallback = { _, _, fingers, _, _ in
    Engine.shared.contactFrame(fingers: Int(fingers))
    return 0
}

final class Multitouch {
    private typealias CreateList = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias FamilyID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32

    private var createList: CreateList?
    private var register: Register?
    private var start: Start?
    private var stop: Stop?
    private var familyID: FamilyID?
    private var devices: [UnsafeMutableRawPointer] = []   // touched only by init and the watchdog thread
    /// Contact detection came up at launch (at least one trackpad).
    private(set) var active = false

    /// Loads the framework and starts every trackpad. False if it's unavailable.
    func open() -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let c = dlsym(h, "MTDeviceCreateList"), let r = dlsym(h, "MTRegisterContactFrameCallback"),
              let s = dlsym(h, "MTDeviceStart"), let t = dlsym(h, "MTDeviceStop") else { return false }
        createList = unsafeBitCast(c, to: CreateList.self)
        register = unsafeBitCast(r, to: Register.self)
        start = unsafeBitCast(s, to: Start.self)
        stop = unsafeBitCast(t, to: Stop.self)
        familyID = dlsym(h, "MTDeviceGetFamilyID").map { unsafeBitCast($0, to: FamilyID.self) }
        devices = openDevices()
        active = !devices.isEmpty
        log("multitouch: \(devices.count) trackpad(s)")
        return active
    }

    /// Rebuilds contact detection after it stops delivering frames (notably across a long lid-closed
    /// sleep). Stopping and re-starting the SAME handles is not enough: after a deep sleep they are dead
    /// and deliver nothing, so they are dropped and a brand-new device list is created.
    func restart() {
        guard active, let stop else { return }
        for d in devices { stop(d) }   // a no-op if the handle is already dead
        devices = []
        usleep(50_000)
        devices = openDevices()
        log("rebuilt multitouch -> \(devices.count) device(s)")
    }

    /// Creates, registers and starts a FRESH set of devices. Magic Mice are skipped: only trackpads feed
    /// contact detection, which is what keeps the coast effect trackpad-only. The list is deliberately
    /// never released (as before), so no device object it owns can be freed under the framework.
    private func openDevices() -> [UnsafeMutableRawPointer] {
        guard let createList, let register, let start, let raw = createList() else { return [] }
        let list = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        var out: [UnsafeMutableRawPointer] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let item = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: item)
            if isMagicMouse(device) { log("skipping Magic Mouse multitouch device"); continue }
            register(device, contactCallback)
            start(device, 0)
            out.append(device)
        }
        return out
    }

    /// Family IDs are private-API folklore (112 confirmed for the Magic Mouse), so this fails OPEN: if
    /// the family can't be read the device counts as a trackpad, rather than silently disabling
    /// coasting on some future trackpad.
    private func isMagicMouse(_ device: UnsafeMutableRawPointer) -> Bool {
        guard let familyID else { return false }
        var family: Int32 = -1
        return familyID(device, &family) == 0 && Tune.mtMouseFamilies.contains(family)
    }
}
