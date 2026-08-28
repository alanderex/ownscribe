import Foundation

struct CommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var ok: Bool { exitCode == 0 }
}

/// One progress event from the CLI (OWNSCRIBE_PROGRESS_EVENTS=1), decoded from a
/// single NDJSON line on stderr. Field presence varies by `event`, so everything
/// past the discriminator is optional.
struct ProgressEvent: Decodable {
    struct Step: Decodable {
        let key: String
        let label: String
        let indent: Int
    }

    let event: String
    let key: String?
    let label: String?
    let indent: Int?
    let fraction: Double?
    let text: String?
    let steps: [Step]?
    let ok: Bool?
    let reason: String?

    /// Discriminator written by ownscribe.progress; absent on ordinary stderr.
    let ownscribeProgress: Int

    enum CodingKeys: String, CodingKey {
        case event, key, label, indent, fraction, text, steps, ok, reason
        case ownscribeProgress = "ownscribe_progress"
    }
}

/// Thread-safe byte accumulator for pipe reads (handlers fire off the main thread).
///
/// Also splits the stream into complete lines as it arrives, so a caller can react
/// to progress while the process is still running rather than at exit. Partial
/// trailing bytes are held back until their newline turns up — a pipe read can land
/// mid-line, and mid-UTF-8-sequence.
private final class OutputBuffer {
    private var data = Data()
    private var pending = Data()
    private let lock = NSLock()

    /// Appends a chunk and returns any newly completed lines.
    @discardableResult
    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        pending.append(chunk)

        var lines: [String] = []
        while let idx = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<idx]
            pending = pending[pending.index(after: idx)...]
            lines.append(String(decoding: line, as: UTF8.self))
        }
        // `pending` is a slice after the first drop; re-root it so it doesn't retain
        // the whole original buffer.
        pending = Data(pending)
        return lines
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A launched process you can signal (e.g. SIGINT to stop a recording cleanly).
final class RunningProcess {
    private let process: Process
    init(_ process: Process) { self.process = process }

    func interrupt() { if process.isRunning { process.interrupt() } }   // SIGINT
    func terminate() { if process.isRunning { process.terminate() } }   // SIGTERM
    var isRunning: Bool { process.isRunning }
}

enum CommandRunner {
    /// Launch `executable` with `args`, draining stdout/stderr without deadlocking
    /// on full pipe buffers. `onExit` is called once, off the main thread.
    @discardableResult
    static func launch(
        executable: URL,
        args: [String],
        cwd: URL?,
        onEvent: ((ProgressEvent) -> Void)? = nil,
        onExit: @escaping (CommandResult) -> Void
    ) -> RunningProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice

        // A GUI app launched from Finder inherits a minimal PATH; prepend the usual
        // Homebrew/local locations so spawned tools (uv, ffmpeg, the audio helper) resolve.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // Ask for NDJSON progress instead of the ANSI checklist, which is unparseable
        // once captured. Only when someone is listening: the config/speaker commands
        // want stderr left alone.
        if onEvent != nil { env["OWNSCRIBE_PROGRESS_EVENTS"] = "1" }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBuf = OutputBuffer()
        let errBuf = OutputBuffer()

        // Balance: stdout EOF + stderr EOF + process exit.
        let group = DispatchGroup()
        group.enter(); group.enter(); group.enter()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                outBuf.append(chunk)
            }
        }
        let decoder = JSONDecoder()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                let lines = errBuf.append(chunk)
                guard let onEvent else { return }
                for line in lines {
                    // Ordinary stderr (torch/pyannote warnings) is not JSON and fails
                    // to decode — that is the discriminator, so failure is expected and
                    // must stay silent. Lines are still kept in errBuf either way.
                    guard let data = line.data(using: .utf8),
                          let event = try? decoder.decode(ProgressEvent.self, from: data)
                    else { continue }
                    onEvent(event)
                }
            }
        }
        process.terminationHandler = { _ in group.leave() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            onExit(CommandResult(
                stdout: "",
                stderr: "Failed to launch \(executable.path): \(error.localizedDescription)",
                exitCode: -1
            ))
            return RunningProcess(process)
        }

        group.notify(queue: .global()) {
            onExit(CommandResult(
                stdout: outBuf.string,
                stderr: errBuf.string,
                exitCode: process.terminationStatus
            ))
        }
        return RunningProcess(process)
    }

    /// Run to completion and return the result.
    static func run(executable: URL, args: [String], cwd: URL?) async -> CommandResult {
        await withCheckedContinuation { continuation in
            _ = launch(executable: executable, args: args, cwd: cwd) { result in
                continuation.resume(returning: result)
            }
        }
    }
}
