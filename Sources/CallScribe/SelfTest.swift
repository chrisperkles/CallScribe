import Foundation
import AVFoundation

/// `CallScribe --selftest [seconds] [--meeting]` — records, transcribes and prints
/// the result without touching the menu bar. Used to verify permissions and setup.
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
        let mode: RecordingMode = CommandLine.arguments.contains("--meeting") ? .meeting : .call

        let settings = Settings.load()
        print("mode:    \(mode.rawValue)")
        print("whisper: \(settings.whisperPath)")

        guard let model = ModelStore.locateExisting(preferring: settings.modelPath) else {
            fail("No model found. Open CallScribe and complete the one-time setup, or place a ggml-*.bin in ~/whisper-models.")
        }
        print("model:   \(model.path)")
        if let missing = settings.missingDependency(modelURL: model) {
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

            if mode.capturesSystemAudio {
                try systemAudio.start(writingTo: directory.appendingPathComponent("them.caf"))
                print("system tap running…")
            }
            if granted {
                try mic.start(writingTo: directory.appendingPathComponent("me.caf"))
                print("mic running…")
            }

            print("recording \(Int(seconds))s — talk, or play something")
            Thread.sleep(forTimeInterval: seconds)

            if let error = systemAudio.stop() { fail("system audio: \(explain(error))") }
            if let error = mic.stop() { fail("mic: \(explain(error))") }

            var tracks: [Transcriber.Track] = []
            if mode.capturesSystemAudio {
                tracks.append(.init(label: "Them", url: directory.appendingPathComponent("them.caf")))
            }
            tracks.append(.init(label: mode.micLabel, url: directory.appendingPathComponent("me.caf")))
            tracks = tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }

            for track in tracks {
                let probe = directory.appendingPathComponent("probe-\(track.label).wav")
                let result = try AudioPrep.prepare(track.url, to: probe)
                print(String(format: "%@: %.1fs, peak %.3f, active %.1f%% -> %@",
                             track.label, result.duration, result.peak,
                             result.activeFraction * 100,
                             result.hasSpeech ? "transcribe" : "skip (silent)"))
                try? FileManager.default.removeItem(at: probe)
            }

            print("transcribing…")
            let transcriber = Transcriber(settings: settings, modelPath: model.path)
            let transcript = try transcriber.run(tracks: tracks, in: directory)
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
