import Foundation
import AVFoundation
import OSLog

/// Records the default input device to its own file, so the transcript can tell
/// your voice apart from the other side of the call.
///
/// @unchecked: control state is only touched on the main thread; the audio
/// thread only reaches `file`/`writeFailure` through the tap block.
final class MicRecorder: @unchecked Sendable {

    private let log = Logger(subsystem: "at.skyline.CallScribe", category: "Mic")
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var writeFailure: Error?
    private var configurationObserver: NSObjectProtocol?

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

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "at.skyline.CallScribe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Input device reported an unusable format — is a microphone connected?"
            ])
        }

        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)

        try attachAndStart()

        // Sleep/wake or an input-device switch stops the engine without a peep;
        // without this the UI keeps counting while nothing is written.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        isRunning = true
    }

    @discardableResult
    func stop() -> Error? {
        guard isRunning else { return nil }
        isRunning = false

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil

        defer { writeFailure = nil }
        return writeFailure
    }

    // MARK: - Internals

    private func attachAndStart() throws {
        guard let file else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "at.skyline.CallScribe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Input device reported an unusable format — is a microphone connected?"
            ])
        }

        // After a device switch the hardware format can differ from the file's;
        // convert live rather than abandon the rest of the recording.
        let converter = format == file.processingFormat
            ? nil
            : AVAudioConverter(from: format, to: file.processingFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.write(buffer, through: converter)
        }

        engine.prepare()
        try engine.start()
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try attachAndStart()
            log.info("Mic capture restarted after a configuration change")
        } catch {
            writeFailure = writeFailure ?? error
            log.error("Mic restart after configuration change failed: \(error.localizedDescription)")
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, through converter: AVAudioConverter?) {
        guard let file, writeFailure == nil else { return }
        do {
            if let converter {
                try file.write(from: converter.convertLive(buffer))
            } else {
                try file.write(from: buffer)
            }
        } catch {
            writeFailure = error
            log.error("Mic write failed: \(error.localizedDescription)")
        }
    }
}


/// Tiny reference cell so a completion handler can hand a value back across a semaphore.
private final class Box: @unchecked Sendable {
    var value = false
}
