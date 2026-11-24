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
    /// Languages the calls are in, as whisper codes ("de", "en"). One: every
    /// track is transcribed in it. Several: each track in whichever of them it
    /// sounds like. None: any language.
    var languages: [String]
    var recordingsRoot: URL
    /// Ask the on-device Apple Intelligence model for a title and put it in the
    /// folder name. Without Apple Intelligence the folder keeps its date name.
    var nameRecordings: Bool
    /// Replace the raw .caf recordings with AAC .m4a once the transcript exists.
    var compressAudio: Bool
    /// Spellings for names speech recognition keeps getting wrong.
    var corrections: [Correction]

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser

        return Settings(
            whisperPath: defaults.string(forKey: "whisperPath") ?? bundledWhisper(),
            modelPath: defaults.string(forKey: "modelPath"),
            languages: spokenLanguages(defaults),
            recordingsRoot: defaults.string(forKey: "recordingsRoot").map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent("Recordings/CallScribe"),
            nameRecordings: defaults.object(forKey: "nameRecordings") as? Bool ?? true,
            compressAudio: defaults.object(forKey: "compressAudio") as? Bool ?? true,
            corrections: Correction.parse(defaults.string(forKey: "corrections") ?? "")
        )
    }

    /// The older single `language` key wins when set (`defaults write … language de`,
    /// or `-language de` on the command line); the panel writes `languages`.
    private static func spokenLanguages(_ defaults: UserDefaults) -> [String] {
        if let single = defaults.string(forKey: "language"), !SpokenLanguage.parse(single).isEmpty {
            return SpokenLanguage.parse(single)
        }
        return SpokenLanguage.parse(defaults.string(forKey: "languages") ?? "")
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
    static let format = "yyyy-MM-dd HH.mm.ss"

    /// Folder name for one recording session.
    static func sessionName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func date(fromSessionName name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.date(from: String(name.prefix(SessionFolder.stampLength)))
    }
}

/// The languages offered in the panel. `defaults write at.skyline.CallScribe
/// languages "de,en"` takes any of whisper's codes.
enum SpokenLanguage {
    static let offered = ["de", "en", "fr", "it", "es", "pl", "nl", "pt"]

    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// "de, en" → ["de", "en"]; "auto" and repeats dropped.
    static func parse(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { $0 != "auto" && seen.insert($0).inserted }
    }
}

/// `defaults write at.skyline.CallScribe corrections "Lansing=Lenzing, Kai-Burg=KRAIBURG"`
struct Correction: Sendable, Equatable {
    let from: String
    let to: String

    /// Pairs separated by commas, semicolons or new lines.
    static func parse(_ text: String) -> [Correction] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }).compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return Correction(from: parts[0], to: parts[1])
        }
    }

    /// Whole words only, ignoring case: "Lansing" fixes "lansing" but not "Lansinger".
    static func apply(_ corrections: [Correction], to text: String) -> String {
        corrections.reduce(text) { text, correction in
            let pattern = "(?<![\\p{L}\\p{N}])"
                + NSRegularExpression.escapedPattern(for: correction.from)
                + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return text
            }
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: correction.to))
        }
    }
}

func explain(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
