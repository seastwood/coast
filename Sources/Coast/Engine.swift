import AppKit
import CoreGraphics

/// One real cursor sample. The finger-contact tag is what attributes motion to a device class:
/// trackpad movement always happens under finger contact, mouse movement never does, so only
/// finger-down samples can launch a coast. dx/dy are the event's relative deltas: the only motion
/// that survives when an app captures the mouse and the on-screen position freezes.
struct Sample {
    var x, y, dx, dy: Double
    var eventTime: Double       // the event's own hardware timestamp, in seconds
    var processedTime: Double   // when we saw it (monotonic)
    var fingersDown: Bool
}

/// The inertia engine: measures flicks from the event tap, decides when a lift launches a coast,
/// animates the glide on a real-time thread and keeps everything alive across sleep/wake.
final class Engine {
    static let shared = Engine()

    let settings = Settings.shared
    let multitouch = Multitouch()
    let cancel = Signal()          // brakes the active coast immediately
    let lift = Signal()            // a finger lifted: wakes the launcher
    let resetStroke = Signal()     // a finger touched: the next sample starts a fresh stroke
    let rebuildRequest = Signal()  // a sleep/wake gap was seen: rebuild multitouch right away

    private(set) var tap: CFMachPort?
    private var source: CGEventSource?   // zero-suppression source used to post coast moves

    private let lock = NSLock()          // guards everything below
    private var samples: [Sample] = []
    private var lastEventTime = 0.0      // monotonic time of the last real event
    private var lastWallTime = 0.0       // wall-clock time of the last real event (sleep-aware)
    private var fingersDown = false      // current trackpad contact state (from multitouch)
    private var mtLastFrame = 0.0        // last contact frame (freshness check)
    private var lastSilentRebuild = 0.0  // last frame-silence-triggered rebuild (throttled)
    private var coasting = false
    private var stopping = false
    // CGEventGetTimestamp's unit isn't guaranteed (mach ticks vs nanoseconds), so it is detected from
    // the first real event by comparing it to mach_absolute_time().
    private var timestampScale: Double?

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var isCoasting: Bool { locked { coasting } }
    func stop() { locked { stopping = true }; cancel.set() }
    private var isStopping: Bool { locked { stopping } }

    // MARK: Startup

    /// Sets up the event source, multitouch and the event tap. False without input permission.
    func start() -> Bool {
        source = CGEventSource(stateID: .hidSystemState)
        // Turn OFF post-event hardware suppression so a returning finger is never ignored. This is
        // what makes re-flicking instant (CGWarpMouseCursorPosition would block input for ~250 ms).
        source?.localEventsSuppressionInterval = 0

        if multitouch.open() {
            locked { mtLastFrame = Clock.now() }
            print("Trackpad contact detection active (coast on flick, instant brake on touch; mice are unaffected).")
        } else {
            print("No trackpad contact detection -> coasting disabled.")
        }

        let mask = (CGEventMask(1) << CGEventType.mouseMoved.rawValue) | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly,   // we never block real movement
                                          eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
            print("Failed to create event tap. Grant Accessibility / Input Monitoring to Coast in System Settings, then relaunch.")
            return false
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        // Honor a persisted "off": the tap stays disabled until Coast is re-enabled from the menu.
        CGEvent.tapEnable(tap: tap, enable: settings.enabled)

        background("launcher") { self.launcherLoop() }
        background("watchdog") { self.watchdogLoop() }
        return true
    }

    /// Turning Coast off stops any coast in flight and disables the tap, so "off" costs nothing.
    func setEnabled(_ on: Bool) {
        settings.enabled = on
        if !on { cancel.set() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    private func background(_ name: String, _ body: @escaping () -> Void) {
        let t = Thread(block: body)
        t.name = "Coast \(name)"
        t.qualityOfService = .userInteractive
        t.start()
    }

    // MARK: Input

    /// Multitouch frame thread: just flips state.
    func contactFrame(fingers: Int) {
        let down = fingers > 0
        let was: Bool = locked {
            mtLastFrame = Clock.now()   // heartbeat: proves contact detection is still alive
            let w = fingersDown
            fingersDown = down
            return w
        }
        if down && !was {
            // A finger just landed: brake the coast this instant, and start a brand-new stroke so
            // the next flick's velocity is measured cleanly.
            cancel.set()
            resetStroke.set()
        } else if was && !down {
            lift.set()   // a finger just lifted: let the launcher consider a coast
        }
    }

    fileprivate func tapEvent(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disabled the tap: a callback timeout or (commonly) sleep/wake. Re-arm it so Coast
            // recovers without a restart, unless Coast was switched off.
            if let tap, settings.enabled { CGEvent.tapEnable(tap: tap, enable: true) }
        case .mouseMoved, .leftMouseDragged:
            guard event.getIntegerValueField(.eventSourceUserData) != Tune.syntheticTag else { return }  // our own move
            // Real movement during a coast means the user is touching: the fallback brake.
            if isCoasting { cancel.set() }
            let loc = event.location
            record(x: loc.x, y: loc.y,
                   dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY),
                   timestamp: event.timestamp)
        default:
            break
        }
    }

    private func record(x: Double, y: Double, dx: Double, dy: Double, timestamp: CGEventTimestamp) {
        let tp = Clock.now(), tw = Clock.wall()
        let (slept, wasIdle): (Bool, Bool) = locked {
            // A sleep/wake gap: the wall clock advances through sleep but the monotonic clock is frozen,
            // so the two diverge by about the sleep's length on the first event after wake. The
            // pre-sleep buffer is then dropped: otherwise the stale flick still looks fresh and
            // relaunches a coast from a pre-sleep position, and a cursor jump across the gap reads
            // as enormous motion.
            let slept = lastWallTime != 0 && (tw - lastWallTime) - (tp - lastEventTime) > 0.5
            let wasIdle = tp - lastEventTime > Tune.padActive
            if timestampScale == nil && timestamp > 0 {
                // First real event: a ratio near 1 means mach ticks; far above 1 means nanoseconds.
                let machNow = Double(mach_absolute_time())
                timestampScale = machNow > 0 && Double(timestamp) / machNow > 5 ? 1e-9 : Clock.machToSec
            }
            let te = timestamp > 0 ? Double(timestamp) * (timestampScale ?? 0) : tp
            if slept || resetStroke.isSet {
                // Fresh start (just woke, or a finger just touched down): nothing stale to average against.
                samples.removeAll()
                resetStroke.clear()
            }
            samples.append(Sample(x: x, y: y, dx: dx, dy: dy, eventTime: te, processedTime: tp, fingersDown: fingersDown))
            if samples.count > Tune.historyLen { samples.removeFirst() }
            lastEventTime = tp
            lastWallTime = tw
            return (slept, wasIdle)
        }
        // First event after an idle stretch: snap the launcher out of its slow idle tick.
        if wasIdle { lift.set() }
        if slept {
            cancel.set()
            rebuildRequest.set()   // multitouch is very likely dead after a sleep this long
            log("sleep/wake gap detected -> cleared motion buffer, cancelled coast")
        }
    }

    // MARK: Launching

    struct Flick { var vx, vy, age: Double; var touched, captured: Bool }

    /// Release velocity in px per frame, weighted to the most recent motion.
    ///
    /// `age` is how long ago the newest sample was (a flick the finger paused on before lifting is
    /// ignored). `touched` says the window's motion happened under trackpad contact: a majority vote,
    /// because the tap races the multitouch thread at the lift. `captured` means an app has grabbed
    /// the mouse (Moonlight, games with mouse-look): the on-screen position is pinned while the
    /// delta fields keep reporting motion, so the deltas become the velocity source.
    private func recentVelocity() -> Flick {
        let now = Clock.now()
        let pts = locked { samples }
        guard pts.count >= 2, let newest = pts.last else { return Flick(vx: 0, vy: 0, age: .infinity, touched: false, captured: false) }
        // Anchor the window to the newest sample so the speed at release dominates.
        var window = pts.filter { $0.eventTime >= newest.eventTime - Tune.velocityWindow }
        if window.count < 2 { window = Array(pts.suffix(2)) }
        let first = window[0], last = window[window.count - 1]
        let touched = window.filter(\.fingersDown).count * 2 >= window.count
        // Time the flick by the events' own clock; the larger of event-dt and processing-dt keeps a
        // burst of batched events from blowing the velocity up.
        let dt = max(last.eventTime - first.eventTime, last.processedTime - first.processedTime, 1e-4)
        var vx = (last.x - first.x) / dt * Tune.frameDT
        var vy = (last.y - first.y) / dt * Tune.frameDT
        // The same window's motion by the delta fields. The first sample's delta describes motion that
        // arrived before the window, so it is skipped, mirroring how positions are differenced.
        let rest = window.dropFirst()
        let dvx = rest.reduce(0) { $0 + $1.dx } / dt * Tune.frameDT
        let dvy = rest.reduce(0) { $0 + $1.dy } / dt * Tune.frameDT
        let posSpeed = hypot(vx, vy), deltaSpeed = hypot(dvx, dvy)
        // Normally the two agree (event deltas ARE the accelerated motion), so a pinned position
        // under real delta motion is the capture signature.
        let captured = deltaSpeed > Tune.captureMinDelta && posSpeed < Tune.capturePosRatio * deltaSpeed
        if captured { vx = dvx; vy = dvy }
        return Flick(vx: vx, vy: vy, age: now - newest.processedTime, touched: touched, captured: captured)
    }

    /// Whether a lift should start a coast, and with what velocity.
    ///
    /// Coasting is trackpad-only, and fresh multitouch frames are the ONLY launch authority: they
    /// prove the motion came from fingers on a trackpad and that those fingers just lifted. When
    /// frames are stale (dead after sleep, or an untouched pad while a mouse moves the cursor),
    /// nothing launches.
    private func shouldLaunch() -> Flick? {
        let (busy, mtLive, fingers): (Bool, Bool, Bool) = locked {
            (coasting, multitouch.active && Clock.now() - mtLastFrame < Tune.mtStale, fingersDown)
        }
        guard !busy, settings.enabled, mtLive, !fingers else { return nil }
        let f = recentVelocity()
        guard f.touched else { return nil }                    // motion with no trackpad contact: a mouse
        guard f.age <= Tune.staleSample else { return nil }    // finger paused before lifting
        let speed = hypot(f.vx, f.vy)
        guard speed >= settings.minLaunchSpeed, speed <= Tune.maxLaunchSpeed else { return nil }
        log("launch v=(\(Int(f.vx.rounded())),\(Int(f.vy.rounded()))) speed=\(Int(speed.rounded()))\(f.captured ? " captured" : "")")
        return f
    }

    /// Starts a coast when a finger lifts after a flick.
    private func launcherLoop() {
        while !isStopping {
            // Wake promptly on a lift; otherwise tick fast only while the pad is in use. The first
            // event after idle sets `lift`, so a flick out of idle gets full-rate polling at once.
            let active = Clock.now() - locked({ lastEventTime }) < Tune.padActive
            lift.wait(active ? Tune.launchPoll : Tune.idlePoll)
            lift.clear()
            guard let f = shouldLaunch() else { continue }
            let origin: CGPoint? = locked {
                guard samples.count >= 2, let last = samples.last, !coasting else { return nil }
                samples.removeAll()          // consume the flick so it can't relaunch later
                lastEventTime = Clock.now()
                coasting = true
                return CGPoint(x: last.x, y: last.y)
            }
            guard let origin else { continue }
            cancel.clear()
            let t = Thread { self.coast(from: origin, vx: f.vx, vy: f.vy, captured: f.captured) }
            t.name = "Coast glide"
            t.qualityOfService = .userInteractive
            t.start()
        }
    }

    // MARK: The glide

    /// Animates the glide; vx/vy are px per frame.
    ///
    /// Ticks are paced by absolute deadlines and each advances by the REAL time since the previous one.
    /// On the desktop that's invisible, but a capturing app (Moonlight) integrates the deltas the
    /// instant each event arrives while the stream encoder samples at a fixed rate, so irregular ticks
    /// put unequal motion into successive video frames. Real trackpad events are hardware-clocked
    /// metronomes; coast ticks have to be too.
    private func coast(from start: CGPoint, vx startVX: Double, vy startVY: Double, captured: Bool) {
        makeThreadRealtime()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Coasting the cursor")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            locked { coasting = false }
        }
        var x = Double(start.x), y = Double(start.y), vx = startVX, vy = startVY
        var carryX = 0.0, carryY = 0.0
        var frames = 1.0                 // the first tick advances one ideal frame
        var last = Clock.now()
        var deadline = last + Tune.frameDT
        var ticks: [Double] = []
        var seen: CGPoint?               // where the cursor really was last tick
        var pinnedX = 0, pinnedY = 0     // ticks an axis has been held by a screen edge
        defer {
            if !ticks.isEmpty {
                let mean = ticks.reduce(0, +) / Double(ticks.count)
                log(String(format: "coast ticks n=%d mean=%.2fms max=%.2fms captured=%@",
                           ticks.count, mean * 1e3, (ticks.max() ?? 0) * 1e3, captured ? "True" : "False"))
            }
        }
        while !isStopping && !cancel.isSet {
            if !captured, let cur = CGEvent(source: nil)?.location {
                // The window server keeps the cursor on a screen. An axis that stays put two ticks
                // running while the glide is still ahead of it is pressed against an edge: drop that
                // axis, so the glide slides along the edge or ends. Two ticks, so a move the window
                // server hasn't applied yet isn't mistaken for an edge.
                if let seen {
                    pinnedX = abs(cur.x - seen.x) < 0.5 && abs(x - cur.x) > 1 ? pinnedX + 1 : 0
                    pinnedY = abs(cur.y - seen.y) < 0.5 && abs(y - cur.y) > 1 ? pinnedY + 1 : 0
                    if pinnedX >= 2 { vx = 0; x = cur.x; carryX = 0 }
                    if pinnedY >= 2 { vy = 0; y = cur.y; carryY = 0 }
                }
                seen = cur
            }
            if hypot(vx, vy) < Tune.minSpeed { break }
            // Deltas are integer event fields; carry the fraction so a slow tail still trickles out.
            let fx = vx * frames + carryX, fy = vy * frames + carryY
            let dx = fx.rounded(), dy = fy.rounded()
            carryX = fx - dx; carryY = fy - dy
            // While captured the cursor is pinned: post AT the pin and let the deltas carry the motion.
            // If the capture is released mid-coast, the first real motion brakes the coast.
            if !captured { x += vx * frames; y += vy * frames }
            postMove(x: x, y: y, dx: Int64(dx), dy: Int64(dy))
            let decay = pow(settings.friction, frames)
            vx *= decay; vy *= decay
            if sleep(until: deadline) { break }
            let now = Clock.now()
            // Cap catch-up so a stall loses a little distance instead of one violent jump-frame.
            frames = min((now - last) / Tune.frameDT, 4)
            if debugLogging { ticks.append(now - last) }
            last = now
            deadline += Tune.frameDT
            if deadline <= now { deadline = now + Tune.frameDT }   // fell behind; restart the cadence
        }
    }

    /// Waits until `deadline` (monotonic seconds); true if the coast was cancelled. Waits on the
    /// cancel signal (so a landing finger interrupts at once), then lands the last couple of ms with
    /// mach_wait_until, which wakes on time where a condition wait overshoots under load.
    private func sleep(until deadline: Double) -> Bool {
        let remaining = deadline - Clock.now()
        if remaining > Tune.coarseWait, cancel.wait(remaining - Tune.coarseWait) { return true }
        if deadline > Clock.now() { mach_wait_until(UInt64(deadline / Clock.machToSec)) }
        return cancel.isSet
    }

    /// Current time in the unit real events use on this machine. Synthetic moves carry a live
    /// timestamp, as hardware events do, so a consumer pacing motion by event time never sees t=0.
    private func eventTimestamp() -> CGEventTimestamp {
        let ticks = mach_absolute_time()
        return locked { timestampScale } == 1e-9 ? CGEventTimestamp(Double(ticks) * Clock.machToSec * 1e9) : ticks
    }

    /// Moves the cursor by posting a tagged mouse-moved event from the zero-suppression source, so a
    /// finger landing mid-coast takes over instantly. dx/dy fill the relative-motion fields, which
    /// are all a mouse-capturing app reads; real hardware events carry both, so coast moves do too.
    private func postMove(x: Double, y: Double, dx: Int64, dy: Int64) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                               mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { return }
        ev.setIntegerValueField(.eventSourceUserData, value: Tune.syntheticTag)
        ev.timestamp = eventTimestamp()
        if dx != 0 || dy != 0 {
            ev.setIntegerValueField(.mouseEventDeltaX, value: dx)
            ev.setIntegerValueField(.mouseEventDeltaY, value: dy)
            // Unaccelerated ("raw") pointer movement; some capture code reads these instead.
            if let ux = CGEventField(rawValue: 170), let uy = CGEventField(rawValue: 171) {
                ev.setDoubleValueField(ux, value: Double(dx))
                ev.setDoubleValueField(uy, value: Double(dy))
            }
        }
        ev.post(tap: .cghidEventTap)
    }

    // MARK: Watchdog

    /// Safety net across sleep/wake: keeps the event tap enabled, and revives multitouch if it goes
    /// silent while the pointer is clearly in use (which otherwise persists until a restart).
    private func watchdogLoop() {
        while !isStopping {
            // Every couple of seconds, or at once when a sleep/wake gap was seen, so multitouch is
            // rebuilt on the FIRST post-wake stroke.
            let woke = rebuildRequest.wait(Tune.tapHealth)
            rebuildRequest.clear()
            if let tap, settings.enabled, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            guard multitouch.active else { continue }
            let now = Clock.now()
            // Dead-multitouch signature: real moves arriving but no contact frames. A MOUSE produces
            // this exact signature all day long, so silence alone only rebuilds when throttle-aged;
            // wake-signal rebuilds stay immediate.
            let silent: Bool = locked {
                let s = now - mtLastFrame > 1 && now - lastEventTime < Tune.tapHealth && now - lastSilentRebuild > Tune.mtSilentRebuild
                if s && !woke { lastSilentRebuild = now }
                return s
            }
            if woke || silent {
                log(woke ? "wake signal -> rebuilding multitouch" : "multitouch silent while pointer in use -> rebuilding it")
                multitouch.restart()
                // Measure silence from this attempt, so the watchdog retries soon if frames still don't come.
                locked { mtLastFrame = Clock.now() }
            }
        }
    }
}

/// The event tap's C callback (runs on the main run loop).
private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    Engine.shared.tapEvent(type, event)
    return Unmanaged.passUnretained(event)
}
