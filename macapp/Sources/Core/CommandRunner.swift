import Foundation

struct CommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var ok: Bool { exitCode == 0 }
}

/// Thread-safe byte accumulator for pipe reads (handlers fire off the main thread).
private final class OutputBuffer {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
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
        onExit: @escaping (CommandResult) -> Void
    ) -> RunningProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice

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
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                errBuf.append(chunk)
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
