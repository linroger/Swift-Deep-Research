import Foundation
import AppKit

/// Auto-launches the pyseekdb sidecar so users don't have to start it from a
/// terminal. Behaviour:
///   1. Probe `/health` once. If it responds, do nothing.
///   2. Otherwise locate `seekdb_sidecar.py` (bundled in Resources for release
///      builds; falls back to the project root for dev runs from DerivedData).
///   3. Spawn `python3 seekdb_sidecar.py --port N` as a child process and keep
///      a `Process` handle so we can terminate it on app quit.
///   4. Poll `/health` for up to ~12 seconds. Return the resolved status.
///
/// Failure modes are surfaced as `Status` values so the UI can show a useful
/// diagnostic (no Python found, dependencies missing, script missing).
public actor SidecarSupervisor {
    public static let shared = SidecarSupervisor()

    public enum Status: Sendable, Equatable {
        case running                       // sidecar responding to /health
        case launching                     // process spawned, /health not yet up
        case notInstalled(String)          // python missing / pip deps missing
        case scriptMissing                 // can't find seekdb_sidecar.py
        case failed(String)                // process exited / unknown error
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var lastError: String?
    private var quitObserver: NSObjectProtocol?

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

    /// Ensure the sidecar is reachable at `host`. Returns the current status.
    /// Safe to call repeatedly — only spawns once per process lifetime.
    @discardableResult
    public func ensureRunning(host: URL, port: Int? = nil) async -> Status {
        if await probeHealth(host: host) { return .running }

        // Already supervising — just wait for it to come up.
        if let process, process.isRunning {
            return await waitForHealth(host: host) ? .running : .launching
        }

        guard let script = locateScript() else {
            lastError = "seekdb_sidecar.py not found in app bundle or project tree"
            return .scriptMissing
        }
        let resolvedPort = port ?? host.port ?? 9100
        let result = launch(script: script, port: resolvedPort)
        if case .launching = result {
            return await waitForHealth(host: host) ? .running : result
        }
        return result
    }

    /// Best-effort termination. Called from app-quit notification and tests.
    public func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        // Give uvicorn ~1s to wind down; if it doesn't, SIGKILL.
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Launch plumbing

    private func launch(script: URL, port: Int) -> Status {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let python = resolvePython()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [python, script.path, "--port", String(port)]

        // Inherit PATH and add the common pyenv / Homebrew locations so
        // `python3` resolution works even when launched from Finder where the
        // PATH is the minimal `/usr/bin:/bin:/usr/sbin:/sbin`.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin", "/usr/local/bin",
            (env["HOME"] ?? "") + "/.pyenv/shims",
            (env["HOME"] ?? "") + "/.pyenv/versions/3.12.6/bin"
        ]
        let path = (env["PATH"] ?? "") + ":" + extraPaths.joined(separator: ":")
        env["PATH"] = path
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        do {
            try process.run()
        } catch {
            lastError = "Failed to spawn python3: \(error.localizedDescription)"
            return .notInstalled(lastError ?? "unknown")
        }

        self.process = process
        self.stdoutPipe = pipe

        // Capture early stderr/stdout so a missing-dependencies failure
        // surfaces in the UI rather than disappearing into the void.
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

    private func appendLog(_ text: String) {
        // Keep the most recent ~2 KB so the UI has actionable diagnostics if
        // python failed for a reason like "ModuleNotFoundError: pyseekdb".
        let combined = (lastError ?? "") + text
        lastError = String(combined.suffix(2048))
    }

    private func handleExit(status: Int32) {
        if status != 0 {
            lastError = (lastError ?? "") + "\n[exit \(status)]"
        }
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
    }

    private func resolvePython() -> String {
        // `/usr/bin/env python3` works on macOS 13+ because Apple ships a
        // python3 shim by default. pyenv users get their version because PATH
        // is augmented above. We pass "python3" as the env argv.
        "python3"
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

    private func waitForHealth(host: URL) async -> Bool {
        // Poll up to ~12s — embedded pyseekdb takes 1–2s to initialise.
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await probeHealth(host: host) { return true }
        }
        return false
    }

    // MARK: - Script discovery

    private func locateScript() -> URL? {
        if let bundled = Bundle.main.url(forResource: "seekdb_sidecar",
                                         withExtension: "py") {
            return bundled
        }
        // Dev fallback: walk up from the bundle path looking for sidecar/.
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("sidecar/seekdb_sidecar.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        // Last-ditch: the canonical project path during development.
        let dev = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("XCode-Projects/Swift-Deep-Research/sidecar/seekdb_sidecar.py")
        if FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }
        return nil
    }

    // MARK: - Public diagnostics

    public func diagnostics() -> String? { lastError }
}
