import Foundation

/// One recording lives in one folder: "2026-11-23 13.22.17", or, once Apple
/// Intelligence has named it, "2026-11-23 13.22.17 – Reform – Challenge-App".
/// The date always comes first, so the folders sort by time either way.
enum SessionFolder {

    /// Length of "yyyy-MM-dd HH.mm.ss".
    static let stampLength = 19
    static let separator = " – "
    static let maximumTitleLength = 70

    /// The recording for a track ("me", "them"): the raw .caf while it exists,
    /// the compressed .m4a after that.
    static func audio(_ name: String, in directory: URL) -> URL? {
        for ext in ["caf", "m4a"] {
            let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func transcript(in directory: URL) -> URL {
        directory.appendingPathComponent("transcript.txt")
    }

    static func metadata(in directory: URL) -> URL {
        directory.appendingPathComponent("meta.json")
    }

    /// True for "2026-11-23 13.22.17" and "2026-11-23 13.22.17 – …", false for
    /// self-test folders and anything the user put there by hand.
    static func isSession(_ directory: URL) -> Bool {
        Timestamps.date(fromSessionName: directory.lastPathComponent) != nil
    }

    static func title(of directory: URL) -> String? {
        let name = directory.lastPathComponent
        let rest = name.dropFirst(stampLength)
        guard rest.hasPrefix(separator) else { return nil }
        let title = rest.dropFirst(separator.count).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// For menus: "23.11.26 13:22  Reform – Challenge-App", or just the date.
    static func displayName(of directory: URL) -> String {
        let name = directory.lastPathComponent
        guard let date = Timestamps.date(fromSessionName: name) else { return name }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yy HH:mm"
        let when = formatter.string(from: date)
        guard let title = title(of: directory) else { return when }
        return "\(when)  \(title)"
    }

    /// A title that is safe and readable as part of a folder name.
    static func sanitized(_ title: String) -> String {
        // Quotes, dots and markdown at either end; a leading dot would also hide the folder.
        let text = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“”‚‘’«»`*#. "))
        guard text.count > maximumTitleLength else { return text }

        // Cut at the last word boundary that fits, never mid-word.
        let cut = text.prefix(maximumTitleLength)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]).trimmingCharacters(in: CharacterSet(charactersIn: " –-,;"))
        }
        return String(cut)
    }

    /// Renames the folder to "<date> – <title>" and returns its new location.
    /// An existing folder of that name gets a counter rather than being touched.
    static func rename(_ directory: URL, title: String) throws -> URL {
        let clean = sanitized(title)
        guard !clean.isEmpty, isSession(directory) else { return directory }

        let stamp = String(directory.lastPathComponent.prefix(stampLength))
        let parent = directory.deletingLastPathComponent()
        var target = parent.appendingPathComponent(stamp + separator + clean)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path), target.standardizedFileURL != directory.standardizedFileURL {
            target = parent.appendingPathComponent("\(stamp)\(separator)\(clean) (\(counter))")
            counter += 1
        }
        guard target.standardizedFileURL != directory.standardizedFileURL else { return directory }
        try FileManager.default.moveItem(at: directory, to: target)
        return target
    }
}
