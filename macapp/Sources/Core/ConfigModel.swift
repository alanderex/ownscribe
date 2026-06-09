import Foundation

/// Swift mirror of `ownscribe config get --json`. Decoded with
/// `.convertFromSnakeCase`, so TOML keys like `mic_device` / `api_key` map to
/// `micDevice` / `apiKey`. Unknown keys (e.g. `templates`) are ignored.
struct OwnscribeConfig: Codable, Equatable {
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
