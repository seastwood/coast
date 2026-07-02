"""
Coast -- trackball-style cursor inertia for macOS trackpads, with a menu bar app.

Watches trackpad velocity, coasts the cursor after a flick with decaying
velocity, and brakes the coast THE INSTANT a finger touches the trackpad
again -- using the private MultitouchSupport framework for true finger-contact
detection (works even if the finger doesn't move).

The feel is modeled on a real trackball:
    * flick and lift  -> the ball keeps spinning, slowing under friction
    * touch the ball  -> it stops dead, immediately, wherever it is
    * the coast launches at your *release* speed, not an averaged speed
    * you can re-flick the instant you touch down -- no pause, no swallowed motion

The coast moves the cursor by POSTING mouse-moved events from an event source
whose local-events-suppression interval is zero. That is the crucial detail:
CGWarpMouseCursorPosition suppresses real hardware input for ~250ms after every
call, which froze the cursor (and ate the next flick) when you touched down to
re-flick mid-coast. Posting from a zero-suppression source never blocks the
hardware, so your finger always controls the cursor with no delay.

A menu bar icon lets you enable/disable the effect and tune the feel; settings
persist to ~/.coast.json.

Requires:
    pip install pyobjc-framework-Quartz pyobjc-framework-Cocoa

Permissions (macOS):
    System Settings -> Privacy & Security -> Accessibility   (add python binary)
    System Settings -> Privacy & Security -> Input Monitoring (add python binary)

Run directly in PyCharm. Quit from the menu bar, or Ctrl+C in the terminal.
"""

import os
import json
import time
import ctypes
import fcntl
import threading
import objc
import Quartz
# noinspection PyUnresolvedReferences
from Quartz import (
    CGEventTapCreate,
    kCGSessionEventTap,
    kCGHeadInsertEventTap,
    kCGEventTapOptionListenOnly,
    CGEventMaskBit,
    kCGEventMouseMoved,
    kCGEventLeftMouseDragged,
    kCGEventTapDisabledByTimeout,
    kCGEventTapDisabledByUserInput,
    CGEventTapIsEnabled,
    CFMachPortCreateRunLoopSource,
    CFRunLoopGetCurrent,
    CFRunLoopAddSource,
    kCFRunLoopCommonModes,
    CGEventGetLocation,
    CGEventGetTimestamp,
    CGEventCreateMouseEvent,
    CGEventPost,
    kCGHIDEventTap,
    kCGMouseButtonLeft,
    CGEventSourceCreate,
    kCGEventSourceStateHIDSystemState,
    CGEventSourceSetLocalEventsSuppressionInterval,
    CGEventSetIntegerValueField,
    CGEventGetIntegerValueField,
    kCGEventSourceUserData,
)
from Foundation import NSObject
# noinspection PyUnresolvedReferences
from AppKit import (
    NSApplication,
    NSApplicationActivationPolicyAccessory,
    NSStatusBar,
    NSVariableStatusItemLength,
    NSMenu,
    NSMenuItem,
    NSImage,
    NSImageSymbolConfiguration,
    NSBezierPath,
    NSColor,
)
from PyObjCTools import AppHelper

# ---- Fixed tunables ----
HISTORY_LEN = 10          # how many recent samples to keep for the velocity estimate
VELOCITY_WINDOW_S = 0.05  # estimate release velocity from motion in this final window
STALE_SAMPLE_S = 0.08     # if the last motion is older than this at lift, don't fling
STOP_GAP_S = 0.035        # (no-multitouch fallback) event silence that counts as a lift
LAUNCH_POLL_S = 0.010     # launcher wakeup cadence while the pad is in use
IDLE_POLL_S = 0.25        # launcher wakeup cadence once the pad has gone idle
PAD_ACTIVE_S = 0.5        # "pad in use" = a real move event within this window
MIN_SPEED = 2.0           # px/frame below which the coast ends
FRAME_DT = 1 / 120.0      # animation tick rate
TAP_HEALTH_S = 2.0        # how often to confirm the event tap is still enabled
MAX_LAUNCH_SPEED = 700.0  # px/frame ceiling; faster than any human flick -> treat as a
                          # glitch (e.g. a timing hiccup) and don't fling the cursor
MT_STALE_S = 0.25         # no multitouch frame within this while the pad is in use ->
                          # contact detection has gone silent (typically after sleep)

# ---- User-editable settings (live; changed from the menu bar) ----
APP_NAME = "Coast"
CONFIG_PATH = os.path.expanduser("~/.coast.json")
# Older config filenames, read once if the current one is missing so settings
# carry over after a rename.
LEGACY_CONFIG_PATHS = [os.path.expanduser("~/.trackball_inertia.json")]
LOCK_PATH = os.path.expanduser("~/.coast.lock")   # single-instance flock
DEFAULTS = {
    "enabled": True,
    "friction": 0.93,          # velocity *= this every frame (higher = longer glide)
    "min_launch_speed": 8.0,   # don't coast for flicks slower than this px/frame
}
SETTINGS = dict(DEFAULTS)

# Preset choices shown in the menu, as (label, value) in display order.
GLIDE_PRESETS = [("Short", 0.90), ("Medium", 0.93), ("Long", 0.965)]
SENS_PRESETS = [("Low", 14.0), ("Medium", 8.0), ("High", 4.0)]

# Menu bar glyph: a monochrome SF Symbol drawn as a TEMPLATE image, so the system
# tints it like every other menu bar icon (pure white on a dark/active bar). Swap
# for any installed symbol, e.g. "smallcircle.filled.circle", "circle.circle",
# "computermouse", "scope".
ICON_SYMBOL = "cursorarrow.motionlines"
ICON_POINT_SIZE = 16.0

# Marker stamped onto the synthetic moves we post during a coast, so our own
# event tap can tell them apart from real finger movement and ignore them.
_SYNTHETIC_TAG = 0x7242B411

_lock = threading.Lock()
_last_positions = []                 # list of (x, y, t)
_last_event_time = 0.0                # monotonic time of the last real event
_last_wall_time = 0.0                 # wall-clock time of the last real event (sleep-aware)
_coasting = False
_stop_requested = False
_fingers_down = False                 # current trackpad contact state (from multitouch)
_coast_cancel = threading.Event()    # set to brake the active coast immediately
_lift_event = threading.Event()      # set when a finger lifts, to wake the launcher
_reset_stroke = threading.Event()    # set on touch: the next sample starts a fresh stroke
_mt_rebuild_request = threading.Event()  # set on wake detection -> rebuild MT right away
_event_source = None                 # zero-suppression source used to post coast moves

# ---- Event-time clock --------------------------------------------------------
# Velocity MUST be timed by each event's own timestamp, not by when Python gets
# around to processing it. Under the Cocoa run loop the tap callback can be
# called in bursts, so several real events arrive back-to-back; timing those with
# the wall clock yields a near-zero dt and an explosive (bogus) velocity that
# flings the cursor across the screen. CGEventGetTimestamp gives the true time.
_libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
_libc.mach_absolute_time.restype = ctypes.c_uint64


class _MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def _mach_to_sec_factor():
    tb = _MachTimebase()
    _libc.mach_timebase_info(ctypes.byref(tb))
    return (tb.numer / tb.denom) * 1e-9 if tb.denom else 1e-9


MACH_TO_SEC = _mach_to_sec_factor()
# CGEventGetTimestamp's unit isn't guaranteed (mach ticks vs nanoseconds), so we
# detect it from the first real event by comparing to mach_absolute_time().
_ts_scale = None

# Kept alive at module scope so they aren't garbage collected.
_tap = None
_runloop_source = None
_status_item = None
_menu = None
_controller = None


def _now():
    return time.monotonic()


DEBUG = bool(os.environ.get("COAST_DEBUG"))
LOG_PATH = os.path.expanduser("~/.coast.log")


def _log(msg):
    """Append a line to ~/.coast.log when COAST_DEBUG=1; a no-op otherwise. Lets us
    diagnose post-sleep misbehavior in the field without attaching a terminal."""
    if not DEBUG:
        return
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


# ------------------------------------------------------------------------
# Settings persistence
# ------------------------------------------------------------------------
def load_settings():
    for path in [CONFIG_PATH] + LEGACY_CONFIG_PATHS:
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        for k in DEFAULTS:
            if k in data:
                SETTINGS[k] = data[k]
        if path != CONFIG_PATH:
            save_settings()  # migrate to the current filename
        return


def save_settings():
    try:
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(SETTINGS, f, indent=2)
        os.replace(tmp, CONFIG_PATH)   # atomic: a crash mid-write can't corrupt the file
    except OSError:
        pass


_instance_lock_file = None   # kept open for the process lifetime; the flock dies with us


def _acquire_single_instance_lock():
    """Refuse to run two Coasts at once (e.g. the installed app plus a dev run from
    source): both would post coast moves and brake each other's coasts. Holds an
    exclusive flock on LOCK_PATH; the kernel releases it when the process exits --
    even on a crash -- so there are no stale locks to clean up."""
    global _instance_lock_file
    try:
        _instance_lock_file = open(LOCK_PATH, "a")
    except OSError:
        return True   # can't create the lock file -> don't block startup over it
    try:
        fcntl.flock(_instance_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False  # another instance holds the lock
    try:
        _instance_lock_file.truncate(0)
        _instance_lock_file.write(str(os.getpid()))
        _instance_lock_file.flush()
    except OSError:
        pass
    return True


# ------------------------------------------------------------------------
# MultitouchSupport: detect actual finger contact for instant braking.
# We only read the finger COUNT argument, never the struct contents, so this
# is robust against the private Finger struct layout changing.
# ------------------------------------------------------------------------
_mt = None                # MultitouchSupport CDLL (kept so we can rebuild devices on wake)
_cf = None                # CoreFoundation CDLL
_mt_devices = []
_mt_callback_ref = None   # keep a ref so the ctypes callback isn't garbage-collected
_mt_active = False
_mt_last_frame = 0.0      # monotonic time of the last contact frame (freshness check)

# int callback(int device, void *data, int nFingers, double timestamp, int frame)
_MTContactCallback = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.c_int,
    ctypes.c_double,
    ctypes.c_int,
)


def _mt_contact(device, data, n_fingers, timestamp, frame):
    """Runs on the multitouch frame thread; keep it tiny -- just flip state."""
    global _fingers_down, _mt_last_frame
    _mt_last_frame = _now()   # heartbeat: proves contact detection is still alive
    down = n_fingers > 0
    if down and not _fingers_down:
        # A finger just landed -> brake the coast this instant, and start a
        # brand-new stroke so the next flick's velocity is measured cleanly.
        _coast_cancel.set()
        _reset_stroke.set()
    elif _fingers_down and not down:
        # A finger just lifted -> let the launcher consider a coast.
        _lift_event.set()
    _fingers_down = down
    return 0


def _mt_open_devices():
    """Create, register, and start a FRESH set of MultitouchSupport devices.

    Building a new device list each time is what makes post-sleep recovery work:
    after a long sleep the framework tears the old device objects down, and
    MTDeviceStart on a stale handle silently delivers no frames -- only devices
    from a newly created list come back to life. Used by both init and restart.
    """
    devices = []
    device_list = _mt.MTDeviceCreateList()
    if not device_list:
        return devices
    count = _cf.CFArrayGetCount(device_list)
    for i in range(count):
        device = _cf.CFArrayGetValueAtIndex(device_list, i)
        if device:
            _mt.MTRegisterContactFrameCallback(device, _mt_callback_ref)
            _mt.MTDeviceStart(device, 0)
            devices.append((_mt, device))
    return devices


def _init_multitouch():
    global _mt, _cf, _mt_devices, _mt_active, _mt_callback_ref, _mt_last_frame
    try:
        _mt = ctypes.CDLL(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        )
        _cf = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )

        _mt.MTDeviceCreateList.restype = ctypes.c_void_p
        _cf.CFArrayGetCount.restype = ctypes.c_long
        _cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        _cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        _cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        _mt.MTRegisterContactFrameCallback.argtypes = [ctypes.c_void_p, _MTContactCallback]
        _mt.MTDeviceStart.argtypes = [ctypes.c_void_p, ctypes.c_int]
        _mt.MTDeviceStop.argtypes = [ctypes.c_void_p]

        _mt_callback_ref = _MTContactCallback(_mt_contact)

        _mt_devices = _mt_open_devices()
        _mt_active = len(_mt_devices) > 0
        _mt_last_frame = _now()
        return _mt_active
    except Exception as e:
        print(f"MultitouchSupport unavailable ({e}); "
              f"falling back to movement-based cancel only.")
        return False


def _restart_multitouch():
    """Rebuild MultitouchSupport after it stops delivering contact frames (notably
    across a long lid-closed sleep). Stopping and re-starting the SAME device
    handles is NOT enough -- after a deep sleep those objects are dead and deliver
    nothing -- so we drop them and create a brand-new device list. Reviving this is
    what restores brake-on-touch: a finger placed down WITHOUT moving is seen only
    by MultitouchSupport, so while it's dead a coast won't stop on contact and
    _should_launch is left on its movement-gap fallback."""
    global _mt_devices, _mt_last_frame
    if not _mt_active:
        return
    for lib, device in _mt_devices:
        try:
            lib.MTDeviceStop(device)   # a no-op if the handle is already dead
        except Exception:
            pass
    _mt_devices = []
    time.sleep(0.05)
    _mt_devices = _mt_open_devices()   # fresh handles bound to the revived service
    # Measure silence from this attempt, not the ancient pre-sleep frame, so the
    # watchdog retries in ~TAP_HEALTH_S if frames still don't come.
    _mt_last_frame = _now()
    _log(f"rebuilt multitouch -> {len(_mt_devices)} device(s)")


def _record_position(x, y, ts):
    """Record a real cursor sample as (x, y, event_time_s, processing_time_s)."""
    global _last_event_time, _last_wall_time, _ts_scale
    tp = _now()
    tw = time.time()
    # Detect a sleep/wake gap: the wall clock advances through sleep but the
    # monotonic clock (tp) is frozen while asleep, so the two diverge by roughly
    # the sleep duration on the first event after wake. When that happens, discard
    # the pre-sleep buffer -- otherwise the stale flick still looks "fresh" to the
    # monotonic-based staleness check and relaunches a coast from a pre-sleep
    # position (the cursor teleporting and flying off), and a cursor-coordinate
    # jump across the gap reads as enormous motion. Also brake a coast frozen
    # mid-flight when we slept.
    slept = bool(_last_wall_time) and (tw - _last_wall_time) - (tp - _last_event_time) > 0.5
    was_idle = (tp - _last_event_time) > PAD_ACTIVE_S   # pad returning from idle?
    if _ts_scale is None and ts > 0:
        # First real event: ratio ~1 means ts is mach ticks; ratio >> 1 means ns.
        mach_now = _libc.mach_absolute_time()
        _ts_scale = 1e-9 if (mach_now and ts / mach_now > 5) else MACH_TO_SEC
    te = ts * _ts_scale if (_ts_scale and ts > 0) else tp
    with _lock:
        if slept or _reset_stroke.is_set():
            # Fresh start (just woke, or a finger just touched down): drop anything
            # left over so this flick can't be averaged against stale samples.
            _last_positions.clear()
            _reset_stroke.clear()
        _last_positions.append((x, y, te, tp))
        if len(_last_positions) > HISTORY_LEN:
            _last_positions.pop(0)
        _last_event_time = tp
        _last_wall_time = tw
    if was_idle:
        # First event after an idle stretch: snap the launcher out of its slow idle
        # tick so even an immediate quick flick gets full-rate fallback polling.
        _lift_event.set()
    if slept:
        _coast_cancel.set()
        # Ask the watchdog to rebuild MultitouchSupport NOW -- it is very likely
        # dead after a sleep this long, and waiting for the next periodic tick
        # leaves brake-on-touch broken for the first post-wake interaction.
        # Event.set() is non-blocking, so this is safe on the event-tap thread.
        _mt_rebuild_request.set()
        _log("sleep/wake gap detected -> cleared motion buffer, cancelled coast")


def _clear_history():
    """Drop buffered samples so a finished coast can't be relaunched from stale data."""
    global _last_event_time
    with _lock:
        _last_positions.clear()
        _last_event_time = _now()


def _recent_velocity():
    """Release velocity in px per FRAME_DT, weighted to the most recent motion.

    Returns (vx, vy, age_s) where age_s is how long ago the newest sample was --
    used to ignore a flick that the finger paused on before lifting.
    """
    now = _now()
    with _lock:
        pts = list(_last_positions)
    if len(pts) < 2:
        return 0.0, 0.0, float("inf")

    te_new = pts[-1][2]
    tp_new = pts[-1][3]
    # Anchor the window to the *newest* sample so the speed at release dominates,
    # rather than averaging in the slower start of the stroke.
    window = [p for p in pts if p[2] >= te_new - VELOCITY_WINDOW_S]
    if len(window) < 2:
        window = pts[-2:]

    x0, y0, te0, tp0 = window[0]
    x1, y1, te1, tp1 = window[-1]
    # Time the flick by the events' own clock. Fall back to the larger of
    # event-dt and processing-dt so a burst of batched events (tiny processing-dt)
    # can never blow the velocity up; floor it to avoid divide-by-zero.
    dt = max(te1 - te0, tp1 - tp0, 1e-4)
    vx = (x1 - x0) / dt * FRAME_DT
    vy = (y1 - y0) / dt * FRAME_DT
    return vx, vy, now - tp_new


def _post_move(x, y):
    """Move the cursor by posting a synthetic, tagged mouse-moved event.

    Unlike CGWarpMouseCursorPosition, a move posted from our zero-suppression
    source never blocks real hardware input, so a finger landing mid-coast takes
    over instantly. The tag lets _tap_callback ignore this as our own event.
    """
    ev = CGEventCreateMouseEvent(_event_source, kCGEventMouseMoved, (x, y), kCGMouseButtonLeft)
    CGEventSetIntegerValueField(ev, kCGEventSourceUserData, _SYNTHETIC_TAG)
    CGEventPost(kCGHIDEventTap, ev)


def _coast(start_x, start_y, vx, vy):
    global _coasting
    x, y = start_x, start_y
    try:
        while not (_stop_requested or _coast_cancel.is_set()):
            speed = (vx * vx + vy * vy) ** 0.5
            if speed < MIN_SPEED:
                break
            x += vx
            y += vy
            _post_move(x, y)
            friction = SETTINGS["friction"]
            vx *= friction
            vy *= friction
            # Sleep one frame, but wake the INSTANT a finger lands (cancel is set
            # from the multitouch thread), so the brake feels immediate.
            if _coast_cancel.wait(FRAME_DT):
                break
    except Exception as e:
        _log(f"coast error: {e!r}")   # end this coast; never kill future ones
    finally:
        _coasting = False


def _should_launch():
    """Decide whether a lift should start a coast, and with what velocity.

    Returns (vx, vy) to launch, or None.
    """
    if _coasting or not SETTINGS["enabled"]:
        return None

    # Trust multitouch contact only while its frames are fresh. After sleep/wake it
    # can go silent, freezing `_fingers_down` at False; if we kept trusting it we'd
    # fire coasts *during* ordinary movement (the runaway sensitivity). When it's
    # stale, fall back to inferring a lift from a pause in real movement instead.
    mt_live = _mt_active and (_now() - _mt_last_frame) < MT_STALE_S
    if mt_live:
        # Authoritative contact info: never coast while a finger is on the pad.
        if _fingers_down:
            return None
    else:
        # No usable contact info: infer a lift from a pause in real movement events,
        # so we never launch while the finger is still sweeping across the pad.
        with _lock:
            gap = _now() - _last_event_time
            have = len(_last_positions) >= 2
        if not have or gap < STOP_GAP_S:
            return None

    vx, vy, age = _recent_velocity()
    if age > STALE_SAMPLE_S:
        return None  # finger paused before lifting -> no fling
    speed = (vx * vx + vy * vy) ** 0.5
    if speed < SETTINGS["min_launch_speed"] or speed > MAX_LAUNCH_SPEED:
        return None  # too slow to bother, or a glitch reading -> don't fling
    _log(f"launch v=({vx:.0f},{vy:.0f}) speed={speed:.0f} mt_live={mt_live} fingers={_fingers_down}")
    return vx, vy


def _launcher():
    """Starts a coast when a finger lifts after a flick."""
    global _coasting
    while not _stop_requested:
        try:
            # Wake promptly on a lift (multitouch), otherwise poll for the fallback
            # path -- fast only while the pad is in use. Once the pad goes idle, back
            # off to a slow tick: the first real event after idle sets _lift_event
            # (see _record_position), so a flick out of idle still gets full-rate
            # polling from its very first sample.
            active = (_now() - _last_event_time) < PAD_ACTIVE_S
            _lift_event.wait(LAUNCH_POLL_S if active else IDLE_POLL_S)
            _lift_event.clear()

            launch = _should_launch()
            if launch is None:
                continue
            vx, vy = launch  # already bounded to MAX_LAUNCH_SPEED by _should_launch

            with _lock:
                if len(_last_positions) < 2:
                    continue
                x, y, _, _ = _last_positions[-1]

            _clear_history()       # consume the flick so it can't relaunch later
            _coast_cancel.clear()
            _coasting = True
            threading.Thread(target=_coast, args=(x, y, vx, vy), daemon=True).start()
        except Exception as e:
            # A surprise here would otherwise kill this thread -- and with it all
            # coasting -- until relaunch. Log and keep serving.
            _log(f"launcher error: {e!r}")
            time.sleep(0.1)


def _tap_callback(proxy, event_type, event, refcon):
    try:
        if event_type in (kCGEventTapDisabledByTimeout, kCGEventTapDisabledByUserInput):
            # macOS disabled our tap -- a callback timeout, or (the common case) the
            # machine slept and woke. Re-arm it so Coast recovers without a restart
            # (unless the user switched Coast off, in which case off means off).
            if _tap is not None and SETTINGS["enabled"]:
                Quartz.CGEventTapEnable(_tap, True)
        elif event_type in (kCGEventMouseMoved, kCGEventLeftMouseDragged):
            if CGEventGetIntegerValueField(event, kCGEventSourceUserData) != _SYNTHETIC_TAG:
                # Real finger movement (not our own coast move). Fallback brake, used
                # if MultitouchSupport isn't active: any real event during a coast
                # means the user is touching.
                if _coasting:
                    _coast_cancel.set()
                loc = CGEventGetLocation(event)
                _record_position(loc.x, loc.y, CGEventGetTimestamp(event))
    except Exception as e:
        _log(f"tap callback error: {e!r}")   # never let one bad event break the tap
    return event


def _tap_watchdog():
    """Safety net across sleep/wake: keep the event tap enabled, and revive
    MultitouchSupport if it goes silent while the trackpad is clearly in use (real
    move events arriving but no contact frames) -- which otherwise persists until
    Coast is restarted. Launch gating already degrades safely when frames are
    stale; this just restores the instant brake-on-touch."""
    while not _stop_requested:
        try:
            # Tick every TAP_HEALTH_S -- or instantly when _record_position detects a
            # sleep/wake gap, so MT is rebuilt on the FIRST post-wake stroke instead of
            # up to a full tick later (a still finger placed mid-coast brakes right away).
            woke = _mt_rebuild_request.wait(TAP_HEALTH_S)
            _mt_rebuild_request.clear()
            # Respect the menu toggle: while Coast is off the tap is deliberately
            # disabled; re-arming it here would undo that.
            if _tap is not None and SETTINGS["enabled"] and not CGEventTapIsEnabled(_tap):
                Quartz.CGEventTapEnable(_tap, True)
            if _mt_active:
                now = _now()
                # Dead-MT signature: real move events keep arriving (pad in use) but no
                # contact frames -- brake-on-touch stays broken until we rebuild MT. Use
                # a full health-check interval as the "recently used" window so activity
                # that lands between ticks still triggers recovery.
                if woke or (now - _mt_last_frame > 1.0 and now - _last_event_time < TAP_HEALTH_S):
                    _log("wake signal -> rebuilding multitouch" if woke
                         else "multitouch silent while pad in use -> rebuilding it")
                    _restart_multitouch()
        except Exception as e:
            # The watchdog IS the recovery path; if it died, sleep/wake recovery
            # would die with it. Log and keep ticking.
            _log(f"watchdog error: {e!r}")
            time.sleep(TAP_HEALTH_S)


# ------------------------------------------------------------------------
# Menu bar app
# ------------------------------------------------------------------------
def _draw_fallback_icon():
    """A simple trackball glyph (ring + dot) as a template image, in case the SF
    Symbol is unavailable. Template images are masked by alpha, so we draw black."""
    size = 18.0
    inset = 2.0
    img = NSImage.alloc().initWithSize_((size, size))
    img.lockFocus()
    NSColor.blackColor().set()
    ring = NSBezierPath.bezierPathWithOvalInRect_(
        ((inset, inset), (size - 2 * inset, size - 2 * inset)))
    ring.setLineWidth_(1.6)
    ring.stroke()
    d = 4.0
    NSBezierPath.bezierPathWithOvalInRect_(
        ((size / 2 - d / 2, size / 2 - d / 2), (d, d))).fill()
    img.unlockFocus()
    img.setTemplate_(True)
    return img


def _make_icon():
    """Build the pure-white menu bar icon (a template image)."""
    img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(
        ICON_SYMBOL, APP_NAME)
    if img is None:
        return _draw_fallback_icon()
    try:
        cfg = NSImageSymbolConfiguration.configurationWithPointSize_weight_(ICON_POINT_SIZE, 0.0)
        sized = img.imageWithSymbolConfiguration_(cfg)
        if sized is not None:
            img = sized
    except Exception:
        pass
    img.setTemplate_(True)  # render monochrome, tinted like native icons
    return img


def _make_submenu(controller, action, presets):
    """Build a submenu of preset choices; returns (NSMenu, items, {label: value})."""
    submenu = NSMenu.alloc().init()
    items = []
    values = {}
    for label, value in presets:
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(label, action, "")
        item.setTarget_(controller)
        submenu.addItem_(item)
        items.append(item)
        values[label] = value
    return submenu, items, values


def _build_menu(controller):
    menu = NSMenu.alloc().init()

    header = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(APP_NAME, None, "")
    header.setEnabled_(False)
    menu.addItem_(header)
    menu.addItem_(NSMenuItem.separatorItem())

    enabled_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        "Enabled", "toggleEnabled:", "")
    enabled_item.setTarget_(controller)
    controller.enabled_item = enabled_item
    menu.addItem_(enabled_item)

    menu.addItem_(NSMenuItem.separatorItem())

    groups = []
    for base, action, presets, key in (
        ("Glide", "pickGlide:", GLIDE_PRESETS, "friction"),
        ("Flick sensitivity", "pickSensitivity:", SENS_PRESETS, "min_launch_speed"),
    ):
        submenu, items, values = _make_submenu(controller, action, presets)
        parent = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(base, None, "")
        parent.setSubmenu_(submenu)
        menu.addItem_(parent)
        groups.append({"base": base, "key": key, "parent": parent,
                       "items": items, "values": values})
    controller.groups = groups

    menu.addItem_(NSMenuItem.separatorItem())

    quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Quit", "doQuit:", "q")
    quit_item.setTarget_(controller)
    menu.addItem_(quit_item)

    return menu


class MenuController(NSObject):
    """Receives menu actions and keeps the menu's checkmarks in sync."""

    def toggleEnabled_(self, sender):
        SETTINGS["enabled"] = not SETTINGS["enabled"]
        if not SETTINGS["enabled"]:
            _coast_cancel.set()   # stop any coast in flight when turning off
        # Gate the event tap with the toggle. While off, the tap would otherwise
        # still wake Python for every mouse move on the system; disabling it makes
        # "off" genuinely free. The watchdog and tap callback both respect this.
        if _tap is not None:
            Quartz.CGEventTapEnable(_tap, bool(SETTINGS["enabled"]))
        save_settings()
        self.refresh()

    def pickGlide_(self, sender):
        self._apply("friction", sender)

    def pickSensitivity_(self, sender):
        self._apply("min_launch_speed", sender)

    @objc.python_method
    def _apply(self, key, sender):
        for g in self.groups:
            if g["key"] == key:
                SETTINGS[key] = g["values"][sender.title()]
                break
        save_settings()
        self.refresh()

    def doQuit_(self, sender):
        global _stop_requested
        _stop_requested = True
        _coast_cancel.set()
        NSApplication.sharedApplication().terminate_(None)

    @objc.python_method
    def refresh(self):
        on = bool(SETTINGS["enabled"])
        self.enabled_item.setState_(1 if on else 0)
        if getattr(self, "status_button", None) is not None:
            self.status_button.setAlphaValue_(1.0 if on else 0.35)
        for g in self.groups:
            cur = SETTINGS[g["key"]]
            chosen = None
            for item in g["items"]:
                match = abs(g["values"][item.title()] - cur) < 1e-9
                item.setState_(1 if match else 0)
                if match:
                    chosen = item.title()
            g["parent"].setTitle_(g["base"] if chosen is None else f'{g["base"]}: {chosen}')


def _start_input_pipeline():
    """Set up the event source, multitouch, and event tap. Returns True on success."""
    global _event_source, _tap, _runloop_source

    _event_source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
    if _event_source is not None:
        # Turn OFF post-event hardware suppression so a returning finger is never
        # ignored. This is what makes re-flicking instant.
        CGEventSourceSetLocalEventsSuppressionInterval(_event_source, 0.0)

    if _init_multitouch():
        print("Finger-contact detection active (instant brake on touch).")
    else:
        print("Using movement-based cancel.")

    mask = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDragged)
    _tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,  # listen-only: we don't block real movement
        mask,
        _tap_callback,
        None,
    )
    if _tap is None:
        print("Failed to create event tap. Grant Accessibility / Input Monitoring "
              "to this Python interpreter in System Settings, then relaunch.")
        return False

    _runloop_source = CFMachPortCreateRunLoopSource(None, _tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _runloop_source, kCFRunLoopCommonModes)
    # Honor a persisted "off" from last session: leave the tap disabled until the
    # user re-enables Coast from the menu.
    Quartz.CGEventTapEnable(_tap, bool(SETTINGS["enabled"]))

    threading.Thread(target=_launcher, daemon=True).start()
    threading.Thread(target=_tap_watchdog, daemon=True).start()
    return True


def main():
    global _status_item, _menu, _controller

    if not _acquire_single_instance_lock():
        print(f"{APP_NAME} is already running; exiting this instance.")
        return

    load_settings()

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)  # menu bar only, no Dock icon

    ok = _start_input_pipeline()

    _controller = MenuController.alloc().init()
    _status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSVariableStatusItemLength)
    button = _status_item.button()
    button.setImage_(_make_icon())
    button.setToolTip_(APP_NAME if ok else f"{APP_NAME} (no input permission)")
    _controller.status_button = button
    _menu = _build_menu(_controller)
    _status_item.setMenu_(_menu)
    _controller.refresh()

    smoke = os.environ.get("COAST_SMOKE_SECONDS")
    if smoke:
        # Test hook: boot normally, then self-exit. Used to verify a packaged
        # build launches without missing dependencies. No effect in normal use.
        threading.Thread(
            target=lambda: (time.sleep(float(smoke)), os._exit(0)), daemon=True).start()

    print(f"{APP_NAME} running in the menu bar. Quit from the icon, or Ctrl+C here.")
    AppHelper.runEventLoop(installInterrupt=True)


if __name__ == "__main__":
    main()
