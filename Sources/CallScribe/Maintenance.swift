import Foundation

/// Gives a finished session its title: meta.json inside, folder renamed after it.
enum SessionNaming {

    struct Outcome {
        let directory: URL          // where the session lives now
        let title: SessionTitle?    // nil: kept its date name
    }

    static func isNamed(_ directory: URL) -> Bool {
        SessionFolder.title(of: directory) != nil
            || FileManager.default.fileExists(atPath: SessionFolder.metadata(in: directory).path)
    }

    static func name(_ directory: URL, settings: Settings, dryRun: Bool = false) async -> Outcome {
        guard settings.nameRecordings, SessionFolder.isSession(directory),
              let transcript = try? String(contentsOf: SessionFolder.transcript(in: directory), encoding: .utf8),
              let title = await Titler.suggest(transcript: transcript, corrections: settings.corrections)
        else { return Outcome(directory: directory, title: nil) }

        guard !dryRun else { return Outcome(directory: directory, title: title) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(title) {
            try? data.write(to: SessionFolder.metadata(in: directory), options: .atomic)
        }
        let renamed = (try? SessionFolder.rename(directory, title: title.title)) ?? directory
        return Outcome(directory: renamed, title: title)
    }
}

/// Command-line upkeep for recordings made before titles and compression existed:
///
///   CallScribe --title <session folder> [--dry-run]
///   CallScribe --title-all [--dry-run]
///   CallScribe --compress <session folder>
enum Maintenance {

    static var isRequested: Bool {
        let arguments = CommandLine.arguments
        return arguments.contains("--title") || arguments.contains("--title-all") || arguments.contains("--compress")
    }

    static func run() -> Never {
        let arguments = CommandLine.arguments
        let settings = Settings.load()
        let dryRun = arguments.contains("--dry-run")

        if let path = value(after: "--compress") {
            let directory = folder(path)
            AudioCompressor.compressSession(at: directory)
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".caf") }
            print(left.isEmpty ? "compressed \(directory.lastPathComponent)" : "still uncompressed: \(left.joined(separator: ", "))")
            exit(left.isEmpty ? 0 : 1)
        }

        if let reason = Titler.unavailableReason {
            fail("No titles on this Mac: \(reason) Recordings keep their date names.")
        }
        let forced: Settings = {        // asked for explicitly, whatever the setting
            var copy = settings
            copy.nameRecordings = true
            return copy
        }()

        let directories: [URL]
        if arguments.contains("--title-all") {
            let all = (try? FileManager.default.contentsOfDirectory(
                at: settings.recordingsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            directories = all
                .filter { SessionFolder.isSession($0) && !SessionNaming.isNamed($0) }
                .filter { FileManager.default.fileExists(atPath: SessionFolder.transcript(in: $0).path) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else if let path = value(after: "--title") {
            directories = [folder(path)]
        } else {
            fail("Usage: CallScribe --title <session folder> | --title-all  [--dry-run]")
        }

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for directory in directories {
                let outcome = await SessionNaming.name(directory, settings: forced, dryRun: dryRun)
                if let title = outcome.title {
                    print("\(directory.lastPathComponent)  →  \(dryRun ? title.title : outcome.directory.lastPathComponent)")
                } else {
                    print("\(directory.lastPathComponent)  →  (no title, keeps its date name)")
                }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func value(after flag: String) -> String? {
        let rest = CommandLine.arguments.drop(while: { $0 != flag }).dropFirst()
        guard let value = rest.first, !value.hasPrefix("--") else { return nil }
        return value
    }

    private static func folder(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
        exit(1)
    }
}
