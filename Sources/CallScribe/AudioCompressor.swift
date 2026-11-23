import Foundation
import AVFoundation
import OSLog

/// The recorders write uncompressed 32-bit float (~1.2 GB per hour of call),
/// because a .caf survives a crash mid-call and an .m4a doesn't. Once the
/// transcript exists the raw files have done their job: AAC at speech bitrates
/// is ~30x smaller and sounds the same for voice.
enum AudioCompressor {

    private static let log = Logger(subsystem: "at.skyline.CallScribe", category: "Compress")
    private static let afconvert = "/usr/bin/afconvert"

    /// Compresses every .caf in a session folder. A file is only deleted once
    /// its .m4a exists and has the same length; on any failure the .caf stays.
    static func compressSession(at directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension.lowercased() == "caf" {
            compress(file)
        }
    }

    /// Sessions recorded before this version, or interrupted mid-compression:
    /// every finished session (it has a transcript) that still holds a .caf.
    static func compressFinishedSessions(in root: URL) {
        let fm = FileManager.default
        let sessions = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for session in sessions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where SessionFolder.isSession(session)
            && fm.fileExists(atPath: SessionFolder.transcript(in: session).path) {
            compressSession(at: session)
        }
    }

    @discardableResult
    static func compress(_ caf: URL) -> Bool {
        let fm = FileManager.default
        guard let source = try? AVAudioFile(forReading: caf) else { return false }
        let format = source.fileFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        guard sampleRate > 0, channels > 0, source.length > 0 else { return false }
        let duration = Double(source.length) / sampleRate

        let output = caf.deletingPathExtension().appendingPathExtension("m4a")

        // A raw 3-channel mic array has no AAC layout, and the encoder refuses
        // to drop channels itself: mix it to a mono file first, outside the session.
        var input = caf
        var scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }
        if channels > 2 {
            let mono = fm.temporaryDirectory.appendingPathComponent("callscribe-\(UUID().uuidString).caf")
            scratch = mono
            guard (try? Shell.run(afconvert, [caf.path, "-o", mono.path, "-f", "caff", "-d", "LEF32", "-c", "1"])) != nil else {
                log.error("Could not mix \(caf.path, privacy: .public) to mono; keeping the original")
                return false
            }
            input = mono
        }
        let outputChannels = channels > 2 ? 1 : channels

        // AAC caps the bitrate by sample rate (a 24 kHz headset refuses 64 kbps
        // mono), so step down until the encoder accepts one.
        let candidates = outputChannels == 1 ? [64_000, 48_000, 32_000] : [96_000, 64_000, 48_000]
        var encoded = false
        for bitrate in candidates {
            try? fm.removeItem(at: output)
            let arguments = [input.path, "-o", output.path, "-f", "m4af", "-d", "aac",
                             "-b", String(bitrate), "-s", "1"]
            if (try? Shell.run(afconvert, arguments)) != nil {
                encoded = true
                break
            }
        }

        guard encoded, let compressed = try? AVAudioFile(forReading: output),
              compressed.fileFormat.sampleRate > 0,
              abs(Double(compressed.length) / compressed.fileFormat.sampleRate - duration) < 0.1
        else {
            try? fm.removeItem(at: output)
            log.error("Could not compress \(caf.path, privacy: .public); keeping the original")
            return false
        }

        do {
            try fm.removeItem(at: caf)
        } catch {
            log.error("Compressed \(caf.lastPathComponent, privacy: .public) but could not remove it: \(error.localizedDescription, privacy: .public)")
            return false
        }
        log.info("Compressed \(caf.lastPathComponent, privacy: .public) (\(Int(duration)) s)")
        return true
    }
}
