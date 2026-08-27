import Foundation

/// What we're recording. The difference matters for both capture and labelling.
enum RecordingMode: String, CaseIterable, Identifiable {
    /// A call: the far end arrives as system audio, you arrive on the mic.
    case call
    /// Everyone is in the room: microphone only, no speaker attribution.
    case meeting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .call: return "Record Call"
        case .meeting: return "Record Meeting (room)"
        }
    }

    var capturesSystemAudio: Bool { self == .call }

    /// Label for the microphone track in the transcript.
    var micLabel: String {
        switch self {
        case .call: return "Me"
        case .meeting: return "Room"
        }
    }
}

/// Paths and options, overridable with `defaults write at.skyline.CallScribe <key> <value>`.
struct Settings {
    var whisperPath: String
    var modelPath: String?
    var language: String
    var recordingsRoot: URL

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser

        return Settings(
            whisperPath: defaults.string(forKey: "whisperPath") ?? bundledWhisper(),
            modelPath: defaults.string(forKey: "modelPath"),
            language: defaults.string(forKey: "language") ?? "auto",
            recordingsRoot: defaults.string(forKey: "recordingsRoot").map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent("Recordings/CallScribe")
        )
    }

    /// The statically linked whisper-cli shipped inside the app, falling back to
    /// a Homebrew install when running from a bare `swift build`.
    static func bundledWhisper() -> String {
        if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        let fallbacks = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        return fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) } ?? fallbacks[0]
    }

    /// Human-readable reason the pipeline can't run, or nil if everything is in place.
    func missingDependency(modelURL: URL?) -> String? {
        if !FileManager.default.isExecutableFile(atPath: whisperPath) {
            return "The speech engine is missing from the app bundle. Reinstall CallScribe."
        }
        if modelURL == nil { return "No speech model downloaded yet." }
        return nil
    }
}

enum Timestamps {
    /// Folder name for one recording session.
    static func sessionName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}

func explain(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
