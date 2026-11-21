import XCTest
@testable import Logic

final class FolderNameTests: XCTestCase {
    /// The same table as FOLDER_TITLES in tests/test_show.py: the app and the CLI
    /// must name a folder the same way.
    func testTitles() {
        let cases: [(String, String)] = [
            ("260609-q2-sales-review", "Q2 Sales Review"),
            ("260609-standup_1630", "Standup"),
            ("260609-budget-2026", "Budget 2026"),
            ("260609-1053", "260609-1053"),
            ("260609-105312", "260609-105312"),
            ("260609-2026", "260609-2026"),
            ("2026-06-09_1053_q2-sales-review", "Q2 Sales Review"),
            ("2026-06-18_1400", "2026-06-18_1400"),
            ("2026-06-16-su-screener", "2026-06-16-su-screener"),
            ("2026-06-17-Alexander W_german-startup", "2026-06-17-Alexander W_german-startup"),
            ("261007-ai@strategy", "Ai@Strategy"),
            ("261008-time4work-podcast", "Time4Work Podcast"),
            ("260101-o'neil-sync", "O'neil Sync"),
            ("260101-o\u{2019}neil-sync", "O\u{2019}neil Sync"),
            ("260101-2nd-review", "2Nd Review"),
            ("260101-über-uns", "Über Uns"),
            ("261015-HE", "He"),
            ("261001-1425-snyc-pycon", "1425 Snyc Pycon"),
            ("notes", "notes"),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(FolderName.title(name), expected, name)
        }
    }
}
