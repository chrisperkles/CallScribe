import Foundation
import AVFoundation
import OSLog
import ObjCExceptionCatcher

/// Records the default input device to its own file, so the transcript can tell
/// your voice apart from the other side of the call.
///
/// @unchecked: control state is only touched on the main thread; the audio
/// thread only reaches `file`/`writeFailure` through the tap block.
final class MicRecorder: @unchecked Sendable {

    private let log = Logger(subsystem: "at.skyline.CallScribe", category: "Mic")
    private var engine: AVAudioEngine?
    private var destination: URL?
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

        destination = url
        do {
            try attachAndStart()
        } catch {
            tearDownEngine()
            file = nil
            destination = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        isRunning = true
    }

    @discardableResult
    func stop() -> Error? {
        guard isRunning else { return nil }
        isRunning = false

        tearDownEngine()
        file = nil
        destination = nil

        defer { writeFailure = nil }
        return writeFailure
    }

    // MARK: - Internals

    private func attachAndStart() throws {
        do {
            try startFreshEngine()
        } catch {
            // The input can change format between reading it and tapping it:
            // a Bluetooth headset switching profile as the mic opens does exactly
            // that. A second engine sees the settled format.
            log.notice("Mic start failed, retrying on a fresh engine: \(error.localizedDescription)")
            try startFreshEngine()
        }
    }

    /// A new engine per start binds to the current default input at its current
    /// format. One kept alive since launch can report a stale format (a headset
    /// last seen at 24 kHz, now running at 48 kHz), and tapping it with that
    /// format raises an Objective-C exception.
    private func startFreshEngine() throws {
        tearDownEngine()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "at.skyline.CallScribe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Input device reported an unusable format — is a microphone connected?"
            ])
        }

        if file == nil, let destination {
            file = try AVAudioFile(
                forWriting: destination,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
        }
        guard let file else { return }

        // After a device switch the hardware format can differ from the file's;
        // convert live rather than abandon the rest of the recording.
        let converter = format == file.processingFormat
            ? nil
            : AVAudioConverter(from: format, to: file.processingFormat)

        var exceptionError: NSError?
        let installed = CSCatchObjCException({
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.write(buffer, through: converter)
            }
            engine.prepare()
        }, &exceptionError)
        guard installed else {
            throw exceptionError ?? NSError(domain: "at.skyline.CallScribe", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Could not attach to the microphone"])
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine

        // Sleep/wake or an input-device switch stops the engine without a peep;
        // without this the UI keeps counting while nothing is written.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
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
