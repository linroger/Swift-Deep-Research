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
///      bootstrap a private virtualenv (`python3 -m venv` + `pip install -r
///      sidecar/requirements.txt`, falling back to the same pinned specs inline)
///      ONCE and relaunch from it. This is what makes "the knowledge base just
///      works on first launch" true even on a machine that has never had the
///      packages installed.
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

    /// Single source of truth for the sidecar's pinned Python dependency specs.
    /// Mirrors `sidecar/requirements.txt` verbatim. `installDependencies`
    /// prefers `pip install -r requirements.txt` when that file is locatable and
    /// falls back to these inline specs otherwise. pydantic v2 is mandatory —
    /// the sidecar is Pydantic-v2-specific — and the rest are capped below the
    /// next major so an unpinned float can't break the first-launch bootstrap.
    static let pinnedPipSpecs: [String] = [
        "pyseekdb>=0.1,<1",
        "fastapi>=0.110,<1",
        "uvicorn>=0.27,<1",
        "pydantic>=2,<3",
    ]

    /// Distinct, user-facing message for the "no internet" case of a failed
    /// dependency bootstrap (kb-offline-vs-broken-deps). The first launch must
    /// download Python packages and the ~470 MB embedding model once; offline
    /// that can't succeed, so we tell the user to connect and Reinstall rather
    /// than handing them a `pip install` command that will keep failing. The
    /// banner detects this exact string (via `messageIndicatesOffline`) to render
    /// the offline-specific fix instead of the generic missing-deps card.
    static let offlineMessage =
        "No internet connection — the knowledge base needs to download Python " +
        "packages and an embedding model once. Connect to the internet and click " +
        "Reinstall."

    /// Substrings pip/urllib emit when the package index or model host can't be
    /// reached. Matching any of these in pip's output tail means the failure is a
    /// connectivity problem, not a genuinely unsatisfiable/broken dependency, so
    /// `installDependencies` surfaces `offlineMessage` instead of a raw pip dump.
    static let offlineSignatures: [String] = [
        "could not find a version",
        "temporary failure in name resolution",
        "failed to establish a new connection",
        "network is unreachable",
        "connection timed out",
        "getaddrinfo failed",
    ]

    /// True when pip's combined output tail carries an offline/network signature.
    static func outputIndicatesOffline(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return offlineSignatures.contains { lowered.contains($0) }
    }

    /// True when a stored diagnostic/error string is the offline message we set
    /// in `installDependencies`. Lets the UI distinguish "no internet" from a
    /// generic unreachable/broken-deps state without a new status enum case.
    public static func messageIndicatesOffline(_ message: String?) -> Bool {
        guard let message else { return false }
        return message == offlineMessage
    }

    /// True when the app is running inside the macOS App Sandbox. The sandbox
    /// exports `APP_SANDBOX_CONTAINER_ID` into every sandboxed process's
    /// environment; its absence is a reliable signal we're unsandboxed (the
    /// intended distribution mode — see Swift_Deep_Research.entitlements). Used
    /// to turn an otherwise-cryptic spawn failure into an actionable message,
    /// since the sandbox blocks the Process/exec + venv bootstrap the sidecar
    /// relies on.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
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
    /// Process-group id of the supervised sidecar when launched as its own
    /// session leader (`pgid == pid`), so `killpg` reaps any helper processes
    /// pyseekdb/uvicorn spawn — not just the parent. `0` when no group was
    /// established (no system `perl`).
    private var childPGID: pid_t = 0
    /// Nonisolated mirror so the synchronous `willTerminate` handler reaps the
    /// tree inline instead of via an unstructured Task that never finishes.
    nonisolated let liveGroup = ProcessGroupBox()

    private init() {
        Task { await registerTermination() }
    }

    private func registerTermination() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Synchronous reap — AppKit won't wait for an unstructured Task before
            // the process exits, so the old `Task { await terminate() }` orphaned
            // the sidecar on quit. `killpg` is sync and safe inline.
            SidecarSupervisor.shared.liveGroup.reap()
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
    /// Stable cache for the Hugging Face / sentence-transformers embedding model
    /// (~470 MB) under our app-support dir, alongside the venv and seekdb data.
    /// Pointing HF_HOME here makes the model's location predictable and persists
    /// it across runs so the first-launch download happens exactly once instead
    /// of re-downloading into a transient/per-user-default cache (kb-stable-hf-cache).
    private var hfCacheDir: URL { appSupportDir.appendingPathComponent("hf-cache", isDirectory: true) }

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

        // Sandbox guard: if we're running inside the App Sandbox and nothing is
        // already serving /health, we can't launch the sidecar at all — the
        // sandbox blocks the child-process exec + venv bootstrap it requires.
        // Probing interpreters and building a venv would all fail with cryptic
        // posix_spawn errors, so short-circuit with an actionable message
        // (the app is intentionally distributed unsandboxed; see
        // Swift_Deep_Research.entitlements).
        if Self.isSandboxed {
            lastError = "This build can't launch the embedding sidecar inside the " +
                "App Sandbox. The knowledge base needs to spawn Python and bootstrap " +
                "a virtualenv, which the sandbox forbids. Use an unsandboxed build of " +
                "Swift Deep Research."
            status = .failed(lastError ?? "sandboxed")
            return status
        }

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
        guard let process, process.isRunning else {
            liveGroup.clear(); childPGID = 0; return
        }
        let pid = process.processIdentifier
        // Reap the whole group (sidecar + any pyseekdb/uvicorn helpers), not just
        // the parent. `process.terminate()` covers the no-setsid fallback.
        if childPGID > 0 { killpg(childPGID, SIGTERM) }
        process.terminate()   // SIGTERM to the direct child
        for _ in 0..<20 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            if childPGID > 0 { killpg(childPGID, SIGKILL) }
            kill(pid, SIGKILL)
        }
        liveGroup.clear()
        childPGID = 0
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

    /// True when the captured child output indicates the bind port is already
    /// held by another process. uvicorn surfaces this as an `OSError` whose text
    /// is "address already in use"; Python also prints `errno 48` (`EADDRINUSE`
    /// on Darwin). Matching both lets us recover from an orphaned sidecar instead
    /// of dumping a raw traceback on the user (kb-port-in-use-no-recovery).
    private var portInUse: Bool {
        guard let e = lastError?.lowercased() else { return false }
        return e.contains("address already in use")
            || e.contains("errno 48")
            || e.contains("eaddrinuse")
    }

    private func launchAndWait(script: URL, port: Int, host: URL, python: String) async -> Status {
        let launched = launch(script: script, port: port, host: host, python: python)
        guard case .launching = launched else { return launched }
        if await waitForHealthOrExit(host: host) { return .running }
        // The first attempt died. If it died because the port was already taken,
        // try to recover once: a healthy orphan we can adopt, or a wedged orphan
        // we can reap and relaunch over (kb-port-in-use-no-recovery).
        if portInUse {
            if await recoverFromPortConflict(host: host, port: port) {
                // The port was freed — relaunch over it once.
                let relaunched = launch(script: script, port: port, host: host, python: python)
                guard case .launching = relaunched else { return relaunched }
                return await waitForHealthOrExit(host: host) ? .running : statusAfterExit(port: port)
            }
            // Recovery returned false either because a healthy listener was
            // adopted (no relaunch needed) or because no owner could be freed.
            // Re-probe once to tell those apart: a healthy adopt is success,
            // otherwise report the distinct EADDRINUSE failure.
            if await probeHealth(host: host) { status = .running; return .running }
        }
        return statusAfterExit(port: port)
    }

    /// Recover from an "address already in use" launch failure. Idempotent and
    /// best-effort:
    ///   1. Re-probe `/health` once — if a previous sidecar of ours is already
    ///      listening and healthy, adopt it (no relaunch needed). This is the
    ///      common debugger-stop / quit+reopen case where the orphan is fine.
    ///   2. Otherwise the listener is a wedged orphan (or a foreign process):
    ///      find the PID holding the port via `lsof -ti tcp:PORT` and SIGTERM it,
    ///      then SIGKILL any stragglers, so the caller can relaunch over a freed
    ///      port.
    /// Returns `true` when the port is healthy (adopt) or has been freed (relaunch);
    /// `false` when no owner could be found/killed (the caller then reports a
    /// distinct EADDRINUSE failure instead of looping).
    private func recoverFromPortConflict(host: URL, port: Int) async -> Bool {
        // 1. Adopt a healthy already-running listener as our sidecar.
        if await probeHealth(host: host) {
            status = .running
            return false   // healthy — no relaunch needed; caller short-circuits below
        }

        // 2. Locate the PID(s) bound to the port and terminate them. `lsof -ti`
        //    prints one PID per line with no header, so the output parses cleanly.
        let pids = await pidsHoldingPort(port)
        guard !pids.isEmpty else { return false }
        for pid in pids { kill(pid, SIGTERM) }
        // Give the orphan a moment to release the socket, then escalate to
        // SIGKILL for anything still bound so the relaunch doesn't re-collide.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if await pidsHoldingPort(port).isEmpty { return true }
        }
        for pid in await pidsHoldingPort(port) { kill(pid, SIGKILL) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return await pidsHoldingPort(port).isEmpty
    }

    /// PIDs of processes with a listening/bound socket on `port`, via
    /// `lsof -ti tcp:PORT`. Returns an empty array when nothing holds the port,
    /// `lsof` is unavailable, or the command times out. We never SIGTERM our own
    /// supervised child here — `recoverFromPortConflict` only runs after that
    /// child has already exited (the launch failed), so the survivor is by
    /// definition a foreign/orphaned listener.
    private func pidsHoldingPort(_ port: Int) async -> [pid_t] {
        let (code, out) = await runProcess(executable: "/usr/sbin/lsof",
                                           args: ["-ti", "tcp:\(port)"],
                                           timeout: 5)
        // lsof exits non-zero (1) when no process matches; that's "port free",
        // not an error. Only parse PIDs from whatever it printed.
        guard code == 0 || !out.isEmpty else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            guard let value = Int32(line.trimmingCharacters(in: .whitespaces)),
                  value > 0, value != me else { return nil }
            return pid_t(value)
        }
    }

    /// After a launch attempt that didn't come up healthy, decide whether the
    /// failure is a missing-deps problem, an unrecoverable port conflict, or a
    /// generic failure.
    private func statusAfterExit(port: Int) -> Status {
        if process?.isRunning == true { return .launching }
        if needsDependencies { return .notInstalled(lastError ?? "Missing Python dependencies.") }
        // A port conflict that survived `recoverFromPortConflict` (we couldn't
        // adopt a healthy listener and couldn't free the port) gets a distinct,
        // actionable message instead of dumping the raw uvicorn traceback on the
        // user (kb-port-in-use-no-recovery).
        if portInUse {
            return .failed("Port \(port) is already in use by another process " +
                "that isn't responding to the knowledge-base health check. " +
                "Quit any stray `seekdb_sidecar.py`/python process, or free the port " +
                "(e.g. `lsof -ti tcp:\(port) | xargs kill`), then retry.")
        }
        return .failed(lastError ?? "Sidecar process exited before becoming healthy.")
    }

    private func launch(script: URL, port: Int, host: URL, python: String) -> Status {
        // Tear down any prior pipe before replacing it, so a relaunch doesn't
        // leak the old read handle / readability handler.
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Launch the sidecar as a new SESSION / process-group leader via a perl
        // `setsid` shim, then `exec` the real command (preserving the pid). This
        // makes `killpg` reap any helper processes pyseekdb/uvicorn spawn instead
        // of orphaning them. `exec @ARGV` (list form) is execvp — no shell, no
        // injection. Falls back to a direct launch if system perl is missing.
        // `/usr/bin/env <python> …` works whether `python` is an absolute venv
        // path or the bare `python3` resolved via PATH.
        // Bind to the exact host the client probes. Previously only `--port` was
        // passed, so the sidecar fell back to its own 127.0.0.1 default — fine
        // until the configured seekdb host URL diverged from that default.
        let bindHost = host.host ?? "127.0.0.1"
        let realArgs = [python, script.path, "--host", bindHost, "--port", String(port)]
        let perl = "/usr/bin/perl"
        let useSetsid = FileManager.default.isExecutableFile(atPath: perl)
        if useSetsid {
            process.executableURL = URL(fileURLWithPath: perl)
            process.arguments = ["-e",
                                 "use POSIX qw(setsid); setsid(); exec @ARGV or die qq(exec failed: $!\\n);",
                                 "--", "/usr/bin/env"] + realArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = realArgs
        }
        process.environment = childEnvironment()

        // Reset the rolling error buffer for this attempt so stale messages from
        // a prior attempt don't trip `needsDependencies`.
        lastError = nil

        do {
            try process.run()
        } catch {
            // If the spawn failed AND we're running inside the App Sandbox, the
            // sandbox almost certainly blocked the exec: this build can't launch
            // the embedding sidecar that way. Surface an actionable message
            // instead of a generic "failed to spawn" that the user can't act on.
            // The app is intentionally distributed unsandboxed (see
            // Swift_Deep_Research.entitlements) precisely because the sidecar
            // needs Process/exec + a venv bootstrap.
            if Self.isSandboxed {
                lastError = "This build can't launch the embedding sidecar inside " +
                    "the App Sandbox. The knowledge base needs to spawn Python and " +
                    "bootstrap a virtualenv, which the sandbox forbids. Use an " +
                    "unsandboxed build of Swift Deep Research (underlying error: " +
                    "\(error.localizedDescription))."
                return .failed(lastError ?? "sandboxed")
            }
            lastError = "Failed to spawn python (\(python)): \(error.localizedDescription)"
            return .notInstalled(lastError ?? "unknown")
        }

        self.process = process
        self.stdoutPipe = pipe
        if useSetsid {
            childPGID = process.processIdentifier   // pgid == pid after setsid
            liveGroup.set(childPGID)
        } else {
            childPGID = 0
            liveGroup.clear()
        }

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
        // Pin the embedding model cache to a stable subdir under our app-support
        // dir so the ~470 MB model downloads once and lives in a predictable
        // location alongside the venv/seekdb data (kb-stable-hf-cache). HF_HOME
        // is the modern umbrella var; TRANSFORMERS_CACHE / SENTENCE_TRANSFORMERS_HOME
        // are set too so older huggingface_hub / sentence-transformers builds that
        // don't honor HF_HOME still land in the same place. Best-effort dir
        // creation: if it fails the libraries fall back to their own default.
        let cache = hfCacheDir
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        env["HF_HOME"] = cache.path
        env["TRANSFORMERS_CACHE"] = cache.appendingPathComponent("transformers", isDirectory: true).path
        env["SENTENCE_TRANSFORMERS_HOME"] = cache.appendingPathComponent("sentence-transformers", isDirectory: true).path
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
        childPGID = 0
        liveGroup.clear()
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

        // Guarantee pip exists in the venv before using it. Some system pythons
        // create venvs without a working pip; `ensurepip` repairs that so the
        // dep install below doesn't fail with a cryptic "No module named pip".
        // Both steps are best-effort (non-fatal).
        _ = await runProcess(executable: venvPython.path,
                             args: ["-m", "ensurepip", "--upgrade"], timeout: 120)
        _ = await runProcess(executable: venvPython.path,
                             args: ["-m", "pip", "install", "--upgrade", "pip"], timeout: 120)
        // Prefer `pip install -r requirements.txt` so the pins live in one place
        // (the file) and stay in lockstep with the manual-setup docs; fall back
        // to the inline `pinnedPipSpecs` (same pins) when the file isn't found
        // — e.g. an unusual bundle layout. pydantic v2 is mandatory either way.
        let installArgs: [String]
        if let requirements = locateRequirements() {
            installArgs = ["-m", "pip", "install", "-r", requirements.path]
        } else {
            installArgs = ["-m", "pip", "install"] + Self.pinnedPipSpecs
        }
        let (code, out) = await runProcess(
            executable: venvPython.path,
            args: installArgs)
        if code != 0 {
            // Tear down the venv so the next attempt starts clean instead of
            // inheriting a partially-installed environment.
            try? fm.removeItem(at: venvDir)
            // Distinguish "no internet" from "broken deps" (kb-offline-vs-broken-deps):
            // offline pip can't possibly succeed, so handing the user the same
            // `pip install` command is useless. Detect the network signatures in
            // pip's output tail and surface an actionable "connect to the internet"
            // message (carried verbatim through the offline marker so the banner
            // can render the right fix instead of a pip command).
            if Self.outputIndicatesOffline(out) {
                lastError = Self.offlineMessage
            } else {
                lastError = "pip install failed:\n" + String(out.suffix(2000))
            }
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

    /// Dedicated ephemeral probe session. `URLSession.shared` carries a shared
    /// cache/cookie store and a 60s default timeout, neither of which we want for
    /// a fast localhost liveness check — and the rest of the KB stack already uses
    /// ephemeral sessions (SeekDBClient), so probing through .shared was the lone
    /// inconsistency (kb-probe-shared-session). One cached session avoids rebuilding
    /// configuration on every poll iteration.
    private static let probeSession = HTTPClientCommon.defaultSession(timeout: 2)

    private func probeHealth(host: URL) async -> Bool {
        await probeHealthDetail(host: host).reachable
    }

    /// Outcome of a single `/health` probe. `reachable` is the only signal the
    /// launch wait gates on (HTTP 200), so a warming sidecar still counts as up.
    /// `modelReady` is optional/additive: it carries the sidecar's `model_ready`
    /// flag when the JSON decodes (nil when the field is absent, the body isn't
    /// JSON, or the probe failed), purely for diagnostics/logging — it must never
    /// turn a reachable sidecar into a failure (E3-kb-9).
    private struct HealthProbe: Sendable {
        var reachable: Bool
        var modelReady: Bool?
    }

    /// Decodes only the additive `model_ready` field; missing/extra keys are
    /// ignored so this never breaks against an older sidecar that predates it.
    private struct ProbeHealthBody: Decodable {
        let model_ready: Bool?
    }

    private func probeHealthDetail(host: URL) async -> HealthProbe {
        var req = URLRequest(url: host.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        req.httpMethod = "GET"
        do {
            let (data, response) = try await Self.probeSession.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return HealthProbe(reachable: false, modelReady: nil)
            }
            // Reachable is decided purely by the 200; decoding model_ready is a
            // best-effort extra that must not flip the result on a decode miss.
            let modelReady = (try? JSONDecoder().decode(ProbeHealthBody.self, from: data))?.model_ready
            return HealthProbe(reachable: true, modelReady: modelReady)
        } catch {
            return HealthProbe(reachable: false, modelReady: nil)
        }
    }

    /// Generous backstop ceiling for the launch wait. This is NOT the primary
    /// failure signal — process exit is (see below). It only bounds a degenerate
    /// case where the child never exits *and* never becomes reachable (e.g. a
    /// wedged interpreter that doesn't crash), so `ensureRunning` can't suspend a
    /// caller forever. 5 minutes comfortably covers a cold-disk OceanBase init
    /// plus a first-run embedding-model download on a slow connection.
    private static let healthWaitCeiling: TimeInterval = 300

    /// Poll `/health` until the sidecar answers, the child process exits, or we
    /// hit the generous backstop ceiling. First-run embedded-mode startup does
    /// real work before binding (OceanBase engine init + create_database +
    /// get_or_create_collection), which can take well over 15s on a cold disk,
    /// so a short window produced false "unreachable" results.
    ///
    /// Failure signal is process EXIT, not the clock (E3-kb-9). Earlier this
    /// loop failed after a fixed ~90s even while the child was alive and still
    /// doing legitimate first-run work (engine init before bind, or a slow model
    /// download), spuriously reporting a healthy-but-slow launch as failed. We
    /// now keep polling for as long as the process is alive and only bail out
    /// (a) immediately when the child exits — e.g. ModuleNotFoundError, so we
    /// never wait on a launch that already failed — or (b) at the generous
    /// `healthWaitCeiling` backstop for the rare never-exits/never-binds wedge.
    ///
    /// Warming tolerance: the sidecar binds the port and answers /health (HTTP
    /// 200) immediately, then loads the ~80-90 MB embedding model on a background
    /// thread (model_ready=false until done). We gate success on reachability
    /// (200) only, so a reachable-but-warming sidecar is a successful launch here
    /// — a slow first-run model download no longer trips a false "unreachable"
    /// failure (kb-implicit-embedding-fn). The model finishes warming in the
    /// background; the first query that arrives before it is ready loads it
    /// lazily. The probe also surfaces `model_ready` (additively decoded) for
    /// diagnostics, but it never gates success here.
    private func waitForHealthOrExit(host: URL) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.healthWaitCeiling)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            // A reachable /health is success even while model_ready=false; the
            // embedding model keeps warming in the background.
            let probe = await probeHealthDetail(host: host)
            if probe.reachable { return true }
            // Process exit — not the clock — is the real failure signal. A child
            // that has gone away (e.g. missing-deps crash) can never become
            // healthy, so stop immediately instead of waiting out the ceiling.
            if process == nil { return false }
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

    /// Locate `requirements.txt` so the bootstrap can `pip install -r` the
    /// pinned specs instead of inline names. Mirrors `locateScript`'s search:
    /// bundled Resources for release builds, then the project tree for dev runs.
    /// Returns nil when not found — the caller then falls back to the inline
    /// `pinnedPipSpecs` (which carry the same pins).
    private func locateRequirements() -> URL? {
        if let bundled = Bundle.main.url(forResource: "requirements",
                                         withExtension: "txt") {
            return bundled
        }
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("sidecar/requirements.txt")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        let dev = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("XCode-Projects/Swift-Deep-Research/sidecar/requirements.txt")
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
