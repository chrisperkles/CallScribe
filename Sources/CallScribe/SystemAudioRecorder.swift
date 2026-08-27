import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import OSLog

/// Captures everything the Mac is playing, using the Core Audio process-tap API
/// (macOS 14.4+). No virtual audio driver, no output-device switching: we create
/// a private global tap, wrap it in a private aggregate device, and pull frames
/// off that device's IOProc.
final class SystemAudioRecorder {

    enum RecorderError: LocalizedError {
        case osStatus(String, OSStatus)
        case noDefaultOutput
        case badTapFormat

        var errorDescription: String? {
            switch self {
            case .osStatus(let what, let status):
                return "\(what) failed (OSStatus \(status))"
            case .noDefaultOutput:
                return "No default output device"
            case .badTapFormat:
                return "Could not read the tap's stream format"
            }
        }
    }

    private let log = Logger(subsystem: "at.skyline.CallScribe", category: "SystemAudio")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?

    /// Set when the IOProc hits a write error, so `stop()` can surface it.
    private var writeFailure: Error?

    private let queue = DispatchQueue(label: "at.skyline.CallScribe.systemtap")

    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start(writingTo url: URL) throws {
        precondition(!isRunning)

        let outputUID = try defaultOutputDeviceUID()

        // 1. A private, global tap: everything the machine plays, mixed to stereo.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "CallScribe System Tap"
        description.isPrivate = true
        // .unmuted so the user still hears the call while we record it.
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw RecorderError.osStatus("AudioHardwareCreateProcessTap", status)
        }

        // 2. A private aggregate device that owns the tap. The default output
        //    device rides along as the clock source.
        let aggregateUID = UUID().uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallScribe Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            cleanUp()
            throw RecorderError.osStatus("AudioHardwareCreateAggregateDevice", status)
        }

        // 3. Ask the tap what it will hand us, and open a matching file.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            cleanUp()
            throw RecorderError.badTapFormat
        }
        format = tapFormat
        log.info("Tap format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount) ch")

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: tapFormat.settings,
            commonFormat: tapFormat.commonFormat,
            interleaved: tapFormat.isInterleaved)
        file = audioFile

        // 4. Pull frames.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let ioProcID else {
            cleanUp()
            throw RecorderError.osStatus("AudioDeviceCreateIOProcIDWithBlock", status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanUp()
            throw RecorderError.osStatus("AudioDeviceStart", status)
        }

        isRunning = true
    }

    @discardableResult
    func stop() -> Error? {
        guard isRunning else { return nil }
        isRunning = false

        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        cleanUp()

        // Draining the queue guarantees no IOProc block is still touching `file`.
        queue.sync {}
        file = nil

        defer { writeFailure = nil }
        return writeFailure
    }

    // MARK: - Internals

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format, let file, writeFailure == nil else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData) else { return }
        do {
            try file.write(from: buffer)
        } catch {
            writeFailure = error
            log.error("System audio write failed: \(error.localizedDescription)")
        }
    }

    private func cleanUp() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw RecorderError.noDefaultOutput
        }

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw RecorderError.osStatus("kAudioDevicePropertyDeviceUID", status)
        }
        return uid as String
    }
}
