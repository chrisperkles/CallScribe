import Foundation
import OSLog

/// Downsamples each track with ffmpeg, runs whisper.cpp over it, then interleaves
/// the two SRT outputs into one speaker-labelled transcript.
struct Transcriber {

    struct Track {
        let label: String       // "Me" / "Them"
        let url: URL            // the raw recording
    }

    struct Cue {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
        let text: String
    }

    private let log = Logger(subsystem: "at.skyline.CallScribe", category: "Transcribe")
    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    /// Returns the URL of the merged transcript.
    func run(tracks: [Track], in directory: URL) throws -> URL {
        var cues: [Cue] = []

        for track in tracks {
            guard fileHasAudio(track.url) else {
                log.info("Skipping empty track \(track.label)")
                continue
            }
            let wav = directory.appendingPathComponent("\(track.label.lowercased())-16k.wav")
            try convertForWhisper(input: track.url, output: wav)

            let prefix = directory.appendingPathComponent(track.label.lowercased())
            try transcribe(wav: wav, outputPrefix: prefix)

            let srt = prefix.appendingPathExtension("srt")
            cues.append(contentsOf: try parseSRT(at: srt, speaker: track.label))

            try? FileManager.default.removeItem(at: wav)
        }

        cues.sort { $0.start < $1.start }

        let transcript = directory.appendingPathComponent("transcript.txt")
        try render(cues: cues).write(to: transcript, atomically: true, encoding: .utf8)
        return transcript
    }

    // MARK: - Steps

    private func convertForWhisper(input: URL, output: URL) throws {
        // whisper.cpp wants 16 kHz mono signed 16-bit PCM.
        try Shell.run(settings.ffmpegPath, [
            "-nostdin", "-y", "-loglevel", "error",
            "-i", input.path,
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
            output.path,
        ])
    }

    private func transcribe(wav: URL, outputPrefix: URL) throws {
        var arguments = [
            "-m", settings.modelPath,
            "-f", wav.path,
            "-osrt",
            "-of", outputPrefix.path,
            "-t", String(ProcessInfo.processInfo.activeProcessorCount),
            "-np",
        ]
        if settings.language != "auto" {
            arguments += ["-l", settings.language]
        } else {
            arguments += ["-l", "auto"]
        }
        try Shell.run(settings.whisperPath, arguments)
    }

    private func parseSRT(at url: URL, speaker: String) throws -> [Cue] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var cues: [Cue] = []

        for block in raw.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.count >= 3,
                  let arrow = lines.first(where: { $0.contains("-->") }),
                  let arrowIndex = lines.firstIndex(of: arrow) else { continue }

            let stamps = arrow.components(separatedBy: "-->")
            guard stamps.count == 2,
                  let start = Self.seconds(fromSRTStamp: stamps[0]),
                  let end = Self.seconds(fromSRTStamp: stamps[1]) else { continue }

            let text = lines[(arrowIndex + 1)...].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            cues.append(Cue(start: start, end: end, speaker: speaker, text: text))
        }
        return cues
    }

    private func render(cues: [Cue]) -> String {
        guard !cues.isEmpty else { return "(no speech detected)\n" }

        var out = ""
        var lastSpeaker: String?
        for cue in cues {
            if cue.speaker != lastSpeaker {
                out += "\n[\(Self.clock(cue.start))] \(cue.speaker):\n"
                lastSpeaker = cue.speaker
            }
            out += "  \(cue.text)\n"
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }

    // MARK: - Helpers

    private func fileHasAudio(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        return size > 8192   // more than just a header
    }

    /// "00:01:23,456" -> 83.456
    static func seconds(fromSRTStamp stamp: String) -> TimeInterval? {
        let trimmed = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

enum Shell {
    struct Failure: LocalizedError {
        let command: String
        let status: Int32
        let output: String
        var errorDescription: String? {
            "\(command) exited with \(status)\n\(output.suffix(600))"
        }
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw Failure(
                command: (launchPath as NSString).lastPathComponent,
                status: process.terminationStatus,
                output: output)
        }
        return output
    }
}
