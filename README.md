<p align="center">
  <img src="assets/coast-icon.png" width="140" alt="Coast icon">
</p>

<h1 align="center">Coast</h1>

<p align="center">
  <b>Trackball-style cursor inertia for macOS trackpads.</b><br>
  Flick and lift — the pointer keeps gliding. Touch the trackpad — it stops dead.
</p>



---

Coast lives in your menu bar and gives a trackpad the feel of a real trackball. Give the
cursor a flick and it coasts across the screen with momentum, slowing under friction; the
instant you touch the trackpad again it stops exactly where your finger lands. Throw it
again right away and it just works — no pause, no swallowed motion.

## Features

- **Momentum** — a quick flick sends the cursor coasting, decaying smoothly under friction.
- **Instant stop** — touching the trackpad brakes the coast the moment your finger makes
  contact (true finger-contact detection via the private MultitouchSupport framework),
  even if you don't move.
- **Re-flick freely** — throw the cursor again the instant you touch down; nothing is
  delayed or swallowed.
- **Release-speed accurate** — the coast launches at the speed of your flick, not an
  average, so it feels like a real throw.
- **Trackpads only** — coasting requires real finger contact, so mice are never affected.
  A Magic Mouse counts as a mouse, not a trackpad.
- **Works through mouse capture** — when an app grabs the mouse and reads relative motion
  (game streaming / remote desktop clients like Moonlight, games with mouse-look), Coast
  detects the capture and delivers the glide as relative deltas, so the remote cursor
  coasts too.
- **Smooth under load** — Coast opts out of App Nap and runs each glide on a real-time
  thread, so the coast stays smooth while a game or stream keeps the Mac busy.
- **Menu bar controls** — toggle on/off and tune the feel; settings persist to `~/.coast.json`.
- **Survives sleep/wake** — re-arms its event tap automatically if macOS disables it, so it
  keeps working after your laptop wakes.
- **Smooth during games and streams** — the glide runs in a small engine process that macOS Game
  Mode doesn't throttle, so it stays smooth even with a full-screen game or stream in front.
- **Update notice** — Coast checks GitHub for a new release about once a day and offers it in the menu.
- **Native look** — a pure-white template icon in the menu bar, no Dock icon.

## Install

1. Download **`Coast.dmg`** from the [Releases](https://github.com/seastwood/coast/releases)
   page (a universal app: Apple Silicon and Intel, macOS 12 or later).
2. Open it and drag **Coast** onto **Applications**.
3. First launch — Coast is self-signed (not notarized by Apple), so macOS blocks it once:
   - Double-click **Coast**. When macOS says it *"can't verify it's free of malware,"* click **Done**.
   - Open **System Settings → Privacy & Security**, scroll to the **Security** section, and click
     **Open Anyway** next to the note about Coast, then confirm and authenticate.

   (The old right-click → Open shortcut no longer works on macOS 15+.)
4. Grant permissions in **System Settings → Privacy & Security**:
   - **Accessibility**
   - **Input Monitoring**

   Then quit Coast from the menu bar and relaunch.

The white motion-cursor icon appears in the menu bar.

> **Why two permissions?** Coast watches trackpad movement to measure your flicks (Input
> Monitoring) and moves the cursor to animate the coast (Accessibility). It doesn't log or
> transmit anything — everything stays on your Mac.

## Usage

Click the menu bar icon:

| Menu item | What it does |
| --- | --- |
| **Enabled** | Turn the effect on or off. |
| **Glide** | Slider: how far the cursor coasts, from Short to Long (default 60%). |
| **Flick sensitivity** | Slider: how gentle a flick still starts a coast, from Low to High (default 70%). |

Your choices are saved to `~/.coast.json` and restored on launch.

## Build from source

Coast is a native Swift app with no dependencies. Requires macOS 12+ and Xcode or the
Command Line Tools (Swift 5.9+).

```bash
git clone https://github.com/seastwood/coast.git
cd coast

# Run directly during development (debug logging to ~/.coast.log):
COAST_DEBUG=1 swift run
```

Running unbundled, macOS asks for the permissions for your terminal instead of Coast.

### Package a `.dmg`

```bash
# One-time: create a stable self-signed code-signing identity, so macOS keeps your
# Accessibility / Input Monitoring grants across rebuilds instead of resetting them.
./make_cert.sh

# Build Coast.app and package Coast.dmg (app, volume, and file icons applied).
./build_dmg.sh
```

## How it works

- A **`CGEventTap`** watches trackpad movement and estimates your release velocity, timed by
  each event's own hardware timestamp so it stays accurate even when the UI thread is busy.
- The coast is animated by **posting mouse-moved events** from an event source with
  input-suppression disabled, so the cursor is never decoupled from your hand — a returning
  finger takes over instantly.
- **MultitouchSupport** reports finger contact directly, so the coast brakes on touch even
  if the finger doesn't move.
- A small watchdog **re-enables the event tap** whenever macOS disables it (notably across
  sleep/wake).


## Project layout

| File | Purpose |
| --- | --- |
| `Sources/Coast/Engine.swift` | The inertia engine: flick measurement, launch rules, the real-time glide, sleep/wake recovery. |
| `Sources/Coast/Multitouch.swift` | Finger-contact detection via the private MultitouchSupport framework. |
| `Sources/Coast/MenuBar.swift` | The menu bar icon and menu. |
| `Sources/Coast/EngineProcess.swift` | Runs the engine as its own process (out of Game Mode's reach) and talks to it. |
| `Sources/Coast/UpdateChecker.swift` | The daily check for a new release. |
| `Sources/Coast/Support.swift` | Tunables, settings, clocks, logging, single-instance lock. |
| `Tools/make_icon.swift` | Generates `Coast.icns` from an SF Symbol. |
| `Tools/set_icon.swift` | Applies an icon to a file or mounted volume (used by the dmg build). |
| `VERSION` | The version shown in the menu and stamped into the app. |
| `make_cert.sh` | Creates the stable self-signed signing identity. |
| `build_dmg.sh` | Builds the universal `Coast.app` and packages `Coast.dmg`. |

<p align="center">
  <a href="https://buymeacoffee.com/eastwoodsee"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="40" alt="Buy Me A Coffee"></a>
</p>

## License

[MIT](LICENSE) © 2026 Seth Eastwood
