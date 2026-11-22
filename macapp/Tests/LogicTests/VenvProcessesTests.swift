import XCTest
@testable import Logic

final class VenvProcessesTests: XCTestCase {
    private let script = "/Users/a/Library/Application Support/Ownscribe/.venv/bin/ownscribe"

    func testARunningJobCounts() {
        let ps = """
            /usr/libexec/trustd
            /Users/a/Library/Application Support/Ownscribe/.venv/bin/python3 /Users/a/Library/Application Support/Ownscribe/.venv/bin/ownscribe --mic --model base
            /bin/ps -axww -o args=
            """
        XCTAssertTrue(VenvProcesses.anyUsing(script: script, psOutput: ps))
    }

    func testAnotherEnvironmentDoesNotCount() {
        let ps = """
            /Users/a/Library/Application Support/Ownscribe Next/.venv/bin/python3 /Users/a/Library/Application Support/Ownscribe Next/.venv/bin/ownscribe show --list --json
            /opt/homebrew/bin/ownscribe resume ./260101-1200
            """
        XCTAssertFalse(VenvProcesses.anyUsing(script: script, psOutput: ps))
    }

    func testNothingRunning() {
        XCTAssertFalse(VenvProcesses.anyUsing(script: script, psOutput: ""))
    }
}
