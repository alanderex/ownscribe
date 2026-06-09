import Foundation

enum CLIError: Error {
    case command(String, String)
    case decode
}

/// Thin wrapper that drives the existing `ownscribe` CLI. Everything the app
/// does — recording, transcribing, summarizing, reading/writing config, naming
/// speakers — goes through the CLI, so config.toml stays the single source of
/// truth and the GUI never reimplements pipeline logic.
final class OwnscribeCLI {
    var projectDirectory: URL

    init(projectDirectory: URL) {
        self.projectDirectory = projectDirectory
    }

    /// The console script inside the project's uv venv, if present. Running it
    /// directly (rather than via a shell) lets us deliver SIGINT to the real
    /// Python process for a clean Stop.
    var cliURL: URL? {
        let candidate = projectDirectory.appendingPathComponent(".venv/bin/ownscribe")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Recording requires the direct venv binary so Stop can signal it.
    var isConfigured: Bool { cliURL != nil }

    private func resolve(_ args: [String]) -> (URL, [String]) {
        if let cli = cliURL {
            return (cli, args)
        }
        // Fallback for read-only commands when the venv isn't found: a login
        // shell picks up PATH (uv, pipx, …). Not used for recording.
        let joined = (["ownscribe"] + args).map(Self.shellQuote).joined(separator: " ")
        return (URL(fileURLWithPath: "/bin/zsh"), ["-lc", joined])
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    func run(_ args: [String]) async -> CommandResult {
        let (exe, resolvedArgs) = resolve(args)
        return await CommandRunner.run(executable: exe, args: resolvedArgs, cwd: projectDirectory)
    }

    /// Launch the full record→transcribe→summarize pipeline (bare `ownscribe`
    /// plus per-run flags). SIGINT to the returned process stops recording and
    /// lets it continue to transcription + summarization.
    func launchPipeline(flags: [String], onExit: @escaping (CommandResult) -> Void) -> RunningProcess {
        let (exe, resolvedArgs) = resolve(flags)
        return CommandRunner.launch(executable: exe, args: resolvedArgs, cwd: projectDirectory, onExit: onExit)
    }

    // MARK: - High-level helpers

    func loadConfig() async throws -> OwnscribeConfig {
        let result = await run(["config", "get"])
        guard result.ok else { throw CLIError.command("config get", result.stderr) }
        guard let data = result.stdout.data(using: .utf8) else { throw CLIError.decode }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OwnscribeConfig.self, from: data)
    }

    @discardableResult
    func setConfig(_ key: String, _ value: String) async -> CommandResult {
        await run(["config", "set", key, value])
    }

    func listSpeakers(_ transcript: URL) async -> [String] {
        let result = await run(["list-speakers", transcript.path])
        guard result.ok,
              let data = result.stdout.data(using: .utf8),
              let labels = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return labels
    }

    @discardableResult
    func renameSpeakers(_ transcript: URL, mapping: [String: String]) async -> CommandResult {
        var args = ["rename-speakers", transcript.path]
        for (label, name) in mapping {
            args += ["--map", "\(label)=\(name)"]
        }
        return await run(args)
    }
}
