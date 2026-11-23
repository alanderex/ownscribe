import Foundation

/// `ownscribe models --json`: the models the configured omlx or openai summarization
/// server offers, for the Settings model picker.
struct ServerModels: Decodable, Equatable {
    /// The only schema this app understands.
    static let supportedSchema = 1

    enum Failure: Error, Equatable {
        case unsupportedSchema(Int)
    }

    let schema: Int
    let backend: String
    /// The API address the CLI asked.
    let host: String
    /// Model ids, sorted by name.
    let models: [String]

    static func decode(_ data: Data) throws -> ServerModels {
        let listing = try JSONDecoder().decode(ServerModels.self, from: data)
        guard listing.schema == supportedSchema else { throw Failure.unsupportedSchema(listing.schema) }
        return listing
    }
}
