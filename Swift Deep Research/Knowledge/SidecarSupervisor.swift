import Foundation
import AppKit

/// Auto-launches the pyseekdb sidecar so users never have to touch a terminal.
///
/// Startup sequence (all best-effort, fully self-healing):
///   1. Probe `/health`. If it responds, we're done.
///   2. Locate `seekdb_sidecar.py` (bundled in Resources for release builds;
///      falls back to the project tree for dev runs).
///   3. Launch it with the best available Python — a managed virtualenv under
///      Application Support if we've built one, otherwise the system `python3`.
///   4. If the process dies because its Python dependencies are missing,
///      bootstrap a private virtualenv (`python3 -m venv` + `pip install
///      pyseekdb fastapi uvicorn pydantic`) ONCE and relaunch from it. This is
///      what makes "the knowledge base just works on first launch" true even on
///      a machine that has never had the packages installed.
///   5. Poll `/health` and report a precise `Status`.
///
/// The supervisor terminates the child on app quit.
public actor SidecarSupervisor {
    public static let shared = SidecarSupervisor()

    public enum Status: Sendable, Equatable {
        case running                       // sidecar responding to /health
        case launching                     // process spawned, /health not yet up
        case installingDependencies        // building the managed virtualenv
        case notInstalled(String)          // python missing / pip deps missing
        case scriptMissing                 // can't find seekdb_sidecar.py
        case failed(String)                // process exited / unknown error
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var lastError: String?
    private var quitObserver: NSObjectProtocol?
    private var didAttemptBootstrap = false
    private var lastBootstrapAttempt: Date?
    private(set) var status: Status = .launching
    /// In-flight launch, so concurrent `ensureRunning` callers join one launch
    /// instead of each spawning a duplicate sidecar that collides on the port.
    private var ensureTask: Task<Status, Never>?

    private init() {
        Task { await registerTermination() }
    }

    private func registerTermination() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await SidecarSupervisor.shared.terminate() }
        }
        self.quitObserver = token
    }

    // MARK: - Managed virtualenv locations

    private var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SwiftDeepResearch", isDirectory: true)
    }
    private var venvDir: URL { appSupportDir.appendingPathComponent("sidecar-venv", isDirectory: true) }
    private var venvPython: URL { venvDir.appendingPathComponent("bin/python3") }
    private var hasVenv: Bool { FileManager.default.isExecutableFile(atPath: venvPython.path) }

    // MARK: - Public API

    /// Ensure the sidecar is reachable at `host`. Returns the current status.
    /// Safe to call repeatedly and concurrently — only one launch runs at a time.
    @discardableResult
    public func ensureRunning(host: URL, port: Int? = nil) async -> Status {
        // Fast path: already healthy, no launch needed.
        if await probeHealth(host: host) { status = .running; return .running }
        // Coalesce concurrent callers. The check-and-assign below runs in a
        // single synchronous actor step (no `await` between them), so two
        // callers can never both start a launch — the second joins the first.
        if let ensureTask { return await ensureTask.value }
        let task = Task { await self.performEnsureRunning(host: host, port: port) }
        ensureTask = task
        let result = await task.value
        ensureTask = nil
        return result
    }

    private func performEnsureRunning(host: URL, port: Int?) async -> Status {
        // Re-probe inside the launch: a sibling caller (or the startup launch)
        // may have brought it up between our fast-path check and here.
        if await probeHealth(host: host) { status = .running; return .running }

        // Already supervising — just wait for it to come up.
        if let process, process.isRunning {
            let up = await waitForHealthOrExit(host: host)
            status = up ? .running : .launching
            return status
        }

        guard let script = locateScript() else {
            lastError = "seekdb_sidecar.py not found in app bundle or project tree"
            status = .scriptMissing
            return .scriptMissing
        }
        let resolvedPort = port ?? host.port ?? 9100

        // Prefer an interpreter that ALREADY has the deps. Probing fixes the
        // classic failure where the GUI launch PATH (Finder/Xcode, not a shell)
        // resolves `python3` to a bare interpreter without pyseekdb installed —
        // the sidecar script then prints "Missing dependencies" and exits.
        if let python = await pythonWithDependencies() {
            let result = await launchAndWait(script: script, port: resolvedPort,
                                             host: host, python: python)
            if case .running = result { status = result; return result }
            // Failed for a non-deps reason (e.g. port busy) — bootstrapping
            // won't help, so report it.
            if !needsDependencies { status = result; return result }
        }

        // No interpreter has the deps → build a private virtualenv, install
        // them, and launch from it. We don't latch this OFF forever after one
        // failure: a transient pip/network error shouldn't permanently disable
        // auto-recovery for the rest of the session. Instead we apply a cooldown
        // so a later query retries without hammering pip on every call.
        let cooldownElapsed = lastBootstrapAttempt.map { Date().timeIntervalSince($0) > 90 } ?? true
        if !didAttemptBootstrap || cooldownElapsed {
            didAttemptBootstrap = true
            lastBootstrapAttempt = Date()
            status = .installingDependencies
            if await installDependencies() {
                let result = await launchAndWait(script: script, port: resolvedPort,
                                                 host: host, python: venvPython.path)
                status = result
                return result
            }
            status = .notInstalled(lastError ?? "Failed to install Python dependencies.")
            return status
        }
        status = .notInstalled(lastError ??
            "Python dependencies unavailable. Open Settings → Knowledge → Reinstall dependencies.")
        return status
    }

    // MARK: - Interpreter discovery

    /// Candidate `python3` interpreters, most-likely-good first. Absolute paths
    /// are tried directly; bare names rely on the augmented PATH. Probing these
    /// for the required modules is what makes the knowledge base "just work"
    /// regardless of how the app was launched.
    private func pythonCandidates() -> [String] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var c: [String] = []
        if hasVenv { c.append(venvPython.path) }
        // Installed pyenv versions, newest first — covers the common case where
        // the deps live in a specific pyenv version and the GUI PATH can't see
        // the shim's global resolution.
        let pyenvVersions = home + "/.pyenv/versions"
        if let entries = try? fm.contentsOfDirectory(atPath: pyenvVersions) {
            for v in entries.sorted(by: >) {
                c.append(pyenvVersions + "/\(v)/bin/python3")
            }
        }
        c += [
            "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.12", "/usr/local/bin/python3",
            home + "/.pyenv/shims/python3",
            "python3", "/usr/bin/python3"
        ]
        return c
    }

    /// First candidate interpreter that can import every required module. Uses
    /// `importlib.util.find_spec` (no heavy import) so the probe is fast.
    private func pythonWithDependencies() async -> String? {
        let probe = "import importlib.util as u,sys;" +
            "sys.exit(0 if all(u.find_spec(m) for m in " +
            "['pyseekdb','fastapi','uvicorn','pydantic']) else 1)"
        var seen = Set<String>()
        for candidate in pythonCandidates() where seen.insert(candidate).inserted {
            // Short timeout: a healthy interpreter answers `find_spec` in well
            // under a second; anything slower is a wedged/broken candidate we
            // should skip rather than hang on.
            let (code, _) = await runProcess(executable: candidate, args: ["-c", probe], timeout: 8)
            if code == 0 { return candidate }
        }
        return nil
    }

    /// Best interpreter for *creating* the virtualenv: first candidate that runs
    /// at all (deps not required), preferring a modern Python. Skips the venv's
    /// own python, which may not exist yet.
    private func pythonForVenvCreation() async -> String {
        var seen = Set<String>()
        for candidate in pythonCandidates()
        where candidate != venvPython.path && seen.insert(candidate).inserted {
            let (code, _) = await runProcess(executable: candidate,
                                            args: ["-c", "import sys"], timeout: 8)
            if code == 0 { return candidate }
        }
        return "python3"
    }

    /// Force a dependency (re)install + relaunch. Exposed for a manual
    /// "repair" action in Settings.
    @discardableResult
    public func reinstallAndStart(host: URL, port: Int? = nil) async -> Status {
        await terminate()
        didAttemptBootstrap = true
        status = .installingDependencies
        let ok = await installDependencies()
        guard ok, let script = locateScript() else {
            status = .notInstalled(lastError ?? "Dependency install failed.")
            return status
        }
        let resolvedPort = port ?? host.port ?? 9100
        status = await launchAndWait(script: script, port: resolvedPort,
                                    host: host, python: venvPython.path)
        return status
    }

    public func currentStatus() -> Status { status }
    public func diagnostics() -> String? { lastError }

    /// Best-effort termination. Called from app-quit notification and the
    /// Settings repair action. Async so it yields the actor's executor while
    /// waiting (the old `Thread.sleep` blocked every other actor caller for up
    /// to a second).
    public func terminate() async {
        guard let process, process.isRunning else { return }
        process.terminate()   // SIGTERM
        for _ in 0..<20 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Launch plumbing

    /// True when the captured child output indicates a missing Python module.
    /// Matches both raw interpreter errors and the sidecar script's own
    /// friendly "Missing dependencies" message (which hides the underlying
    /// `ImportError`), plus its `SystemExit(2)` deps signal.
    private var needsDependencies: Bool {
        guard let e = lastError?.lowercased() else { return false }
        return e.contains("modulenotfounderror")
            || e.contains("no module named")
            || e.contains("importerror")
            || e.contains("missing dependencies")
            || e.contains("is not installed")
            || e.contains("pip install")
            || e.contains("[exit 2]")
    }

    private func launchAndWait(script: URL, port: Int, host: URL, python: String) async -> Status {
        let launched = launch(script: script, port: port, python: python)
        guard case .launching = launched else { return launched }
        return await waitForHealthOrExit(host: host) ? .running : statusAfterExit()
    }

    /// After a launch attempt that didn't come up healthy, decide whether the
    /// failure is a missing-deps problem or a generic failure.
    private func statusAfterExit() -> Status {
        if process?.isRunning == true { return .launching }
        if needsDependencies { return .notInstalled(lastError ?? "Missing Python dependencies.") }
        return .failed(lastError ?? "Sidecar process exited before becoming healthy.")
    }

    private func launch(script: URL, port: Int, python: String) -> Status {
        // Tear down any prior pipe before replacing it, so a relaunch doesn't
        // leak the old read handle / readability handler.
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // `/usr/bin/env <python> …` works whether `python` is an absolute venv
        // path or the bare `python3` resolved via PATH.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [python, script.path, "--port", String(port)]
        process.environment = childEnvironment()

        // Reset the rolling error buffer for this attempt so stale messages from
        // a prior attempt don't trip `needsDependencies`.
        lastError = nil

        do {
            try process.run()
        } catch {
            lastError = "Failed to spawn python (\(python)): \(error.localizedDescription)"
            return .notInstalled(lastError ?? "unknown")
        }

        self.process = process
        self.stdoutPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                Task { await self?.appendLog(text) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.handleExit(status: status) }
        }
        return .launching
    }

    /// PATH augmented with common pyenv / Homebrew locations so `python3`
    /// resolves to a real interpreter even when launched from Finder/Xcode
    /// (where the inherited PATH is the minimal `/usr/bin:/bin:…`). The extra
    /// locations are *prepended* so a Homebrew/pyenv Python that actually has
    /// the deps wins over the bare `/usr/bin/python3` stub.
    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let extraPaths = [
            "/opt/homebrew/bin", "/usr/local/bin",
            home + "/.pyenv/shims"
        ]
        env["PATH"] = extraPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private func appendLog(_ text: String) {
        let combined = (lastError ?? "") + text
        lastError = String(combined.suffix(4096))
    }

    private func handleExit(status: Int32) {
        if status != 0 {
            lastError = (lastError ?? "") + "\n[exit \(status)]"
        }
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
    }

    // MARK: - Dependency bootstrap

    /// Create the managed virtualenv (if needed) and install the sidecar's
    /// Python dependencies into it. Returns true only if the venv python ends
    /// up present and pip succeeded. Best-effort and fully logged.
    private func installDependencies() async -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        if !hasVenv {
            let creator = await pythonForVenvCreation()
            let (code, out) = await runProcess(
                executable: creator,
                args: ["-m", "venv", venvDir.path])
            if code != 0 {
                // Don't leave a half-built venv behind — `hasVenv` only checks
                // for bin/python3, so a partial dir would falsely look "present"
                // on the next run and never get repaired.
                try? fm.removeItem(at: venvDir)
                lastError = "venv creation failed (\(creator)):\n" + String(out.suffix(1500))
                return false
            }
        }
        guard hasVenv else {
            lastError = "virtualenv python not found after creation at \(venvPython.path)"
            return false
        }

        // Upgrade pip (non-fatal) then install the runtime deps.
        _ = await runProcess(executable: venvPython.path,
                             args: ["-m", "pip", "install", "--upgrade", "pip"])
        let (code, out) = await runProcess(
            executable: venvPython.path,
            args: ["-m", "pip", "install", "pyseekdb", "fastapi", "uvicorn", "pydantic"])
        if code != 0 {
            // Tear down the venv so the next attempt starts clean instead of
            // inheriting a partially-installed environment.
            try? fm.removeItem(at: venvDir)
            lastError = "pip install failed:\n" + String(out.suffix(2000))
            return false
        }
        // Verify the venv really imports all four modules before declaring
        // success — pip can exit 0 yet leave a broken/partial install.
        let probe = "import importlib.util as u,sys;" +
            "sys.exit(0 if all(u.find_spec(m) for m in " +
            "['pyseekdb','fastapi','uvicorn','pydantic']) else 3)"
        let (verifyCode, _) = await runProcess(executable: venvPython.path,
                                               args: ["-c", probe], timeout: 15)
        if verifyCode != 0 {
            try? fm.removeItem(at: venvDir)
            lastError = "Dependencies did not import after install (venv verification failed)."
            return false
        }
        return true
    }

    /// Run a process to completion off the actor's thread, capturing a tail of
    /// its combined output. Used for venv/pip steps which are slow.
    ///
    /// `timeout` bounds the run so a wedged interpreter (e.g. a broken pyenv
    /// shim that hangs on `import`) can't suspend `ensureRunning` forever — on
    /// expiry the child is terminated and a non-zero code is returned. Probes
    /// pass a short timeout; pip/venv steps pass a long one.
    private func runProcess(executable: String,
                            args: [String],
                            timeout: TimeInterval = 600) async -> (Int32, String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            if executable.hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + args
            }
            process.environment = childEnvironment()

            let buffer = OutputBuffer()
            let once = ResumeOnce()
            let timeoutHolder = TaskHolder()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                    buffer.append(s)
                }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                timeoutHolder.cancel()
                once.run { continuation.resume(returning: (proc.terminationStatus, buffer.value())) }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                once.run { continuation.resume(returning: (-1, "spawn failed: \(error.localizedDescription)")) }
                return
            }
            // Watchdog: kill and resume if the process overruns its budget.
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if Task.isCancelled { return }
                if process.isRunning {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                once.run {
                    continuation.resume(returning: (-1, "timed out after \(Int(timeout))s\n" + buffer.value()))
                }
            }
            timeoutHolder.set(watchdog)
        }
    }

    // MARK: - Health probing

    private func probeHealth(host: URL) async -> Bool {
        var req = URLRequest(url: host.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Poll `/health` until the sidecar answers, the child process exits, or we
    /// hit a generous ceiling. First-run embedded-mode startup does real work
    /// before binding (OceanBase engine init + create_database +
    /// get_or_create_collection), which can take well over 15s on a cold disk,
    /// so a short window produced false "unreachable" results. We keep polling
    /// as long as the process is alive, up to ~90s, and bail out immediately if
    /// it exits (e.g. ModuleNotFoundError) so we never wait the full window on a
    /// launch that already failed.
    private func waitForHealthOrExit(host: URL) async -> Bool {
        for _ in 0..<180 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await probeHealth(host: host) { return true }
            if process == nil { return false }   // process exited
        }
        return false
    }

    // MARK: - Script discovery

    private func locateScript() -> URL? {
        if let bundled = Bundle.main.url(forResource: "seekdb_sidecar",
                                         withExtension: "py") {
            return bundled
        }
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("sidecar/seekdb_sidecar.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        let dev = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("XCode-Projects/Swift-Deep-Research/sidecar/seekdb_sidecar.py")
        if FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }
        return nil
    }
}

/// Guarantees a checked continuation is resumed exactly once, even though the
/// process `terminationHandler` and the timeout watchdog race on separate
/// threads.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Runs `body` only on the first call; subsequent calls are no-ops.
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Mutable holder so a `terminationHandler` closure can cancel the timeout
/// watchdog `Task` that was created after the handler was installed.
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func set(_ t: Task<Void, Never>) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; task = nil; lock.unlock(); t?.cancel() }
}

/// Tiny thread-safe text accumulator for capturing bounded process output from
/// a `readabilityHandler` (which fires on an arbitrary queue).
private final class OutputBuffer: @unchecked Sendable {
    private var storage = ""
    private let lock = NSLock()
    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        storage += s
        if storage.count > 8192 { storage = String(storage.suffix(8192)) }
    }
    func value() -> String {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
