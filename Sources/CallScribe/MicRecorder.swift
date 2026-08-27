import Foundation
import AVFoundation
import OSLog

/// Records the default input device to its own file, so the transcript can tell
/// your voice apart from the other side of the call.
final class MicRecorder {

    private let log = Logger(subsystem: "at.skyline.CallScribe", category: "Mic")
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var writeFailure: Error?

    private(set) var isRunning = false

    static func requestAccess() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Blocking variant for the command-line self-test.
    static func requestAccessSynchronously() -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        let semaphore = DispatchSemaphore(value: 0)
        let result = Box()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            result.value = granted
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }

    func start(writingTo url: URL) throws {
        precondition(!isRunning)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "at.skyline.CallScribe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Input device reported an unusable format — is a microphone connected?"
            ])
        }

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        file = audioFile

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, self.writeFailure == nil else { return }
            do {
                try audioFile.write(from: buffer)
            } catch {
                self.writeFailure = error
                self.log.error("Mic write failed: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    @discardableResult
    func stop() -> Error? {
        guard isRunning else { return nil }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil

        defer { writeFailure = nil }
        return writeFailure
    }
}


/// Tiny reference cell so a completion handler can hand a value back across a semaphore.
private final class Box: @unchecked Sendable {
    var value = false
}
