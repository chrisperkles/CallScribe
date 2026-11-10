import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import OSLog

/// Captures everything the Mac is playing, using the Core Audio process-tap API
/// (macOS 14.4+). No virtual audio driver, no output-device switching: we create
/// a private global tap, wrap it in a private aggregate device, and pull frames
/// off that device's IOProc.
///
/// The aggregate is clocked by the default output device, so when that device
/// goes away mid-recording (headphones unplugged, sleep/wake with a different
/// output) the capture is rebuilt on the new device and keeps writing to the
/// same file.
///
/// Frames arrive at the aggregate's sample rate, which is the output device's,
/// not the rate the tap reports. A Bluetooth headset in call mode runs at 24 or
/// 16 kHz while the tap still says 48, so the rate is read from the aggregate
/// and followed when it changes mid-recording.
///
/// @unchecked: control state is only touched on the main thread; the IOProc
/// only reaches `file`/`format`/`converter`/`writeFailure` on `queue`, and
/// `format`/`converter` only change inside `queue.sync`.
final class SystemAudioRecorder: @unchecked Sendable {

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
    private var converter: AVAudioConverter?

    /// The tap's own description: channel layout and sample type. Its rate
    /// is replaced with the aggregate's (see `currentStreamFormat`).
    private var tapDescription: AudioStreamBasicDescription?

    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var deviceListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Set when the IOProc hits a write error, so `stop()` can surface it.
    private var writeFailure: Error?

    private let queue = DispatchQueue(label: "at.skyline.CallScribe.systemtap")

    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start(writingTo url: URL) throws {
        precondition(!isRunning)

        try startCapture(creatingFileAt: url)
        registerDeviceListener()
        isRunning = true
    }

    @discardableResult
    func stop() -> Error? {
        guard isRunning else { return nil }
        isRunning = false

        unregisterDeviceListener()
        teardownCapture()
        file = nil
        converter = nil

        defer { writeFailure = nil }
        return writeFailure
    }

    // MARK: - Capture pipeline

    /// Builds tap → aggregate → IOProc. With a URL it also opens the output
    /// file; without one it re-attaches to an existing file after a device
    /// change, converting if the new tap format differs.
    private func startCapture(creatingFileAt url: URL? = nil) throws {
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

        // 3. Work out what the IOProc will hand us: the tap's sample type at
        //    the aggregate's rate. Open a matching file, or convert to the one
        //    already open.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            cleanUp()
            throw RecorderError.badTapFormat
        }
        tapDescription = asbd
        guard let streamFormat = currentStreamFormat() else {
            cleanUp()
            throw RecorderError.badTapFormat
        }
        log.notice("System audio: tap reports \(asbd.mSampleRate) Hz, device runs at \(streamFormat.sampleRate) Hz, \(streamFormat.channelCount) ch")

        if let url {
            do {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: streamFormat.settings,
                    commonFormat: streamFormat.commonFormat,
                    interleaved: streamFormat.isInterleaved)
            } catch {
                cleanUp()
                throw error
            }
        }
        adopt(streamFormat)
        registerRateListener()

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
    }

    private func teardownCapture() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        cleanUp()

        // Draining the queue guarantees no IOProc block is still touching `file`.
        queue.sync {}
    }

    // MARK: - Device changes

    private func registerDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListenerAddress, .main, block)
        deviceListener = block
    }

    private func unregisterDeviceListener() {
        guard let deviceListener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListenerAddress, .main, deviceListener)
        self.deviceListener = nil
    }

    private func handleDeviceChange() {
        guard isRunning else { return }
        log.info("Default output device changed — rebuilding system capture")
        teardownCapture()
        do {
            try startCapture()
        } catch {
            writeFailure = writeFailure ?? error
            log.error("Could not resume system capture: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The output device changed its rate without being swapped out, e.g. a
    /// Bluetooth headset switching into call mode when the call app opens its
    /// microphone. The tap and aggregate stay; only the format the frames are
    /// read as (and the conversion to the file) changes.
    private func registerRateListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleRateChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(aggregateID, &rateListenerAddress, .main, block)
        if status == noErr {
            rateListener = block
        } else {
            log.error("Could not watch the output sample rate (OSStatus \(status))")
        }
    }

    private func unregisterRateListener() {
        guard let rateListener else { return }
        AudioObjectRemovePropertyListenerBlock(aggregateID, &rateListenerAddress, .main, rateListener)
        self.rateListener = nil
    }

    private func handleRateChange() {
        guard isRunning, let streamFormat = currentStreamFormat() else { return }
        let previous = queue.sync { format?.sampleRate }
        guard streamFormat.sampleRate != previous else { return }
        log.notice("Output sample rate changed from \(previous ?? 0) to \(streamFormat.sampleRate) Hz")
        adopt(streamFormat)
    }

    /// The tap's sample type at the rate the aggregate actually runs at.
    private func currentStreamFormat() -> AVAudioFormat? {
        guard var asbd = tapDescription else { return nil }
        if let rate = nominalSampleRate(of: aggregateID), rate > 0 {
            asbd.mSampleRate = rate
        }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Reads the IOProc's frames as `streamFormat` from now on, converting
    /// when the open file has a different format.
    private func adopt(_ streamFormat: AVAudioFormat) {
        queue.sync {
            format = streamFormat
            if let file, streamFormat != file.processingFormat {
                converter = AVAudioConverter(from: streamFormat, to: file.processingFormat)
            } else {
                converter = nil
            }
        }
    }

    // MARK: - Internals

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format, let file, writeFailure == nil else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData) else { return }
        do {
            if let converter {
                try file.write(from: converter.convertLive(buffer))
            } else {
                try file.write(from: buffer)
            }
        } catch {
            writeFailure = error
            log.error("System audio write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cleanUp() {
        unregisterRateListener()
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func nominalSampleRate(of device: AudioObjectID) -> Double? {
        guard device != kAudioObjectUnknown else { return nil }
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
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
