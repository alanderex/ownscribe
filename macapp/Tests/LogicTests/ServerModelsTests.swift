import XCTest
@testable import Logic

final class ServerModelsTests: XCTestCase {
    func testDecodesTheModelList() throws {
        let json = #"""
        {"schema": 1, "backend": "omlx", "host": "http://127.0.0.1:8000/v1",
         "models": ["Gemma4-26B-MoE-Q4", "mlx-community--gemma-4-26B-A4B-it-qat-4bit"]}
        """#
        let listing = try ServerModels.decode(Data(json.utf8))
        XCTAssertEqual(listing.backend, "omlx")
        XCTAssertEqual(listing.models, ["Gemma4-26B-MoE-Q4", "mlx-community--gemma-4-26B-A4B-it-qat-4bit"])
    }

    func testRefusesAnUnknownSchema() {
        let json = #"{"schema": 2, "backend": "omlx", "host": "h", "models": []}"#
        XCTAssertThrowsError(try ServerModels.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ServerModels.Failure, .unsupportedSchema(2))
        }
    }
}
