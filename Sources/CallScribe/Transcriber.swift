import Foundation
import NaturalLanguage
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
        /// What the previous track turned out to be in, when the language is "auto".
        var heardLanguage: String?

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

            let language = chooseLanguage(of: track.label, prepared: prepared, wav: wav, heardLanguage: heardLanguage)

            let prefix = directory.appendingPathComponent(track.label.lowercased())
            try transcribe(wav: wav, outputPrefix: prefix, language: language)
            let trackCues = parseSRT(at: prefix.appendingPathExtension("srt"), speaker: track.label)
            cues.append(contentsOf: trackCues)
            transcribedAny = true

            if heardLanguage == nil, !prepared.lifted {
                if language != "auto" {
                    heardLanguage = language
                } else {
                    let recognizer = NLLanguageRecognizer()
                    recognizer.processString(trackCues.map(\.text).joined(separator: " "))
                    if let (code, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.8 {
                        // Whisper wants "zh", not NaturalLanguage's "zh-Hans".
                        heardLanguage = code.rawValue.split(separator: "-").first.map(String.init)
                    }
                }
            }

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
    /// that faint echo into invented dialogue. A mic cue is bleed when another
    /// track is much louder over the same moment — which, unlike a loudness
    /// threshold, can never discard speech said while the other side was quiet.
    ///
    /// The far end's track is system audio, so loudness alone proves nothing
    /// there: it only ever holds the user's voice when a far end without echo
    /// cancellation plays it back, and whisper then writes down the same words.
    /// Judged by loudness, one call lost eight real lines said while the user
    /// talked, and all recordings together 366 — questions included — against
    /// 105 true echoes.
    private func suppressBleed(in cues: [Cue], analyses: [String: AudioPrep.Result]) -> [Cue] {
        guard analyses.count > 1 else { return cues }

        return cues.filter { cue in
            guard let own = analyses[cue.speaker] else { return true }
            let ownEnergy = own.energy(from: cue.start, to: cue.end)

            let loudestOther = analyses
                .filter { $0.key != cue.speaker }
                .map { $0.value.energy(from: cue.start, to: cue.end) }
                .max() ?? 0

            var isEcho = loudestOther > ownEnergy * 3
            if isEcho, cue.speaker == Self.systemAudioLabel {
                let words = Self.words(cue.text)
                let heard = cues
                    .filter { $0.speaker != cue.speaker && $0.start < cue.end && $0.end > cue.start }
                    .reduce(into: Set<String>()) { $0.formUnion(Self.words($1.text)) }
                isEcho = !words.isEmpty && Double(words.intersection(heard).count) >= Double(words.count) / 2
            }
            if isEcho {
                log.info("Dropping bleed on \(cue.speaker, privacy: .public): \(cue.text)")
            }
            return !isEcho
        }
    }

    /// The label of the system-audio track: the far end of a call.
    static let systemAudioLabel = "Them"

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    // MARK: - Steps

    /// The language to transcribe a track in.
    ///
    /// Left to itself, whisper guesses from a track's first 30 seconds, which on
    /// a call is hellos, waiting or silence: a German call came out as Icelandic
    /// on one side and Spanish on the other (2026-11-24), while 30 seconds of
    /// actual speech from the same tracks read as German at p = 0.999. So the
    /// guess is made here, on the busiest stretches, and only the languages set
    /// in the panel can win.
    private func chooseLanguage(of label: String, prepared: AudioPrep.Result, wav: URL,
                                heardLanguage: String?) -> String {
        let allowed = settings.languages
        if allowed.count == 1 { return allowed[0] }

        // A lifted, very quiet track was guessed as English and got translated;
        // it speaks the language the other side was heard in.
        if prepared.lifted, let heardLanguage {
            log.info("\(label, privacy: .public) was lifted; transcribing it as \(heardLanguage, privacy: .public)")
            return heardLanguage
        }

        var votes: [String: Double] = [:]
        let stretches = AudioPrep.busiestStretches(in: prepared, seconds: 30, count: 3)
        for (index, start) in stretches.enumerated() {
            let excerpt = wav.deletingLastPathComponent()
                .appendingPathComponent("\(label.lowercased())-language-\(index).wav")
            defer { try? FileManager.default.removeItem(at: excerpt) }
            do {
                try AudioPrep.excerpt(of: wav, from: start, seconds: 30, to: excerpt)
                if let (code, probability) = try detectLanguage(in: excerpt) {
                    votes[code, default: 0] += probability
                    log.info("\(label, privacy: .public) at \(Int(start)) s sounds like \(code, privacy: .public) (p = \(probability))")
                }
            } catch {
                log.error("Language check on \(label, privacy: .public) failed: \(explain(error), privacy: .public)")
            }
        }

        let eligible = allowed.isEmpty ? votes : votes.filter { allowed.contains($0.key) }
        let choice = eligible.max { $0.value < $1.value }?.key ?? allowed.first ?? "auto"
        log.info("\(label, privacy: .public): transcribing as \(choice, privacy: .public)")
        return choice
    }

    /// Whisper's guess for the first 30 seconds of a file, with its probability.
    private func detectLanguage(in wav: URL) throws -> (String, Double)? {
        let output = try Shell.run(settings.whisperPath, [
            "-m", modelPath,
            "-f", wav.path,
            "-t", String(ProcessInfo.processInfo.activeProcessorCount),
            "-l", "auto",
            "-dl",
        ])
        // "whisper_full_with_state: auto-detected language: de (p = 0.999049)"
        let pattern = #"auto-detected language: ([a-z]+) \(p = ([0-9.]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let code = Range(match.range(at: 1), in: output).map({ String(output[$0]) }),
              let probability = Range(match.range(at: 2), in: output).flatMap({ Double(output[$0]) })
        else { return nil }
        return (code, probability)
    }

    private func transcribe(wav: URL, outputPrefix: URL, language: String) throws {
        var arguments = [
            "-m", modelPath,
            "-f", wav.path,
            "-osrt",
            "-of", outputPrefix.path,
            "-t", String(ProcessInfo.processInfo.activeProcessorCount),
            "-np",
            "-l", language,
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
            guard !text.isEmpty, !Self.isHallucination(text, duration: end - start) else { continue }

            cues.append(Cue(start: start, end: end, speaker: speaker,
                            text: Correction.apply(settings.corrections, to: text)))
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
        "wdr mediagroup gmbh im auftrag des wdr", "...",
        "vertraue und glaube, es hilft, es heilt die göttliche kraft!",
    ]

    /// Thanks stretched over a whole 30-second decoding window are whisper
    /// talking over silence: across all recordings "Vielen Dank." lasted 25 s
    /// or more 155 times, and less only 4 times.
    private static let windowFillers: Set<String> = ["vielen dank.", "danke.", "danke schön.", "thanks."]

    static func isHallucination(_ text: String, duration: TimeInterval = 0) -> Bool {
        let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return junk.contains(key) || (duration >= 25 && windowFillers.contains(key))
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
