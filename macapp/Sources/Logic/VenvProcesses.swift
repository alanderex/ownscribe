import Foundation

/// Whether anything still runs from the app's managed environment.
enum VenvProcesses {
    /// True when any command line in `psOutput` (`ps -axww -o args=`) contains the
    /// venv's ownscribe script.
    ///
    /// Matched on the command line, not the executable: the console script runs
    /// under the venv's python, which is a symlink, so the executable path says
    /// nothing reliable. The command line also catches a job left running by an
    /// earlier app session.
    static func anyUsing(script: String, psOutput: String) -> Bool {
        psOutput.split(whereSeparator: \.isNewline).contains { $0.contains(script) }
    }
}
