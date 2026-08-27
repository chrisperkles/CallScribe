import Foundation

/// Paths and options, overridable with `defaults write at.skyline.CallScribe <key> <value>`.
struct Settings {
    var whisperPath: String
    var modelPath: String
    var ffmpegPath: String
    var language: String
    var recordingsRoot: URL

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser

        return Settings(
            whisperPath: defaults.string(forKey: "whisperPath")
                ?? firstExisting(["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
                ?? "/opt/homebrew/bin/whisper-cli",
            modelPath: defaults.string(forKey: "modelPath")
                ?? home.appendingPathComponent("whisper-models/ggml-large-v3-turbo.bin").path,
            ffmpegPath: defaults.string(forKey: "ffmpegPath")
                ?? firstExisting(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
                ?? "/opt/homebrew/bin/ffmpeg",
            language: defaults.string(forKey: "language") ?? "auto",
            recordingsRoot: defaults.string(forKey: "recordingsRoot").map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent("Recordings/CallScribe")
        )
    }

    /// Human-readable reason the pipeline can't run, or nil if everything is in place.
    var missingDependency: String? {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: whisperPath) { return "whisper-cli not found at \(whisperPath)" }
        if !fm.isExecutableFile(atPath: ffmpegPath) { return "ffmpeg not found at \(ffmpegPath)" }
        if !fm.fileExists(atPath: modelPath) { return "Whisper model not found at \(modelPath)" }
        return nil
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
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
