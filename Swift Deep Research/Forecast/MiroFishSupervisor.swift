import Foundation
import AppKit

/// Auto-launches & supervises the MiroFish prediction backend (Flask, default
/// :5001) so the Forecast workspace works without the user touching a terminal.
///
/// This mirrors `SidecarSupervisor` (the pyseekdb sidecar), but MiroFish's
/// dependency stack (camel-oasis / camel-ai / zep-cloud, Python ≤3.12) is far too
/// heavy to bootstrap a venv on the fly. So instead of installing dependencies we:
///   1. Probe `:5001/health`; if it answers (e.g. the user already ran
///      `npm run dev`), attach to it and we're done.
///   2. Locate the MiroFish repo (configurable; default
///      `~/Downloads/mirofish/MiroFish-0.1.2`) and its `backend/run.py`.
///   3. Launch it with the backend's own venv (`backend/.venv/bin/python`) or,
///      failing that, `uv run`.
///   4. Poll `/health`. If the process exits early (commonly a broken/3.13 venv
///      that can't import camel-ai), surface a precise, actionable `Status`
///      rather than hanging — the UI then guides the user to fix the backend.
///
/// The Zep API key (the one credential MiroFish always needs and that has no
/// runtime settings endpoint) can be merged into MiroFish's `.env` via
/// `syncEnv` — MiroFish loads `.env` with `override=True`, so an injected child
/// env var alone would be clobbered; writing `.env` is the reliable path.
public actor MiroFishSupervisor {
    public static let shared = MiroFishSupervisor()

    public enum Status: Sendable, Equatable {
        case running                    // backend answering /health
        case launching                  // process spawned, /health not yet up
        case stopped                    // not started / terminated cleanly
        case backendMissing(String)     // repo dir or run.py not found
        case interpreterMissing(String) // no venv python and no `uv`
        case failed(String)             // process exited / unknown error
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var logTail: String = ""
    private var lastPort: Int?
    private var quitObserver: NSObjectProtocol?
    /// Monotonic launch generation. Each `launch()` bumps it; the readability
    /// handler captures the value at registration time and `appendLog` drops text
    /// tagged with a stale epoch, so a quick fail-then-relaunch can't mix the dead
    /// child's stdout into the new child's `logTail` (which `statusAfterExit`
    /// later parses for diagnostics).
    private var launchEpoch: UInt64 = 0
    private(set) var status: Status = .stopped
    /// Coalesce concurrent `ensureRunning` callers onto one launch.
    private var ensureTask: Task<Status, Never>?
    /// Process-group id of the supervised backend when it was launched as its own
    /// session leader (`pgid == child pid`). `> 0` means `killpg` reaps the entire
    /// DeerFlow/OASIS tree, not just `run.py`. `0` when we couldn't establish a
    /// group (no `perl`), in which case we fall back to single-process signalling.
    private var childPGID: pid_t = 0
    /// Nonisolated mirror of `childPGID` so the synchronous `willTerminate`
    /// handler can reap the tree inline (an awaiting Task can't finish before the
    /// app process exits).
    nonisolated let liveGroup = ProcessGroupBox()
    /// Nonisolated holder for the quit-notification token so the nonisolated
    /// `deinit` can deregister it (an actor-isolated stored property is
    /// unreachable from `deinit`). Removing the observer prevents the latent leak
    /// the singleton would otherwise carry if it ever stops being a singleton.
    nonisolated private let quitObserverBox = ObserverTokenBox()

    private init() {
        Task { await registerTermination() }
    }

    deinit {
        quitObserverBox.remove()
    }

    private func registerTermination() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // Reap the backend tree SYNCHRONOUSLY here. AppKit does not wait for
            // unstructured Tasks before the process exits, so the old
            // `Task { await terminate() }` almost never ran to completion — it
            // orphaned the DeerFlow/OASIS grandchildren (which then keep burning
            // API credits). `killpg` is sync and safe to call inline.
            MiroFishSupervisor.shared.liveGroup.reap()
        }
        self.quitObserver = token
        quitObserverBox.set(token)
    }

    // MARK: - Public API

    public func currentStatus() -> Status { status }
    public func diagnostics() -> String? { logTail.isEmpty ? nil : logTail }

    /// Probe-only readiness check (does NOT launch). Used when auto-launch is off
    /// and the user runs the backend themselves.
    public func checkHealth(host: URL) async -> Status {
        if await probeHealth(host: host) { status = .running; return .running }
        if case .running = status { status = .stopped }
        return status
    }

    /// Ensure the MiroFish backend at `host` is reachable, launching it from
    /// `repoRoot` if needed. Safe to call repeatedly and concurrently.
    @discardableResult
    public func ensureRunning(host: URL, repoRoot: URL) async -> Status {
        if await probeHealth(host: host) { status = .running; return .running }
        if let ensureTask { return await ensureTask.value }
        let task = Task { await self.performEnsureRunning(host: host, repoRoot: repoRoot) }
        ensureTask = task
        let result = await task.value
        ensureTask = nil
        return result
    }

    private func performEnsureRunning(host: URL, repoRoot: URL) async -> Status {
        if await probeHealth(host: host) { status = .running; return .running }

        // Already supervising a child — just wait for it to come up.
        if let process, process.isRunning {
            let up = await waitForHealthOrExit(host: host)
            if !up { drainPipeIntoLogTail() }   // populate diagnostics before parsing
            status = up ? .running : statusAfterExit()
            return status
        }

        let fm = FileManager.default
        let backendDir = repoRoot.appendingPathComponent("backend", isDirectory: true)
        let runScript = backendDir.appendingPathComponent("run.py")
        guard fm.fileExists(atPath: runScript.path) else {
            status = .backendMissing(
                "MiroFish backend not found at \(runScript.path). Set the correct MiroFish folder in Settings → Forecast.")
            return status
        }

        guard let invocation = resolveInterpreter(backendDir: backendDir) else {
            status = .interpreterMissing(
                "No MiroFish Python environment found. Run `uv sync` in \(backendDir.path) (Python ≤3.12), or install `uv`.")
            return status
        }

        status = .launching
        lastPort = host.port ?? 5001
        let launched = launch(invocation: invocation, backendDir: backendDir,
                              port: host.port ?? 5001)
        guard case .launching = launched else { status = launched; return launched }
        let up = await waitForHealthOrExit(host: host)
        if !up { drainPipeIntoLogTail() }   // populate diagnostics before parsing
        status = up ? .running : statusAfterExit()
        return status
    }

    /// Stop a backend this supervisor started. (No-op if we attached to an
    /// externally-run backend.)
    public func terminate() async {
        guard let process, process.isRunning else {
            liveGroup.clear(); childPGID = 0; return
        }
        let pid = process.processIdentifier
        // Reap the whole process group (run.py + DeerFlow/OASIS grandchildren),
        // not just the direct child. `process.terminate()` covers the rare
        // no-setsid fallback where childPGID == 0.
        if childPGID > 0 { killpg(childPGID, SIGTERM) }
        process.terminate()                       // SIGTERM to the direct child
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
        status = .stopped
    }

    /// Best-effort merge of key/value pairs into MiroFish's root `.env`
    /// (`<repoRoot>/.env`, the file `config.py` loads with `override=True`).
    /// Used to persist the Zep key the user enters in Settings. Existing keys are
    /// updated in place; new keys are appended. Returns true on success.
    @discardableResult
    public func syncEnv(_ pairs: [String: String], repoRoot: URL) -> Bool {
        guard !pairs.isEmpty else { return true }
        let envURL = repoRoot.appendingPathComponent(".env")
        var lines: [String] = []
        if let existing = try? String(contentsOf: envURL, encoding: .utf8) {
            lines = existing.components(separatedBy: "\n")
        }
        var remaining = pairs
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            if let value = remaining[key] {
                lines[i] = "\(key)=\(Self.escapeEnvValue(value))"
                remaining.removeValue(forKey: key)
            }
        }
        for (k, v) in remaining { lines.append("\(k)=\(Self.escapeEnvValue(v))") }
        let output = lines.joined(separator: "\n")
        do {
            try output.write(to: envURL, atomically: true, encoding: .utf8)
            // This file holds API keys (Zep, LLM providers). Restrict it to the
            // owner — the default 0644 left secrets world-readable on shared Macs.
            // `atomically: true` writes via a temp file + rename, so permissions
            // must be (re)applied to the final path after the write.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                    ofItemAtPath: envURL.path)
            return true
        } catch {
            logTail = "Failed to update MiroFish .env: \(error.localizedDescription)"
            return false
        }
    }

    /// Render an `.env` value safely. API keys can contain `#`, spaces, `=`, or
    /// quotes that would corrupt an unquoted `KEY=VALUE` line (or, worse, a value
    /// with a newline could inject a second assignment) and break backend boot.
    /// Wrap in single quotes — which python-dotenv and shells treat literally — and
    /// escape any embedded single quote with the POSIX `'\''` idiom. Newlines and
    /// carriage returns are stripped (no legitimate API key contains them and they
    /// can't be represented inside a single-quoted line anyway).
    private static func escapeEnvValue(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let escaped = sanitized.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Setup script (onboarding)

    public enum SetupScriptError: Error, LocalizedError {
        case scriptMissing(String)
        case launchFailed(String)
        case exited(Int32)

        public var errorDescription: String? {
            switch self {
            case .scriptMissing(let path):
                return "setup.sh not found at \(path). Point Settings → Forecast at the MiroFish folder that contains it."
            case .launchFailed(let message):
                return "Couldn't launch setup.sh: \(message)"
            case .exited(let code):
                return "setup.sh exited with status \(code) — see the log above for the failing step."
            }
        }
    }

    /// Run MiroFish's `setup.sh` (idempotent installer: .env scaffold, backend
    /// venv on Python 3.12, DeerFlow clone + bridge overlay + venv) and stream
    /// its output line by line. stdin is /dev/null, so the script's interactive
    /// Zep prompt self-skips — the app injects the key via `syncEnv` instead.
    /// Cancelling the consuming task terminates the script.
    nonisolated public static func setupScriptStream(repoRoot: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let script = repoRoot.appendingPathComponent("setup.sh")
            guard FileManager.default.fileExists(atPath: script.path) else {
                continuation.finish(throwing: SetupScriptError.scriptMissing(script.path))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            process.currentDirectoryURL = repoRoot
            var env = ProcessInfo.processInfo.environment
            let home = env["HOME"] ?? NSHomeDirectory()
            env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin"]
                .joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            env["PYTHONUNBUFFERED"] = "1"
            process.environment = env
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in buffer.append(data) { continuation.yield(line) }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    for line in buffer.append(rest) { continuation.yield(line) }
                }
                if let tail = buffer.flush() { continuation.yield(tail) }
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: SetupScriptError.exited(proc.terminationStatus))
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: SetupScriptError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Splits a byte stream into text lines across chunk boundaries. The pipe's
    /// readability handler is serial per file handle, but the termination
    /// handler can race it, hence the lock.
    private final class LineBuffer: @unchecked Sendable {
        private var pending = ""
        private let lock = NSLock()

        func append(_ data: Data) -> [String] {
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            lock.lock(); defer { lock.unlock() }
            pending += text
            var lines: [String] = []
            while let nl = pending.firstIndex(of: "\n") {
                lines.append(String(pending[..<nl]))
                pending = String(pending[pending.index(after: nl)...])
            }
            return lines
        }

        func flush() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard !pending.isEmpty else { return nil }
            let tail = pending
            pending = ""
            return tail
        }
    }

    // MARK: - Environment repair

    public enum RepairError: Error, LocalizedError {
        case uvMissing
        case backendMissing(String)
        case stepFailed(step: String, log: String)
        case timedOut(step: String)

        public var errorDescription: String? {
            switch self {
            case .uvMissing:
                return "uv isn't installed. Install it with `curl -LsSf https://astral.sh/uv/install.sh | sh` (or `brew install uv`), then retry."
            case .backendMissing(let path):
                return "MiroFish backend not found at \(path). Set the correct MiroFish folder in Settings → Forecast."
            case .stepFailed(let step, let log):
                return "`\(step)` failed:\n\(String(log.suffix(500)))"
            case .timedOut(let step):
                return "`\(step)` didn't finish within 15 minutes — check your network and retry."
            }
        }
    }

    /// Re-provision the backend's Python environment: create the venv on
    /// Python 3.12 when it's missing/broken, then `uv sync` the dependencies.
    /// camel-ai + tiktoken don't build on 3.13, hence the pin. Slow (minutes on
    /// first run) — callers drive a progress UI off the returned log. Any backend
    /// we supervise is stopped first so the venv isn't replaced under it.
    public func repairEnvironment(repoRoot: URL) async throws -> String {
        let fm = FileManager.default
        let backendDir = repoRoot.appendingPathComponent("backend", isDirectory: true)
        guard fm.fileExists(atPath: backendDir.appendingPathComponent("run.py").path) else {
            throw RepairError.backendMissing(backendDir.path)
        }
        guard let uv = uvExecutable() else { throw RepairError.uvMissing }

        await terminate()

        var transcript = ""
        // Recreate the venv unless it already runs Python 3.12.
        if !(await venvIsPython312(backendDir: backendDir)) {
            try? fm.removeItem(at: backendDir.appendingPathComponent(".venv"))
            transcript += try await runRepairStep(
                executable: uv, arguments: ["venv", "--python", "3.12"],
                cwd: backendDir, label: "uv venv --python 3.12")
        }
        transcript += try await runRepairStep(
            executable: uv, arguments: ["sync"],
            cwd: backendDir, label: "uv sync")
        return transcript
    }

    private func uvExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                          home + "/.local/bin/uv", home + "/.cargo/bin/uv"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func venvIsPython312(backendDir: URL) async -> Bool {
        let python = backendDir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let process = Process()
        process.executableURL = python
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let version = String(data: data, encoding: .utf8) ?? ""
        return process.terminationStatus == 0 && version.contains("3.12")
    }

    /// Run one repair subprocess to completion (15-minute cap) and return its
    /// combined output. Throws `RepairError` on a non-zero exit or timeout.
    private func runRepairStep(executable: String, arguments: [String],
                               cwd: URL, label: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin"]
            .joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Drain the pipe off-actor so a chatty install can't fill the buffer
        // and deadlock the child.
        let drainTask = Task.detached { () -> String in
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }

        let deadline = ContinuousClock.now + .seconds(900)
        while process.isRunning {
            if ContinuousClock.now > deadline {
                process.terminate()
                drainTask.cancel()
                throw RepairError.timedOut(step: label)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let output = await drainTask.value
        guard process.terminationStatus == 0 else {
            throw RepairError.stepFailed(step: label, log: output)
        }
        return "$ \(label)\n" + output + "\n"
    }

    // MARK: - Interpreter resolution

    /// How to invoke `run.py`. Either a direct interpreter path, or `uv run`.
    private struct Invocation {
        let executable: String   // absolute path or bare name resolved via /usr/bin/env
        let prefixArgs: [String] // args before the script (e.g. ["run","--project",dir,"python"])
    }

    private func resolveInterpreter(backendDir: URL) -> Invocation? {
        let fm = FileManager.default
        // 1. The backend's own virtualenv (the documented setup).
        for rel in ["backend/.venv/bin/python", ".venv/bin/python"] {
            let candidate = backendDir.deletingLastPathComponent().appendingPathComponent(rel)
            if fm.isExecutableFile(atPath: candidate.path) {
                return Invocation(executable: candidate.path, prefixArgs: [])
            }
        }
        let directVenv = backendDir.appendingPathComponent(".venv/bin/python")
        if fm.isExecutableFile(atPath: directVenv.path) {
            return Invocation(executable: directVenv.path, prefixArgs: [])
        }
        // 2. Fall back to `uv run` if uv is installed anywhere obvious.
        let uvCandidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                            NSHomeDirectory() + "/.local/bin/uv", NSHomeDirectory() + "/.cargo/bin/uv"]
        if let uv = uvCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return Invocation(executable: uv,
                              prefixArgs: ["run", "--project", backendDir.path, "python"])
        }
        return nil
    }

    // MARK: - Launch

    private func launch(invocation: Invocation, backendDir: URL, port: Int) -> Status {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        logTail = ""
        // New launch generation: any appendLog Task still queued from the previous
        // child carries the old epoch and will be dropped (see `launchEpoch`).
        launchEpoch &+= 1
        let epoch = launchEpoch

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.currentDirectoryURL = backendDir

        // The real command we want to run.
        let realExec: String
        let realArgs: [String]
        if invocation.executable.hasPrefix("/") {
            realExec = invocation.executable
            realArgs = invocation.prefixArgs + ["run.py"]
        } else {
            realExec = "/usr/bin/env"
            realArgs = [invocation.executable] + invocation.prefixArgs + ["run.py"]
        }

        // Launch the backend as a NEW SESSION / process-group leader via a tiny
        // perl `setsid` shim, then `exec` the real command (preserving the pid).
        // Foundation's `Process` leaves the child in the app's own process group,
        // so MiroFish's DeerFlow/OASIS grandchildren reparent to launchd and keep
        // running after we SIGKILL only `run.py`. With `setsid`, the child's pgid
        // equals its pid and every descendant inherits it, so `killpg` reaps the
        // whole tree. `exec @ARGV` (list form) runs execvp directly — no shell, no
        // injection. Falls back to a direct launch if system perl is unavailable.
        let perl = "/usr/bin/perl"
        let useSetsid = FileManager.default.isExecutableFile(atPath: perl)
        if useSetsid {
            process.executableURL = URL(fileURLWithPath: perl)
            process.arguments = ["-e",
                                 "use POSIX qw(setsid); setsid(); exec @ARGV or die qq(exec failed: $!\\n);",
                                 "--", realExec] + realArgs
        } else {
            process.executableURL = URL(fileURLWithPath: realExec)
            process.arguments = realArgs
        }
        process.environment = childEnvironment(port: port)

        do {
            try process.run()
        } catch {
            logTail = "Failed to launch MiroFish backend: \(error.localizedDescription)"
            return .failed(logTail)
        }

        self.process = process
        self.stdoutPipe = pipe
        if useSetsid {
            // After setsid in the child, pgid == pid; this is the group to reap.
            childPGID = process.processIdentifier
            liveGroup.set(childPGID)
        } else {
            childPGID = 0
            liveGroup.clear()
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { return }
            Task { await self?.appendLog(text, epoch: epoch) }
        }
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { await self?.handleExit(code: code) }
        }
        return .launching
    }

    private func childEnvironment(port: Int) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin"]
        env["PATH"] = extraPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["PYTHONUNBUFFERED"] = "1"
        // Hint the port; MiroFish's run.py reads FLASK_PORT (its .env may still win).
        env["FLASK_PORT"] = String(port)
        return env
    }

    /// Append child stdout to `logTail`, dropping any text from a prior launch.
    /// `epoch == nil` is a synchronous in-actor caller (e.g. `drainPipeIntoLogTail`)
    /// that is already current by construction.
    private func appendLog(_ text: String, epoch: UInt64? = nil) {
        if let epoch, epoch != launchEpoch { return }   // stale child's output
        logTail = String((logTail + text).suffix(4096))
    }

    private func handleExit(code: Int32) {
        if code != 0 { logTail += "\n[backend exited \(code)]" }
        process = nil
        childPGID = 0
        liveGroup.clear()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
    }

    private func statusAfterExit() -> Status {
        if process?.isRunning == true { return .launching }
        let lower = logTail.lowercased()
        if lower.contains("modulenotfounderror") || lower.contains("no module named")
            || lower.contains("importerror") {
            return .failed("MiroFish backend couldn't import its dependencies — its venv likely needs re-provisioning on Python ≤3.12. Use “Repair environment” in Settings → Forecast (or run `cd backend && uv venv --python 3.12 && uv sync`).")
        }
        if lower.contains("address already in use") || lower.contains("errno 48") {
            return .failed("Port \(lastPort ?? 5001) is already taken by another process that isn't MiroFish. Quit it, or change the backend URL's port in Settings → Forecast.")
        }
        // run.py prints “配置错误:” + bullets and exits 1 when .env validation fails.
        if logTail.contains("配置错误") || logTail.contains("ZEP_API_KEY") {
            var detail = "MiroFish's .env is incomplete."
            if logTail.contains("ZEP_API_KEY") {
                detail = "MiroFish needs a Zep Cloud API key. Add it under Settings → API keys → Zep (free at app.getzep.com) — it syncs into MiroFish's .env automatically."
            } else if logTail.contains("LLM_API_KEY") {
                detail = "MiroFish's selected LLM provider needs an API key in its .env (LLM_API_KEY), or switch to a CLI-subscription provider in Settings → Forecast."
            }
            return .failed(detail)
        }
        return .failed(logTail.isEmpty ? "MiroFish backend exited before becoming healthy." : String(logTail.suffix(400)))
    }

    // MARK: - Health probing

    private func probeHealth(host: URL) async -> Bool {
        var req = URLRequest(url: host.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        req.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            // Don't attach to just *any* server answering 200 on /health (a
            // port-conflict false positive). Require the MiroFish signature: a
            // JSON body decodable as MFHealth, and — when it advertises a
            // `service` — that service must look like MiroFish. A foreign health
            // endpoint returning HTML or an unrelated service is rejected so we
            // surface a real port conflict instead of silently mis-attaching.
            guard let health = try? JSONDecoder().decode(MFHealth.self, from: data) else { return false }
            if let service = health.service?.lowercased(),
               !(service.contains("mirofish") || service.contains("deerflow") || service.contains("forecast")) {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Poll `/health` until it answers, the child exits, or ~120s elapses.
    /// MiroFish's cold start imports the heavy camel/zep stack, which is slow.
    private func waitForHealthOrExit(host: URL) async -> Bool {
        for _ in 0..<240 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await probeHealth(host: host) { return true }
            // Detect exit SYNCHRONOUSLY off the Process. The async `handleExit`
            // hop (which sets `process = nil`) can lag the OS exit by an unbounded
            // scheduling gap; waiting on `process == nil` would keep sleeping the
            // full ~120s after the child already died. `isRunning == false` is
            // observed the instant the OS reaps the child.
            if process?.isRunning == false { return false }
        }
        return false
    }

    /// Synchronously drain whatever is left in the backend's stdout/stderr pipe
    /// into `logTail`, so the diagnostic heuristics in `statusAfterExit` see the
    /// child's final ImportError/配置错误/port-taken output. Without this, a child
    /// that crashes instantly can exit before its async `appendLog` Tasks run,
    /// leaving `logTail` empty and producing the generic 'exited' message.
    private func drainPipeIntoLogTail() {
        // Only drain once the child has exited; while it's alive its streamed
        // output already flows through the readability handler.
        guard process?.isRunning != true, let pipe = stdoutPipe else { return }
        // Stop the readability handler first so it can't race this read, then read
        // what's already buffered. `availableData` returns immediately (it does NOT
        // block waiting for EOF the way `readToEnd()` would) — important because a
        // setsid descendant could still hold the pipe's write end open after the
        // direct child exited, and a blocking read would hang the actor.
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.availableData
        if !rest.isEmpty, let text = String(data: rest, encoding: .utf8) {
            appendLog(text)
        }
    }
}

/// Nonisolated, lock-protected holder of the supervised backend's process-group
/// id, so the synchronous `applicationWillTerminate` handler can reap the whole
/// DeerFlow/OASIS tree inline. An actor `await` can't complete before the app
/// process exits, so quit cleanup must not hop onto the actor.
final class ProcessGroupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pgid: pid_t = 0

    func set(_ p: pid_t) { lock.lock(); pgid = p; lock.unlock() }
    func clear() { lock.lock(); pgid = 0; lock.unlock() }

    /// Synchronous best-effort SIGTERM→SIGKILL of the entire process group.
    /// Safe to call on the main thread at quit; bounded by a short fixed grace.
    func reap() {
        lock.lock(); let p = pgid; lock.unlock()
        guard p > 0 else { return }
        killpg(p, SIGTERM)
        usleep(200_000)          // 200ms grace for a clean Flask shutdown
        killpg(p, SIGKILL)
    }
}

/// Nonisolated, lock-protected holder of the `willTerminate` observer token so the
/// actor's nonisolated `deinit` can deregister it. `NotificationCenter` is
/// thread-safe; the token is an opaque reference, so this is safe to drop from any
/// isolation.
final class ObserverTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func set(_ t: NSObjectProtocol) { lock.lock(); token = t; lock.unlock() }

    func remove() {
        lock.lock(); let t = token; token = nil; lock.unlock()
        if let t { NotificationCenter.default.removeObserver(t) }
    }
}
