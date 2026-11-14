import AppKit

// Coast runs as two processes from the same executable.
//
//   * The menu bar app (no arguments): the icon, the menu, the settings file, the single-instance lock.
//   * The engine (`--engine`), started by the app: the event tap, multitouch contact detection, the
//     launcher and the glide.
//
// The split is for macOS Game Mode. While a game (or a Nokcandu stream) is full screen, Game Mode
// throttles every other *app*, real-time threads included: coast ticks then land ~100 ms apart instead
// of 8.3 ms, a glide stepping ten times a second. A plain process the app starts is not an app and is
// left alone, so everything time-critical lives there. The engine brakes on touch itself, so braking
// stays instant too. It inherits Coast's Accessibility and Input Monitoring permissions as its child.
//
// The app sends one line per change on the engine's stdin: "enabled 0|1", "friction <x>",
// "minspeed <x>". The engine answers "ready 1" (input OK) or "ready 0" (no input permission) once.
// It exits when its stdin closes, so it never outlives the app.

/// Engine process entry point. Never returns.
func runEngineProcess() -> Never {
    signal(SIGPIPE, SIG_IGN)
    Settings.shared.persist = false
    Settings.shared.load()
    // Not an app, so not an App Nap target either, but this keeps its timers precise all the same.
    let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Coast animates the cursor after a flick")
    let ok = Engine.shared.start()
    log("engine process \(getpid()) started (parent \(getppid()))")
    print(ok ? "ready 1" : "ready 0")
    fflush(stdout)

    let reader = Thread {
        while let line = readLine() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            DispatchQueue.main.async {
                switch parts[0] {
                case "enabled": Engine.shared.setEnabled(value == "1")
                case "friction": if let v = Double(value) { Settings.shared.friction = v }
                case "minspeed": if let v = Double(value) { Settings.shared.minLaunchSpeed = v }
                default: break
                }
            }
        }
        // The app quit or crashed: go with it.
        Engine.shared.stop()
        exit(0)
    }
    reader.name = "Coast engine stdin"
    reader.start()
    withExtendedLifetime(activity) { CFRunLoopRun() }
    exit(0)
}

/// The app's handle on the engine process: starts it, restarts it if it dies, sends it settings.
final class EngineHost {
    /// Called on the main thread with the engine's input permission state.
    var onStatus: ((Bool) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var stopping = false
    private var restarts: [Date] = []

    func start() {
        signal(SIGPIPE, SIG_IGN)   // writing to an engine that just died must not kill the app
        launch()
    }

    private func launch() {
        guard !stopping, let exe = Bundle.main.executablePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--engine"]
        let toEngine = Pipe(), fromEngine = Pipe()
        p.standardInput = toEngine
        p.standardOutput = fromEngine
        fromEngine.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if line == "ready 1" || line == "ready 0" {
                    let ok = line == "ready 1"
                    DispatchQueue.main.async { self?.onStatus?(ok) }
                } else {
                    print(line)   // the engine's own console messages
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.engineExited(status: proc.terminationStatus) }
        }
        do {
            try p.run()
        } catch {
            log("could not start the engine: \(error)")
            return
        }
        process = p
        input = toEngine.fileHandleForWriting
        log("started engine process \(p.processIdentifier)")
        sendSettings()
    }

    private func engineExited(status: Int32) {
        input = nil
        process = nil
        guard !stopping else { return }
        // Restart it, backing off if it keeps dying so a crash loop can't spin.
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        let delay = restarts.count > 3 ? 10.0 : 0.5
        log("engine exited (\(status)); restarting in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }

    /// Sends the current settings (after any change, and to a freshly started engine).
    func sendSettings() {
        let s = Settings.shared
        send("enabled \(s.enabled ? 1 : 0)")
        send("friction \(s.friction)")
        send("minspeed \(s.minLaunchSpeed)")
    }

    private func send(_ line: String) {
        // The throwing write: the old one raises an exception if the engine has just died.
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    func stop() {
        stopping = true
        try? input?.close()   // the engine exits when its stdin closes
        process?.terminate()
    }
}
