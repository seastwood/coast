import Foundation
import Darwin

// MARK: - Fixed tunables

enum Tune {
    static let historyLen = 10          // recent samples kept for the velocity estimate
    static let velocityWindow = 0.05    // estimate release velocity from motion in this final window (s)
    static let staleSample = 0.08       // if the last motion is older than this at lift, don't fling
    static let launchPoll = 0.010       // launcher wakeup cadence while the pad is in use
    static let idlePoll = 0.25          // launcher wakeup cadence once the pad has gone idle
    static let padActive = 0.5          // "pad in use" = a real move event within this window
    static let minSpeed = 2.0           // px/frame below which the coast ends
    static let frameDT = 1.0 / 120.0    // animation tick rate
    static let coarseWait = 0.002       // the last part of each frame wait is a precise mach_wait_until:
                                        // a condvar wait alone overshoots by 1-3 ms under load, and in
                                        // captured mode tick-timing wobble IS remote cursor jitter
    static let tapHealth = 2.0          // how often to confirm the event tap is still enabled
    static let maxLaunchSpeed = 700.0   // px/frame ceiling; faster than any human flick -> a glitch
    static let mtStale = 0.25           // no multitouch frame within this while the pad is in use ->
                                        // contact detection has gone silent (typically after sleep)
    static let rtComputation = 0.0015   // real-time coast thread: CPU it may use each frame ...
    static let rtConstraint = 0.004     // ... and the window it must get that CPU within
    static let mtMouseFamilies: Set<Int32> = [112, 113]  // MTDeviceGetFamilyID values for Magic Mice
    static let mtSilentRebuild = 30.0   // min gap between rebuilds triggered by frame silence alone:
                                        // ordinary MOUSE movement mimics the dead-MT signature
    static let captureMinDelta = 1.0    // px/frame: delta motion below this never reads as "captured"
    static let capturePosRatio = 0.25   // captured = on-screen motion under this fraction of the delta motion
    static let syntheticTag: Int64 = 0x7242B411  // stamped on our own posted moves so the tap ignores them
}

let appName = "Coast"
let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

// MARK: - Clocks

enum Clock {
    /// Seconds per mach_absolute_time tick.
    static let machToSec: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1e-9 : Double(tb.numer) / Double(tb.denom) * 1e-9
    }()
    /// Monotonic seconds. Like Python's time.monotonic on macOS it stands still during sleep,
    /// which is what the sleep/wake detection relies on.
    static func now() -> Double { Double(mach_absolute_time()) * machToSec }
    /// Wall-clock seconds; keeps running through sleep.
    static func wall() -> Double { Date().timeIntervalSince1970 }
}

// MARK: - Debug log

let debugLogging = ProcessInfo.processInfo.environment["COAST_DEBUG"].map { !$0.isEmpty } ?? false
private let logPath = NSHomeDirectory() + "/.coast.log"
private let logLock = NSLock()
private let logTimeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

/// Appends a line to ~/.coast.log when COAST_DEBUG=1; a no-op otherwise. Lets us diagnose
/// post-sleep misbehaviour in the field without attaching a terminal.
func log(_ message: @autoclosure () -> String) {
    guard debugLogging else { return }
    logLock.lock(); defer { logLock.unlock() }
    let line = "\(logTimeFormat.string(from: Date())) \(message())\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}

// MARK: - Signal (a threading.Event)

/// A settable flag threads can wait on with a timeout.
final class Signal {
    private let cond = NSCondition()
    private var flag = false

    func set() { cond.lock(); flag = true; cond.broadcast(); cond.unlock() }
    func clear() { cond.lock(); flag = false; cond.unlock() }
    var isSet: Bool { cond.lock(); defer { cond.unlock() }; return flag }

    /// Waits up to `timeout` seconds; true if the flag is set.
    @discardableResult func wait(_ timeout: Double) -> Bool {
        cond.lock(); defer { cond.unlock() }
        let until = Date(timeIntervalSinceNow: max(timeout, 0))
        while !flag { if !cond.wait(until: until) { break } }
        return flag
    }
}

// MARK: - Settings

/// User-editable settings, changed from the menu bar and persisted to ~/.coast.json.
final class Settings {
    static let shared = Settings()
    static let glidePresets: [(String, Double)] = [("Short", 0.90), ("Medium", 0.93), ("Long", 0.965)]
    static let sensitivityPresets: [(String, Double)] = [("Low", 14.0), ("Medium", 8.0), ("High", 4.0)]

    private let path = NSHomeDirectory() + "/.coast.json"
    // Older config filenames, read once if the current one is missing so settings carry over.
    private let legacyPaths = [NSHomeDirectory() + "/.trackball_inertia.json"]
    private let lock = NSLock()
    private var _enabled = true
    private var _friction = 0.93          // velocity *= this every frame (higher = longer glide)
    private var _minLaunchSpeed = 8.0     // don't coast for flicks slower than this px/frame

    var enabled: Bool { get { read { _enabled } } set { write { _enabled = newValue } } }
    var friction: Double { get { read { _friction } } set { write { _friction = newValue } } }
    var minLaunchSpeed: Double { get { read { _minLaunchSpeed } } set { write { _minLaunchSpeed = newValue } } }

    private func read<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func write(_ body: () -> Void) { lock.lock(); body(); lock.unlock(); save() }

    func load() {
        for p in [path] + legacyPaths {
            guard let data = FileManager.default.contents(atPath: p),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            lock.lock()
            if let v = dict["enabled"] as? Bool { _enabled = v }
            if let v = (dict["friction"] as? NSNumber)?.doubleValue { _friction = v }
            if let v = (dict["min_launch_speed"] as? NSNumber)?.doubleValue { _minLaunchSpeed = v }
            lock.unlock()
            if p != path { save() }   // migrate to the current filename
            return
        }
    }

    func save() {
        let dict: [String: Any] = read { ["enabled": _enabled, "friction": _friction, "min_launch_speed": _minLaunchSpeed] }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)   // a crash mid-write can't corrupt it
    }
}

// MARK: - Single instance

private var instanceLockFD: Int32 = -1   // kept open for the process lifetime; the flock dies with us

/// Refuses to run two Coasts at once (e.g. the installed app plus a dev run): both would post coast
/// moves and brake each other's coasts. The kernel releases the flock when the process exits, even
/// on a crash, so there are no stale locks to clean up.
func acquireSingleInstanceLock() -> Bool {
    let fd = open(NSHomeDirectory() + "/.coast.lock", O_WRONLY | O_CREAT, 0o644)
    guard fd >= 0 else { return true }   // can't create the lock file -> don't block startup over it
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
    instanceLockFD = fd
    ftruncate(fd, 0)
    let pid = "\(getpid())"
    _ = pid.withCString { write(fd, $0, strlen($0)) }
    return true
}

// MARK: - Thread scheduling

/// Gives the calling thread the time-constraint (real-time) policy audio and display threads use:
/// a 1/120 s period with a little CPU guaranteed inside a few ms. QoS alone is a hint the scheduler
/// bends under load (a live stream, a game); this is a deadline it keeps. The kernel demotes a
/// thread that overruns its computation, so a misbehaving coast can never hog a core.
func makeThreadRealtime() {
    func ticks(_ seconds: Double) -> UInt32 { UInt32(seconds / Clock.machToSec) }
    var policy = thread_time_constraint_policy_data_t(
        period: ticks(Tune.frameDT), computation: ticks(Tune.rtComputation),
        constraint: ticks(Tune.rtConstraint), preemptible: 1)
    let thread = mach_thread_self()
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    let rc = withUnsafeMutablePointer(to: &policy) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_policy_set(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
        }
    }
    mach_port_deallocate(mach_task_self_, thread)
    if rc != KERN_SUCCESS { log("real-time coast thread refused: \(rc)") }
}
