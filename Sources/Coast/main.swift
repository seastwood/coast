// Coast: trackball-style cursor inertia for macOS trackpads, with a menu bar app.
//
// Watches trackpad velocity, coasts the cursor after a flick with decaying velocity, and brakes the
// coast THE INSTANT a finger touches the trackpad again, using the private MultitouchSupport
// framework for true finger-contact detection (works even if the finger doesn't move).
//
//   * flick and lift  -> the ball keeps spinning, slowing under friction
//   * touch the ball  -> it stops dead, immediately, wherever it is
//   * the coast launches at your *release* speed, not an averaged speed
//   * you can re-flick the instant you touch down: no pause, no swallowed motion
//
// The effect is trackpad-only: a coast launches only when MultitouchSupport saw the motion happen
// under real finger contact and then saw the fingers lift, so a mouse never coasts (a Magic Mouse,
// itself a multitouch device, is excluded by its device family). It also carries through mouse
// CAPTURE (Moonlight, games with mouse-look): Coast recognises deltas flowing while the position
// stays pinned, measures the flick from the deltas, and delivers the glide as deltas too.
//
// Permissions: System Settings -> Privacy & Security -> Accessibility and Input Monitoring.
// Settings persist to ~/.coast.json; COAST_DEBUG=1 logs to ~/.coast.log.
import AppKit

guard acquireSingleInstanceLock() else {
    print("\(appName) is already running; exiting this instance.")
    exit(0)
}

Settings.shared.load()

// A menu bar app with no visible windows is a prime App Nap target: while a full-screen game or
// stream has the screen, macOS coalesces its timers and lowers its priority, and coast ticks land
// late and bunched. Held for the process lifetime.
let appActivity = ProcessInfo.processInfo.beginActivity(
    options: .userInitiatedAllowingIdleSystemSleep, reason: "Coast animates the cursor after a flick")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

let inputOK = Engine.shared.start()
let menuBar = MenuBar(inputOK: inputOK)

if let smoke = ProcessInfo.processInfo.environment["COAST_SMOKE_SECONDS"].flatMap(Double.init) {
    // Test hook: boot normally, then exit. Verifies a packaged build launches. No effect in normal use.
    DispatchQueue.global().asyncAfter(deadline: .now() + smoke) { exit(0) }
}

print("\(appName) running in the menu bar. Quit from the icon, or Ctrl+C here.")
app.run()
