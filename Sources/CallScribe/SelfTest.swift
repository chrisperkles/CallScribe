import Foundation
import AVFoundation

/// `CallScribe --selftest [seconds]` — records, transcribes and prints the result
/// without touching the menu bar. Used to verify permissions and tool paths.
enum SelfTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static func run() -> Never {
        let seconds = CommandLine.arguments
            .drop(while: { $0 != "--selftest" })
            .dropFirst()
            .compactMap(Double.init)
            .first ?? 8

        let settings = Settings.load()
        print("whisper: \(settings.whisperPath)")
        print("ffmpeg:  \(settings.ffmpegPath)")
        print("model:   \(settings.modelPath)")
        if let missing = settings.missingDependency {
            fail(missing)
        }

        let directory = settings.recordingsRoot
            .appendingPathComponent("selftest-\(Timestamps.sessionName(Date()))")

        let systemAudio = SystemAudioRecorder()
        let mic = MicRecorder()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let granted = MicRecorder.requestAccessSynchronously()
            print("microphone access: \(granted ? "granted" : "DENIED")")

            try systemAudio.start(writingTo: directory.appendingPathComponent("them.caf"))
            print("system tap running…")
            if granted {
                try mic.start(writingTo: directory.appendingPathComponent("me.caf"))
                print("mic running…")
            }

            print("recording \(Int(seconds))s — play something now")
            Thread.sleep(forTimeInterval: seconds)

            if let error = systemAudio.stop() { fail("system audio: \(explain(error))") }
            if let error = mic.stop() { fail("mic: \(explain(error))") }

            for name in ["them.caf", "me.caf"] {
                let url = directory.appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? Int) ?? 0
                print("\(name): \(size) bytes")
            }

            let tracks = [
                Transcriber.Track(label: "Them", url: directory.appendingPathComponent("them.caf")),
                Transcriber.Track(label: "Me", url: directory.appendingPathComponent("me.caf")),
            ].filter { FileManager.default.fileExists(atPath: $0.url.path) }

            print("transcribing…")
            let transcript = try Transcriber(settings: settings).run(tracks: tracks, in: directory)
            print("\n--- \(transcript.path) ---")
            print((try? String(contentsOf: transcript, encoding: .utf8)) ?? "(unreadable)")
            exit(0)
        } catch {
            systemAudio.stop()
            mic.stop()
            fail(explain(error))
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
        exit(1)
    }
}
