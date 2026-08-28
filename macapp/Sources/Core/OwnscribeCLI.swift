import Foundation

enum CLIError: Error {
    case command(String, String)
    case decode
}

/// Drives a self-managed `ownscribe` install — no dev checkout required. The app keeps
/// its own virtual environment under Application Support and, on first launch, installs
/// ownscribe into it with `uv`. Everything else (record/transcribe/summarize, config,
/// speaker naming) goes through that CLI, so `~/.config/ownscribe/config.toml` stays the
/// single source of truth.
final class OwnscribeCLI {
    /// ~/Library/Application Support/Ownscribe
    static var managedRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ownscribe", isDirectory: true)
    }

    private var venvDir: URL { Self.managedRoot.appendingPathComponent(".venv", isDirectory: true) }

    /// Git ref installed on first launch. Must be an **immutable tag**, never a branch:
    /// a branch ref silently changes what new users get, and deleting it breaks first-run
    /// install permanently (this pointed at `feature/macos-menubar-ui` until that branch
    /// was merged into main).
    ///
    /// The `macapp-` prefix keeps these tags out of upstream's `v*` namespace — upstream
    /// tags are fetched into this repo, so an unprefixed `v0.15.1` here would collide with
    /// paberr's release of the same name.
    ///
    /// PyPI `ownscribe` is published by upstream (paberr) and does not carry the GUI's CLI
    /// additions (config get/set, list/rename-speakers), so this has to stay a git spec
    /// until those land upstream.
    ///
    /// To cut a release: `git tag macapp-vX.Y.Z && git push origin macapp-vX.Y.Z`,
    /// then bump the ref below in the same commit that bumps CFBundleShortVersionString
    /// in build-app.sh.
    private static let macappRelease = "macapp-v0.15.0"

    private static let pipSpec =
        "ownscribe[all] @ git+https://github.com/alanderex/ownscribe@\(macappRelease)"

    /// The ownscribe console script in the managed venv, if installed. Running it directly
    /// (not via a shell) lets us deliver SIGINT to the real Python process for a clean Stop.
    var cliURL: URL? {
        let candidate = venvDir.appendingPathComponent("bin/ownscribe")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    var isInstalled: Bool { cliURL != nil }

    @discardableResult
    func run(_ args: [String]) async -> CommandResult {
        guard let cli = cliURL else {
            return CommandResult(stdout: "", stderr: "ownscribe is not installed yet.", exitCode: -1)
        }
        return await CommandRunner.run(executable: cli, args: args, cwd: Self.managedRoot)
    }

    /// Launch the full record→transcribe→summarize pipeline. SIGINT to the returned
    /// process stops recording and lets it continue to transcription + summarization.
    func launchPipeline(
        flags: [String],
        onEvent: ((ProgressEvent) -> Void)? = nil,
        onExit: @escaping (CommandResult) -> Void
    ) -> RunningProcess? {
        guard let cli = cliURL else { return nil }
        return CommandRunner.launch(
            executable: cli, args: flags, cwd: Self.managedRoot,
            onEvent: onEvent, onExit: onExit
        )
    }

    /// First-run setup: create the managed venv and install ownscribe into it with `uv`.
    /// Run through a login shell so `uv` is found on the user's PATH.
    func install() async -> CommandResult {
        try? FileManager.default.createDirectory(
            at: Self.managedRoot, withIntermediateDirectories: true)
        let script = """
        set -e
        if ! command -v uv >/dev/null 2>&1; then
          echo "uv is required but was not found. Install it from https://docs.astral.sh/uv/ (e.g. 'brew install uv')." >&2
          exit 127
        fi
        uv venv "\(venvDir.path)"
        uv pip install --python "\(venvDir.path)/bin/python" "\(Self.pipSpec)"
        """
        return await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            args: ["-lc", script],
            cwd: Self.managedRoot
        )
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
