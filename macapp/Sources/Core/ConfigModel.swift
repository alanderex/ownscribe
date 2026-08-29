import Foundation

/// Swift mirror of `ownscribe config get --json`. Decoded with
/// `.convertFromSnakeCase`, so TOML keys like `mic_device` / `api_key` map to
/// `micDevice` / `apiKey`. Unknown keys (e.g. `templates`) are ignored.
struct OwnscribeConfig: Codable, Equatable {
    /// Which secrets are stored, keyed "section.field" (e.g. "diarization.hf_token").
    /// `config get` blanks secret values, so this is the only way to tell a saved
    /// token from no token — without it a saved field just reads back empty and
    /// looks like the save failed.
    ///
    /// Optional on purpose: Swift's synthesized Decodable ignores property defaults
    /// for missing keys and throws instead, so a non-optional here would hard-fail
    /// the whole app against any ownscribe predating this field.
    var secretsSet: [String: Bool]?
    var audio = Audio()
    var transcription = Transcription()
    var diarization = Diarization()
    var summarization = Summarization()
    var output = Output()

    struct Audio: Codable, Equatable {
        var backend = "coreaudio"
        var device = ""
        var mic = false
        var micDevice = ""
        var captureMode = "picker"
        var silenceTimeout = 300
    }

    struct Transcription: Codable, Equatable {
        var model = "base"
        var language = ""
        var initialPrompt = ""
        var hotwords = ""
    }

    struct Diarization: Codable, Equatable {
        var enabled = false
        var hfToken = ""
        var minSpeakers = 0
        var maxSpeakers = 0
        var telemetry = false
        var device = "auto"
    }

    struct Summarization: Codable, Equatable {
        var enabled = true
        var backend = "local"
        var model = "phi-4-mini"
        var host = "http://localhost:11434"
        var apiKey = ""
        var template = ""
        var contextSize = 0
    }

    struct Output: Codable, Equatable {
        var dir = "~/ownscribe"
        var format = "markdown"
        var keepRecording = true
    }
}
