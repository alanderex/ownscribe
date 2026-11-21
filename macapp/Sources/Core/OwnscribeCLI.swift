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
    /// ~/Library/Application Support/<name>, where <name> comes from the bundle's
    /// `OWSManagedRootName` key and defaults to "Ownscribe".
    ///
    /// A side-by-side build (build-app.sh --variant) sets a different name so it gets
    /// its own virtual environment. Without that, a variant would share — and upgrade —
    /// the stable app's env, so a bad CLI change would take out the very build being
    /// kept as a fallback.
    static var managedRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(managedRootName, isDirectory: true)
    }

    private static let stableRootName = "Ownscribe"

    private static var managedRootName: String {
        (Bundle.main.object(forInfoDictionaryKey: "OWSManagedRootName") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? stableRootName
    }

    /// True for a side-by-side build (`build-app.sh --variant`), the only kind that
    /// honours `cliSpecOverrideKey`. Keyed off the managed root because that is what
    /// keeps a variant's environment apart from the stable app's.
    static var isVariantBuild: Bool { managedRootName != stableRootName }

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
    /// To cut a release: bump the ref below in the same commit that bumps the app
    /// version (CFBundleShortVersionString in build-app.sh, MARKETING_VERSION in
    /// project.yml), open a pull request to main, and once CI is green, tag that
    /// commit as an annotated `macapp-vX.Y.Z`, push the tag, then fast-forward main.
    /// The tag is on origin before anyone builds a bundle that names it; until then
    /// a variant build tries the CLI through OWNSCRIBE_CLI_SPEC.
    ///
    /// Never move an existing tag. needsUpgrade compares the spec built from it with
    /// the one recorded beside the installed venv, so a moved tag leaves every
    /// existing install on the CLI it already had while claiming to be current. v0.15.1 was
    /// moved several times during development; every tag from v0.15.2 on is fixed.
    ///
    /// Bump this whenever a Python-side change must reach installed apps — the tag
    /// named here is what a menu-bar install actually runs, so a fix that is merged
    /// but not tagged reaches nobody. v0.15.2 predates helper checksum verification;
    /// v0.15.3 is the first tag that contains it. v0.16.0 is the first with `show`
    /// and the folder events the window relies on.
    ///
    /// This is deliberately NOT the app's own version. CFBundleShortVersionString
    /// tracks the bundle; this tracks the CLI the bundle installs. A Swift-only
    /// release bumps the former and leaves this alone — otherwise needsUpgrade
    /// fires and every user reinstalls ownscribe for no change at all.
    static let macappRelease = "macapp-v0.16.0"

    private static let pipSpec =
        "ownscribe[all] @ git+https://github.com/alanderex/ownscribe@\(macappRelease)"

    /// `defaults` key with a pip requirement that a variant build installs instead of
    /// the release tag, so an unreleased CLI can be tried before its tag exists:
    ///
    ///     defaults write dev.p4l.ownscribe.menubar.next OWNSCRIBE_CLI_SPEC \
    ///       -string "ownscribe[all] @ file:///path/to/checkout"
    ///
    /// A `defaults` key rather than an environment variable: `open`, which
    /// build-app.sh --run uses, does not pass the environment to the app. The stable
    /// build ignores it, so a stray key can never change what users run.
    static let cliSpecOverrideKey = "OWNSCRIBE_CLI_SPEC"

    /// What install() installs and the stamp must match: the override in a variant
    /// build that sets one, the release tag otherwise. Removing the key therefore
    /// triggers a normal upgrade back to the tag.
    static var installSpec: String {
        if isVariantBuild,
           let override = UserDefaults.standard.string(forKey: cliSpecOverrideKey)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return pipSpec
    }

    /// The ownscribe console script in the managed venv, if installed. Running it directly
    /// (not via a shell) lets us deliver SIGINT to the real Python process for a clean Stop.
    /// The venv's console script, whether or not it is installed yet. Processes
    /// with this path in their command line run from this environment.
    var scriptPath: String { venvDir.appendingPathComponent("bin/ownscribe").path }

    var cliURL: URL? {
        let candidate = venvDir.appendingPathComponent("bin/ownscribe")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    var isInstalled: Bool { cliURL != nil }

    /// Spec recorded alongside the venv at install time. Compared against
    /// installSpec to notice that the app wants a different CLI. Stamps written
    /// before this held only the tag name, so those installs upgrade once.
    private var stampURL: URL { Self.managedRoot.appendingPathComponent("installed-ref") }

    private var installedSpec: String? {
        try? String(contentsOf: stampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the managed venv holds a CLI older than this app expects.
    ///
    /// isInstalled only ever asked "does the executable exist", and install() ran on
    /// first launch alone — so shipping a new app with a bumped macappRelease left
    /// every existing user on the CLI they first installed, silently. A venv with no
    /// stamp predates this check and is treated as needing an upgrade.
    var needsUpgrade: Bool {
        guard isInstalled else { return false }
        return installedSpec != Self.installSpec
    }

    private func recordInstalled(_ spec: String) {
        try? spec.write(to: stampURL, atomically: true, encoding: .utf8)
    }

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
    ///
    /// Upgrades reinstall the ownscribe package only. Every macapp tag carries the
    /// same pyproject version, so without a forced reinstall uv would keep the old
    /// code; `--reinstall` forced it for every dependency too, reinstalling the whole
    /// multi-GB ML stack each time. uv resolves and builds before it touches the
    /// venv, so a failed upgrade (missing tag, build error, no network) leaves the
    /// installed CLI runnable.
    func install() async -> CommandResult {
        try? FileManager.default.createDirectory(
            at: Self.managedRoot, withIntermediateDirectories: true)
        // Read once: the stamp must name what was actually installed.
        let spec = Self.installSpec
        // The venv path and the spec are passed as $1 and $2, never spliced into the
        // script: the override is free text and must not be read as shell.
        let script = """
        set -e
        if ! command -v uv >/dev/null 2>&1; then
          echo "uv is required but was not found. Install it from https://docs.astral.sh/uv/ (e.g. 'brew install uv')." >&2
          exit 127
        fi
        [ -x "$1/bin/python" ] || uv venv "$1"
        uv pip install --reinstall-package ownscribe --python "$1/bin/python" "$2"
        """
        let result = await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            args: ["-lc", script, "ownscribe-install", venvDir.path, spec],
            cwd: Self.managedRoot
        )
        if result.ok { recordInstalled(spec) }
        return result
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

    /// One meeting folder as `show DIR --json` describes it; the decoding runs off
    /// the main actor.
    func show(_ folder: URL) async throws -> MeetingDocument {
        let result = await run(["show", folder.path, "--json"])
        guard result.ok else {
            throw CLIError.command("show", FailureText.firstMeaningfulLine(result.stderr) ?? "exit \(result.exitCode)")
        }
        let data = Data(result.stdout.utf8)
        return try await Task.detached { try MeetingDocument.decode(data) }.value
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
