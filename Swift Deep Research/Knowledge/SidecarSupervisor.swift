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
    private(set) var status: Status = .launching

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

    /// Absolute path to the Python that should launch the sidecar. Prefer the
    /// managed venv (it has the deps); otherwise let `/usr/bin/env` resolve
    /// `python3` from PATH.
    private var preferredPython: String { hasVenv ? venvPython.path : "python3" }

    // MARK: - Public API

    /// Ensure the sidecar is reachable at `host`. Returns the current status.
    /// Safe to call repeatedly — only spawns once per process lifetime.
    @discardableResult
    public func ensureRunning(host: URL, port: Int? = nil) async -> Status {
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

        // Attempt 1 — best available Python.
        var result = await launchAndWait(script: script, port: resolvedPort,
                                         host: host, python: preferredPython)
        if case .running = result { return result }

        // Attempt 2 — if it died for want of dependencies, build a venv once
        // and relaunch from it.
        if needsDependencies && !didAttemptBootstrap {
            didAttemptBootstrap = true
            status = .installingDependencies
            let installed = await installDependencies()
            if installed {
                result = await launchAndWait(script: script, port: resolvedPort,
                                            host: host, python: venvPython.path)
            } else {
                result = .notInstalled(lastError ?? "Failed to install Python dependencies.")
            }
        }
        status = result
        return result
    }

    /// Force a dependency (re)install + relaunch. Exposed for a manual
    /// "repair" action in Settings.
    @discardableResult
    public func reinstallAndStart(host: URL, port: Int? = nil) async -> Status {
        terminate()
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

    /// Best-effort termination. Called from app-quit notification and tests.
    public func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Launch plumbing

    /// True when the captured child output indicates a missing Python module.
    private var needsDependencies: Bool {
        guard let e = lastError?.lowercased() else { return false }
        return e.contains("modulenotfounderror")
            || e.contains("no module named")
            || e.contains("importerror")
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
    /// resolves even when launched from Finder (minimal PATH).
    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let extraPaths = [
            "/opt/homebrew/bin", "/usr/local/bin",
            home + "/.pyenv/shims",
            home + "/.pyenv/versions/3.12.6/bin"
        ]
        env["PATH"] = (env["PATH"] ?? "") + ":" + extraPaths.joined(separator: ":")
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
            let (code, out) = await runProcess(
                executable: "/usr/bin/env",
                args: ["python3", "-m", "venv", venvDir.path])
            if code != 0 {
                lastError = "venv creation failed:\n" + String(out.suffix(1500))
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
            lastError = "pip install failed:\n" + String(out.suffix(2000))
            return false
        }
        return true
    }

    /// Run a process to completion off the actor's thread, capturing a tail of
    /// its combined output. Used for venv/pip steps which are slow.
    private func runProcess(executable: String, args: [String]) async -> (Int32, String) {
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
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                    buffer.append(s)
                }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (proc.terminationStatus, buffer.value()))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (-1, "spawn failed: \(error.localizedDescription)"))
            }
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

    /// Poll `/health` up to ~15s, but bail out early if the child process has
    /// already exited (e.g. ModuleNotFoundError) so we don't wait the full
    /// window on a launch that already failed.
    private func waitForHealthOrExit(host: URL) async -> Bool {
        for _ in 0..<30 {
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
