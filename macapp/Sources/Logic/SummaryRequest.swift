import Foundation

/// What a summary is written with: the backend, model and template from Settings or
/// the Summarize dialog, and the user's own instructions. `show DIR --json` reports
/// the one behind the current summary, so the dialog can ask for it again.
struct SummaryRequest: Codable, Equatable {
    var backend: String
    var model: String
    var template: String
    var instructions: String

    /// The templates every ownscribe has (src/ownscribe/summarization/prompts.py).
    static let builtInTemplates = ["meeting", "lecture", "brief"]

    /// The built-in templates, then the custom ones from config.toml by name.
    static func templates(custom: some Collection<String>) -> [String] {
        builtInTemplates + custom.filter { !builtInTemplates.contains($0) }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// What the dialog starts from: the meeting's last request, else Settings. A
    /// model recorded under another backend means nothing to the one in Settings now,
    /// so the model then comes from Settings; the template and instructions stay.
    static func initial(recorded: SummaryRequest?, backend: String, model: String, template: String) -> SummaryRequest {
        let settings = SummaryRequest(
            backend: backend, model: model, template: template.isEmpty ? "meeting" : template, instructions: ""
        )
        guard var request = recorded else { return settings }
        if request.backend != backend {
            request.backend = backend
            request.model = settings.model
        }
        return request
    }

    /// `ownscribe` arguments that write the meeting's summary with this request, in
    /// place (`resume --resummarize`, which keeps the folder's name).
    func resumeArguments(folder: String) -> [String] {
        var arguments = ["resume", folder, "--resummarize", "--template", template, "--summary-model", model]
        let typed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { arguments += ["--instructions", typed] }
        return arguments
    }
}
