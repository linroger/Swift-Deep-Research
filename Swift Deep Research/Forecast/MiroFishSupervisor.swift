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
    private var quitObserver: NSObjectProtocol?
    private(set) var status: Status = .stopped
    /// Coalesce concurrent `ensureRunning` callers onto one launch.
    private var ensureTask: Task<Status, Never>?

    private init() {
        Task { await registerTermination() }
    }

    private func registerTermination() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Task { await MiroFishSupervisor.shared.terminate() }
        }
        self.quitObserver = token
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
        let launched = launch(invocation: invocation, backendDir: backendDir,
                              port: host.port ?? 5001)
        guard case .launching = launched else { status = launched; return launched }
        let up = await waitForHealthOrExit(host: host)
        status = up ? .running : statusAfterExit()
        return status
    }

    /// Stop a backend this supervisor started. (No-op if we attached to an
    /// externally-run backend.)
    public func terminate() async {
        guard let process, process.isRunning else { return }
        process.terminate()                       // SIGTERM
        for _ in 0..<20 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
                lines[i] = "\(key)=\(value)"
                remaining.removeValue(forKey: key)
            }
        }
        for (k, v) in remaining { lines.append("\(k)=\(v)") }
        let output = lines.joined(separator: "\n")
        do {
            try output.write(to: envURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            logTail = "Failed to update MiroFish .env: \(error.localizedDescription)"
            return false
        }
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

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.currentDirectoryURL = backendDir

        if invocation.executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: invocation.executable)
            process.arguments = invocation.prefixArgs + ["run.py"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [invocation.executable] + invocation.prefixArgs + ["run.py"]
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
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { return }
            Task { await self?.appendLog(text) }
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

    private func appendLog(_ text: String) {
        logTail = String((logTail + text).suffix(4096))
    }

    private func handleExit(code: Int32) {
        if code != 0 { logTail += "\n[backend exited \(code)]" }
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
    }

    private func statusAfterExit() -> Status {
        if process?.isRunning == true { return .launching }
        let lower = logTail.lowercased()
        if lower.contains("modulenotfounderror") || lower.contains("no module named")
            || lower.contains("importerror") {
            return .failed("MiroFish backend couldn't import its dependencies — its venv likely needs re-provisioning on Python ≤3.12 (`cd backend && uv venv --python 3.12 && uv sync`).")
        }
        return .failed(logTail.isEmpty ? "MiroFish backend exited before becoming healthy." : String(logTail.suffix(400)))
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

    /// Poll `/health` until it answers, the child exits, or ~120s elapses.
    /// MiroFish's cold start imports the heavy camel/zep stack, which is slow.
    private func waitForHealthOrExit(host: URL) async -> Bool {
        for _ in 0..<240 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await probeHealth(host: host) { return true }
            if process == nil { return false }   // exited
        }
        return false
    }
}
