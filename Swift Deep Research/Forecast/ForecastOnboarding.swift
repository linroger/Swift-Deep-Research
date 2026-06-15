import Foundation
import Observation

/// Drives the first-run Forecast setup flow: inspect the machine, run the repo's
/// idempotent `setup.sh` with a live console, then launch the backend and verify
/// health. The knowledge graph runs locally (Graphiti + embedded FalkorDB), so
/// there is no graph credential to collect here.
///
/// The model is recreated each time the onboarding sheet opens, so all state is
/// per-presentation; only the "completed" flag persists (UserDefaults).
@MainActor
@Observable
public final class ForecastOnboarding {

    // MARK: - Environment checks

    public enum CheckState: Sendable { case pass, warn, fail }

    public struct Check: Sendable, Identifiable {
        public let id: String        // stable key, doubles as sort order
        public let title: String
        public let detail: String
        public let state: CheckState
    }

    public enum SetupPhase: Equatable, Sendable {
        case idle, running, succeeded
        case failed(String)
    }

    public private(set) var checks: [Check] = []
    public private(set) var checking = false

    public private(set) var setupPhase: SetupPhase = .idle
    public private(set) var consoleLines: [String] = []

    public private(set) var launching = false
    public private(set) var backendStatus: MiroFishSupervisor.Status = .stopped
    public private(set) var completed = false

    private let config: ForecastConfiguration
    private var setupTask: Task<Void, Never>?

    public init(config: ForecastConfiguration) {
        self.config = config
    }

    /// Everything the *backend pipeline* needs is already in place — the setup
    /// script would be a no-op apart from dependency refreshes.
    public var looksProvisioned: Bool {
        repoOK && backendVenvOK && deerflowOK
    }

    public var repoRoot: URL { config.repoRoot }

    // MARK: Persistent completion flag

    private static let completedKey = "forecastOnboardingCompleted.v1"
    public static var hasCompletedOnce: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }
    private static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    // MARK: - Checks

    public func refreshChecks() async {
        checking = true
        defer { checking = false }

        let envValues = Self.parseEnv(at: repoRoot.appendingPathComponent(".env"))

        var result: [Check] = []

        // 1. The MiroFish checkout itself.
        if repoOK {
            result.append(Check(id: "1-repo", title: "MiroFish folder",
                                detail: repoRoot.path, state: .pass))
        } else {
            result.append(Check(id: "1-repo", title: "MiroFish folder",
                                detail: "backend/run.py + setup.sh not found at \(repoRoot.path). Pick the right folder in Settings → Forecast.",
                                state: .fail))
        }

        // 2. uv — the only hard tool requirement (builds both Python venvs).
        if let uv = Self.findExecutable("uv") {
            result.append(Check(id: "2-uv", title: "uv", detail: uv, state: .pass))
        } else {
            result.append(Check(id: "2-uv", title: "uv",
                                detail: "Not found. Install with `curl -LsSf https://astral.sh/uv/install.sh | sh` or `brew install uv`.",
                                state: .fail))
        }

        // 3. git — needed only if DeerFlow still has to be cloned.
        if Self.findExecutable("git") != nil {
            result.append(Check(id: "3-git", title: "git", detail: "Available", state: .pass))
        } else {
            result.append(Check(id: "3-git", title: "git",
                                detail: deerflowOK
                                    ? "Not found, but DeerFlow is already downloaded — fine."
                                    : "Not found. Needed to download the DeerFlow research engine (or install Xcode command-line tools).",
                                state: deerflowOK ? .pass : .fail))
        }

        // 4. Model provider for simulation/report + research.
        let hasClaude = Self.findExecutable("claude") != nil
        let hasCodex = Self.findExecutable("codex") != nil
        let provider = envValues["LLM_PROVIDER"] ?? ""
        let hasAPIKey = Self.isRealValue(envValues["LLM_API_KEY"])
        if hasClaude || hasCodex {
            result.append(Check(id: "4-llm", title: "Model provider",
                                detail: hasClaude ? "Claude Code CLI detected — no API key needed."
                                                  : "Codex CLI detected — no API key needed.",
                                state: .pass))
        } else if !provider.isEmpty, !provider.hasSuffix("-cli"), hasAPIKey {
            result.append(Check(id: "4-llm", title: "Model provider",
                                detail: "\(provider) configured in .env.", state: .pass))
        } else {
            result.append(Check(id: "4-llm", title: "Model provider",
                                detail: "No claude/codex CLI found and no API provider in .env. Install Claude Code, or pick an API provider in Settings → Forecast after the backend starts.",
                                state: .warn))
        }

        // 5. Knowledge graph — now runs locally (Graphiti + embedded FalkorDB),
        //    so there's no cloud account or API key to configure.
        result.append(Check(id: "5-graph", title: "Knowledge graph",
                            detail: "Runs locally via Graphiti + embedded FalkorDB — no API key required. The first forecast downloads a ~470MB multilingual embedding model once.",
                            state: .pass))

        // 6–7. What setup.sh will build (informational before the run).
        result.append(Check(id: "6-venv", title: "Backend Python env",
                            detail: backendVenvOK
                                ? "backend/.venv ready (Python 3.12)."
                                : "Not built yet — the setup script creates it (Python 3.12, camel-ai stack).",
                            state: backendVenvOK ? .pass : .warn))
        result.append(Check(id: "7-deerflow", title: "DeerFlow research engine",
                            detail: deerflowOK
                                ? deerflowDir.path
                                : "Not downloaded yet — the setup script clones and patches it.",
                            state: deerflowOK ? .pass : .warn))

        checks = result.sorted { $0.id < $1.id }
    }

    /// Hard blockers for running the setup script at all.
    public var canRunSetup: Bool {
        repoOK && Self.findExecutable("uv") != nil
    }

    private var repoOK: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: repoRoot.appendingPathComponent("backend/run.py").path)
            && fm.fileExists(atPath: repoRoot.appendingPathComponent("setup.sh").path)
    }

    private var backendVenvOK: Bool {
        // The venv layout includes a `python3.12` shim iff it was built on 3.12,
        // which makes this an accurate check without spawning a process.
        FileManager.default.isExecutableFile(
            atPath: repoRoot.appendingPathComponent("backend/.venv/bin/python3.12").path)
    }

    private var deerflowDir: URL {
        let envValues = Self.parseEnv(at: repoRoot.appendingPathComponent(".env"))
        if let custom = envValues["DEERFLOW_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return repoRoot.appendingPathComponent("deer-flow")
    }

    private var deerflowOK: Bool {
        FileManager.default.fileExists(atPath: deerflowDir.appendingPathComponent("deerflow_research.py").path)
    }

    // MARK: - Setup script

    public func runSetup() {
        guard setupPhase != .running, canRunSetup else { return }
        setupPhase = .running
        consoleLines = ["$ bash setup.sh    (\(repoRoot.path))", ""]
        let root = repoRoot
        setupTask = Task { @MainActor [weak self] in
            do {
                for try await line in MiroFishSupervisor.setupScriptStream(repoRoot: root) {
                    guard let self, !Task.isCancelled else { return }
                    self.appendConsole(line)
                }
                guard let self else { return }
                self.setupPhase = .succeeded
                self.appendConsole("✓ setup.sh finished.")
                await self.refreshChecks()
            } catch {
                guard let self else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.setupPhase = .failed(message)
                self.appendConsole("✗ \(message)")
                await self.refreshChecks()
            }
        }
    }

    public func cancelSetup() {
        setupTask?.cancel()
        setupTask = nil
        if setupPhase == .running {
            setupPhase = .failed("Setup cancelled.")
            appendConsole("✗ Cancelled.")
        }
    }

    private func appendConsole(_ line: String) {
        // Progress-bar output (uv/npm) rewrites lines with \r; keep only the
        // final rendition so the console stays readable.
        var cleaned = line
        if let lastCR = cleaned.lastIndex(of: "\r") {
            cleaned = String(cleaned[cleaned.index(after: lastCR)...])
        }
        consoleLines.append(cleaned)
        if consoleLines.count > 600 { consoleLines.removeFirst(consoleLines.count - 600) }
    }

    // MARK: - Backend launch

    /// Final step: launch the backend and wait for `/health`. The knowledge graph
    /// runs locally (Graphiti), so there's no credential to sync first.
    public func startBackend() async -> MiroFishSupervisor.Status {
        launching = true
        defer { launching = false }
        let status = await MiroFishSupervisor.shared.ensureRunning(host: config.host, repoRoot: repoRoot)
        backendStatus = status
        if case .running = status {
            completed = true
            Self.markCompleted()
        }
        return status
    }

    // MARK: - Helpers

    private nonisolated static func findExecutable(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                    home + "/.local/bin", home + "/.cargo/bin", home + "/.bun/bin",
                    home + "/.claude/local"]
        for dir in dirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Minimal `.env` reader: active `KEY=VALUE` lines only, comments skipped.
    private nonisolated static func parseEnv(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    /// A value counts only when it isn't empty and isn't an .env.example
    /// placeholder ("your_zep_api_key_here", "your-key", …).
    private nonisolated static func isRealValue(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let lower = value.lowercased()
        return !(lower.hasPrefix("your_") || lower.hasPrefix("your-") || lower.contains("_here"))
    }
}
