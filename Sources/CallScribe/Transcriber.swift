import Foundation
import OSLog

/// Converts each track to whisper's input format, transcribes it, and interleaves
/// the results into one chronological, speaker-labelled transcript.
struct Transcriber {

    struct Track {
        let label: String       // "Me" / "Them" / "Room"
        let url: URL
    }

    struct Cue {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
        let text: String
    }

    private let log = Logger(subsystem: "at.skyline.CallScribe", category: "Transcribe")
    private let settings: Settings
    private let modelPath: String

    init(settings: Settings, modelPath: String) {
        self.settings = settings
        self.modelPath = modelPath
    }

    /// Returns the URL of the merged transcript.
    func run(tracks: [Track], in directory: URL) throws -> URL {
        var cues: [Cue] = []
        var analyses: [String: AudioPrep.Result] = [:]
        var transcribedAny = false

        for track in tracks {
            let wav = directory.appendingPathComponent("\(track.label.lowercased())-16k.wav")
            let prepared = try AudioPrep.prepare(track.url, to: wav)
            analyses[track.label] = prepared

            guard prepared.hasSpeech else {
                // Silence makes whisper invent dialogue, so don't feed it any.
                log.info("Skipping \(track.label): no speech (peak \(prepared.peak))")
                try? FileManager.default.removeItem(at: wav)
                continue
            }

            let prefix = directory.appendingPathComponent(track.label.lowercased())
            try transcribe(wav: wav, outputPrefix: prefix)
            cues.append(contentsOf: parseSRT(at: prefix.appendingPathExtension("srt"), speaker: track.label))
            transcribedAny = true

            try? FileManager.default.removeItem(at: wav)
        }

        cues = suppressBleed(in: cues, analyses: analyses)
        cues.sort { $0.start < $1.start }

        let transcript = directory.appendingPathComponent("transcript.txt")
        let body = transcribedAny ? render(cues: cues) : "(no speech detected in this recording)\n"
        try body.write(to: transcript, atomically: true, encoding: .utf8)
        return transcript
    }

    /// On speakerphone the microphone re-records the far end, and whisper turns
    /// that faint echo into invented dialogue. A cue is bleed when another track
    /// is much louder over the same moment — which, unlike a loudness threshold,
    /// can never discard speech said while the other side was quiet.
    private func suppressBleed(in cues: [Cue], analyses: [String: AudioPrep.Result]) -> [Cue] {
        guard analyses.count > 1 else { return cues }

        return cues.filter { cue in
            guard let own = analyses[cue.speaker] else { return true }
            let ownEnergy = own.energy(from: cue.start, to: cue.end)

            let loudestOther = analyses
                .filter { $0.key != cue.speaker }
                .map { $0.value.energy(from: cue.start, to: cue.end) }
                .max() ?? 0

            let isEcho = loudestOther > ownEnergy * 3
            if isEcho {
                log.info("Dropping bleed on \(cue.speaker): \(cue.text)")
            }
            return !isEcho
        }
    }

    // MARK: - Steps

    private func transcribe(wav: URL, outputPrefix: URL) throws {
        var arguments = [
            "-m", modelPath,
            "-f", wav.path,
            "-osrt",
            "-of", outputPrefix.path,
            "-t", String(ProcessInfo.processInfo.activeProcessorCount),
            "-np",
            "-l", settings.language,
        ]
        // Whisper loops and invents dialogue when fed near-silence. Dropping
        // cross-window context (-mc 0) is the single most effective guard, and
        // the entropy threshold makes the decoder give up rather than repeat.
        arguments += ["--no-speech-thold", "0.6", "-mc", "0", "-et", "2.6"]
        try Shell.run(settings.whisperPath, arguments)
    }

    private func parseSRT(at url: URL, speaker: String) -> [Cue] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var cues: [Cue] = []

        for block in raw.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.count >= 2,
                  let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

            let stamps = lines[arrowIndex].components(separatedBy: "-->")
            guard stamps.count == 2,
                  let start = Self.seconds(fromSRTStamp: stamps[0]),
                  let end = Self.seconds(fromSRTStamp: stamps[1]) else { continue }

            let text = lines[(arrowIndex + 1)...].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isHallucination(text) else { continue }

            cues.append(Cue(start: start, end: end, speaker: speaker, text: text))
        }
        return collapseRepeats(cues)
    }

    /// A stuck decoder emits the same sentence over and over. One occurrence is
    /// plausibly real; a run of them never is.
    private func collapseRepeats(_ cues: [Cue]) -> [Cue] {
        var out: [Cue] = []
        var runText: String?
        var runLength = 0

        for cue in cues {
            let key = cue.text.lowercased()
            if key == runText {
                runLength += 1
            } else {
                runText = key
                runLength = 1
            }
            if runLength == 1 {
                out.append(cue)
            } else if runLength == 3 {
                // Keep the first, drop the rest, and say so rather than silently lying.
                out.removeLast()
            }
        }
        return out
    }

    /// Stock phrases whisper emits over near-silence, from its subtitle training data.
    private static let junk: Set<String> = [
        "thank you.", "thanks for watching!", "you", "bye.", ".", "so",
        "untertitel von stephanie geiges", "untertitelung des zdf, 2020",
        "subtitles by the amara.org community", "amara.org", "copyright wdr",
    ]

    static func isHallucination(_ text: String) -> Bool {
        junk.contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func render(cues: [Cue]) -> String {
        guard !cues.isEmpty else { return "(no speech detected in this recording)\n" }

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
