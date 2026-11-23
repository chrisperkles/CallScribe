import Foundation
import NaturalLanguage
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the on-device model made of a recording. Written to meta.json.
struct SessionTitle: Codable, Sendable {
    var title: String
    var summary: String
    var names: [String]
    var actionItems: [String]
    var language: String
    var model: String
    var created: Date
}

/// Names a recording from its transcript with Apple Intelligence's on-device
/// model (macOS 26 and later). Everywhere else — older macOS, Apple Intelligence
/// switched off or still downloading, a language it doesn't speak, or a call it
/// declines to summarise — `suggest` returns nil and the folder keeps its date
/// name, exactly as before. Nothing leaves the Mac either way.
enum Titler {

    /// Why titles are off on this Mac, or nil when they work.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleIntelligence.unavailableReason
        }
        #endif
        return "Titles need macOS 26 or later with Apple Intelligence."
    }

    static var isAvailable: Bool { unavailableReason == nil }

    static func suggest(transcript: String, corrections: [Correction] = []) async -> SessionTitle? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await AppleIntelligence.suggest(
                transcript: Correction.apply(corrections, to: transcript))
        }
        #endif
        return nil
    }

    // MARK: - Transcript preparation (any macOS)

    /// "[00:00:09] Me:\n  text\n  text" blocks become "Me: text text" lines.
    static func condense(_ raw: String) -> [String] {
        var lines: [String] = []
        var speaker = ""
        var buffer: [String] = []
        func flush() {
            let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { lines.append(speaker.isEmpty ? text : "\(speaker): \(text)") }
            buffer = []
        }
        for line in raw.components(separatedBy: .newlines) {
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                flush()
                speaker = line[line.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            } else {
                let text = line.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { buffer.append(text) }
            }
        }
        flush()
        return lines
    }

    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(20_000)))
        return recognizer.dominantLanguage?.rawValue ?? "und"
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "the language of the conversation"
    }

    /// Consecutive lines grouped into chunks of at most `characters`.
    static func chunks(_ lines: [String], characters: Int) -> [String] {
        let limit = max(characters, 500)
        var out: [String] = []
        var current = ""
        for whole in lines {
            var line = Substring(whole)
            while line.count > limit {            // one monologue longer than a chunk
                out.append(String(line.prefix(limit)))
                line = line.dropFirst(limit)
            }
            if current.count + line.count + 1 > limit, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Speaker labels and the like that the model sometimes lists as names.
    static let notNames: Set<String> = ["me", "them", "room", "ich", "user", "the user", "team", "kunde", "customer"]

    /// The model sometimes leads with the user ("Chris – Förderungen"): who you
    /// are is the one thing a title never needs. Done here rather than in the
    /// prompt, because the model repeats whatever names the prompt mentions.
    static func tidy(_ raw: String, userName: String = NSFullUserName()) -> String {
        var title = SessionFolder.sanitized(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: " –-,;"))
        let parts = title.components(separatedBy: SessionFolder.separator)
        if parts.count > 1, isUser(parts[0], userName: userName) {
            title = parts.dropFirst().joined(separator: SessionFolder.separator)
        }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " –-,;"))
    }

    private static func isUser(_ lead: String, userName: String) -> Bool {
        let lead = lead.trimmingCharacters(in: .whitespaces).lowercased()
        guard lead.count >= 3 else { return false }
        if notNames.contains(lead) { return true }
        let nameWords = userName.lowercased().split(separator: " ").map(String.init)
        guard !nameWords.isEmpty else { return false }
        // "Chris", "Christoph", "Perkles", "Chris Perkles" for "Christoph Perkles":
        // every word of the lead is one of the user's names, or short for one.
        return lead.split(separator: " ").allSatisfy { word in
            let word = String(word)
            return word.count >= 3 && nameWords.contains { $0 == word || $0.hasPrefix(word) }
        }
    }
}

#if canImport(FoundationModels)

@available(macOS 26.0, *)
private enum AppleIntelligence {

    // Lessons from running this over real calls: the small model repeats
    // whatever the prompt hands it. Telling it who the user is or listing known
    // names put those names into every title; a made-up example title came back
    // verbatim. So the prompt carries no context and no example.

    @Generable
    struct Summary {
        @Guide(description: "A short, specific title for this conversation, at most 60 characters. If the conversation is with or about a named company, organisation, project or person, start with that name, then ' – ', then the main topic. Otherwise just the main topic. No date, no quotes, no words like Call or Meeting, never Me or Them.")
        var title: String
        @Guide(description: "Two or three sentences: who the conversation is with and what was discussed or decided.")
        var summary: String
        @Guide(description: "Other people and organisations taking part or discussed. Not 'Me', 'Them' or 'Room'.", .maximumCount(6))
        var names: [String]
        @Guide(description: "Concrete next steps or to-dos agreed in the conversation. Empty if none.", .maximumCount(5))
        var actionItems: [String]
    }

    @Generable
    struct Notes {
        @Guide(description: "Up to 60 words of notes on this part of the conversation: who is speaking with whom, companies and people named, topics, decisions, next steps.")
        var notes: String
    }

    static let log = Logger(subsystem: "at.skyline.CallScribe", category: "Titles")

    /// Transforming the user's own content (their transcript) is exactly what
    /// this guardrail setting is for; the default one refuses ordinary calls.
    static var model: SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    static var unavailableReason: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in System Settings."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model."
        case .unavailable:
            return "Apple Intelligence isn't available."
        }
    }

    static func suggest(transcript raw: String) async -> SessionTitle? {
        guard unavailableReason == nil else { return nil }
        let model = model

        let lines = Titler.condense(raw)
        let full = lines.joined(separator: "\n")
        let words = full.split(whereSeparator: \.isWhitespace).count
        guard words >= 40 else { return nil }               // nothing worth naming

        let language = Titler.language(of: full)
        let instructions = """
        You read machine transcripts of business phone calls and meetings recorded by the user. \
        "Me" is the user, "Them" is the other side, "Room" is everyone in a meeting room. \
        The transcript comes from speech recognition, so names may be misspelled. \
        Write all output in \(Titler.languageName(language)).
        """
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400)

        // Instructions, schema and the answer need room in the context window too.
        let budget = max(model.contextSize - 1300, 1000)
        let charactersPerToken = await measureCharactersPerToken(sample: String(full.prefix(8000)), model: model)
        let estimatedTokens = Int(Double(full.count) / charactersPerToken)

        func summarise(_ source: String) async throws -> Summary {
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(
                to: "Here is the conversation. Give it a title and summary.\n\n\(source)",
                generating: Summary.self, options: options).content
        }

        /// Notes per chunk. A chunk the safety filter rejects is left out
        /// rather than costing the whole recording its title.
        func notes(chunkCharacters: Int) async -> [String] {
            let parts = Titler.chunks(lines, characters: chunkCharacters)
            var out: [String] = []
            for (index, part) in parts.enumerated() {
                let session = LanguageModelSession(model: model, instructions: instructions)
                do {
                    let notes = try await session.respond(
                        to: "Part \(index + 1) of \(parts.count) of the transcript:\n\n\(part)",
                        generating: Notes.self, options: options).content.notes
                    out.append("Part \(index + 1): \(notes)")
                } catch {
                    log.notice("Skipped part \(index + 1) of \(parts.count): \(String(describing: error), privacy: .public)")
                }
            }
            return out
        }

        var summary: Summary?
        if estimatedTokens <= budget {
            summary = try? await summarise(full)            // short call: all of it at once
        }
        if summary == nil {
            // Long, or refused as a whole: smaller parts, so a passage the filter
            // dislikes only costs its own part.
            let size = estimatedTokens <= budget
                ? max(full.count / 3, 1500)
                : Int(Double(budget) * charactersPerToken)
            let collected = await notes(chunkCharacters: size)
            guard !collected.isEmpty else { return nil }
            let header = "Notes on each part of the conversation, in order:\n\n"
            summary = try? await summarise(header + collected.joined(separator: "\n"))
            if summary == nil, collected.count > 1 {
                // The combined notes can be refused too; each half on its own often isn't.
                let half = collected.count / 2
                for slice in [collected.prefix(half), collected.dropFirst(half)] where summary == nil {
                    summary = try? await summarise(header + slice.joined(separator: "\n"))
                }
            }
        }

        guard let summary else {
            log.notice("No title: the model declined this recording")
            return nil
        }
        let title = Titler.tidy(summary.title)
        guard !title.isEmpty else { return nil }

        return SessionTitle(
            title: title,
            summary: summary.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            names: summary.names
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !Titler.notNames.contains($0.lowercased()) },
            actionItems: summary.actionItems,
            language: language,
            model: "Apple Intelligence (on-device)",
            created: Date())
    }

    /// Exact on macOS 26.4 and later; before that a conservative estimate that
    /// errs towards smaller chunks.
    static func measureCharactersPerToken(sample: String, model: SystemLanguageModel) async -> Double {
        if #available(macOS 26.4, *), !sample.isEmpty,
           let tokens = try? await model.tokenCount(for: sample), tokens > 0 {
            return max(Double(sample.count) / Double(tokens), 1.5)
        }
        return 2.5
    }
}

#endif
