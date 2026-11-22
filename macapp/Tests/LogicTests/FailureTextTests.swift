import XCTest
@testable import Logic

final class FailureTextTests: XCTestCase {
    func testProgressEventsAreSkipped() {
        let stderr = """
            {"ownscribe_progress": 1, "event": "steps", "steps": []}
            Error: No audio was captured.
            """
        XCTAssertEqual(FailureText.firstMeaningfulLine(stderr), "Error: No audio was captured.")
    }

    func testTracebackGivesTheException() {
        let stderr = """
            Traceback (most recent call last):
              File "x.py", line 1, in <module>
            RuntimeError: model crashed
            """
        XCTAssertEqual(FailureText.firstMeaningfulLine(stderr), "RuntimeError: model crashed")
    }

    func testLibraryNoiseIsPassedOver() {
        let stderr = """
            /venv/torchaudio/_backend.py:1: UserWarning: deprecated
              warnings.warn(
            Error: Unknown summarization backend 'llama'.
            """
        XCTAssertEqual(FailureText.firstMeaningfulLine(stderr), "Error: Unknown summarization backend 'llama'.")
    }

    func testOnlyNoiseStillSaysSomething() {
        XCTAssertEqual(FailureText.firstMeaningfulLine("FutureWarning: x"), "FutureWarning: x")
    }

    func testNothingToSay() {
        XCTAssertNil(FailureText.firstMeaningfulLine("\n  \n"))
        XCTAssertNil(FailureText.firstMeaningfulLine(#"{"ownscribe_progress": 1, "event": "done", "ok": false}"#))
    }
}
