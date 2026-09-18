import Foundation
import AppKit
import CoreAudio
import OSLog

/// Notices when another app starts using the microphone, which is the one thing
/// every call has in common regardless of whether it runs in Zoom, Teams,
/// FaceTime or a browser tab.
///
/// Core Audio publishes one process object per audio client (macOS 14.4+) with
/// its bundle ID and whether it is currently running input. Reading those needs
/// no permission and never touches the audio itself.
///
/// Polled rather than observed: property listeners on process objects proved
/// unreliable, silently missing an app that held the mic for seven seconds.
/// A call lasts minutes, so a two-second poll loses nothing.
@MainActor
final class CallDetector {

    /// Called with the app's display name once the mic has been held long
    /// enough to look like a call rather than a permission check or a blip.
    var onCallStarted: ((String) -> Void)?
    /// Called with the name of the app whose call just ended.
    var onCallEnded: ((String) -> Void)?

    /// Display name of the app currently in a call, if any.
    private(set) var activeApp: String?

    private let log = Logger(subsystem: "at.skyline.CallScribe", category: "CallDetector")

    private static let startDelay: Duration = .seconds(3)
    /// Longer than the start delay so a device switch mid-call, which drops and
    /// reopens the input, doesn't read as a new call.
    private static let endDelay: Duration = .seconds(8)

    /// Mic users that aren't calls: "Hey Siri", dictation, Voice Control and
    /// sound recognition listen all day. Daemons without a bundle ID (such as
    /// historicalaudiod, which holds the mic permanently) are skipped separately.
    private static let ignoredPrefixes = [
        "com.apple.corespeech", "com.apple.CoreSpeech", "com.apple.assistantd",
        "com.apple.Siri", "com.apple.siri", "com.apple.SpeechRecognitionCore",
        "com.apple.speech", "com.apple.accessibility", "com.apple.universalaccessd",
        "com.apple.VoiceControl", "com.apple.VoiceMemos",
    ]

    /// System processes that hold the mic on behalf of an app.
    private static let knownNames = [
        "com.apple.avconferenced": "FaceTime",
        "com.apple.TelephonyUtilities": "FaceTime",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.WebKit.GPU": "Safari",
    ]

    private var poll: Timer?
    private var pending: Task<Void, Never>?

    var isRunning: Bool { poll != nil }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        poll = timer

        evaluate()
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        pending?.cancel()
        pending = nil
        activeApp = nil
    }

    // MARK: - Tracking

    /// Starts and stops only count once they have held for a moment.
    private func evaluate() {
        let inCall = activeApp != nil
        guard (currentMicUser() != nil) != inCall else {
            pending?.cancel()
            pending = nil
            return
        }
        guard pending == nil else { return }

        let delay = inCall ? Self.endDelay : Self.startDelay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.settle()
        }
    }

    private func settle() {
        let app = currentMicUser()
        guard (app != nil) != (activeApp != nil) else { return }

        let previous = activeApp
        activeApp = app
        if let app {
            log.info("Microphone in use by \(app, privacy: .public)")
            onCallStarted?(app)
        } else {
            log.info("Microphone released")
            onCallEnded?(previous ?? "The app")
        }
    }

    private func currentMicUser() -> String? {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for process in Self.processObjects() {
            guard Self.read(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
                  Self.read(process, kAudioProcessPropertyPID, default: pid_t(-1)) != ownPID
            else { continue }

            let bundleID = Self.bundleID(of: process)
            guard !bundleID.isEmpty,
                  !Self.ignoredPrefixes.contains(where: bundleID.hasPrefix)
            else { continue }

            return Self.displayName(for: bundleID)
        }
        return nil
    }

    // MARK: - Naming

    /// The mic is often held by a helper ("com.google.Chrome.helper"), so walk
    /// up the bundle ID until it names an installed app.
    private static func displayName(for bundleID: String) -> String {
        if let known = knownNames[bundleID] { return known }

        var components = bundleID.split(separator: ".")
        while components.count >= 2 {
            let candidate = components.joined(separator: ".")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                return url.deletingPathExtension().lastPathComponent
            }
            components.removeLast()
        }
        return "An app"
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }

        var processes = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return Array(processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T) -> T {
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        var address = address(selector)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value : fallback
    }

    private static func bundleID(of process: AudioObjectID) -> String {
        read(process, kAudioProcessPropertyBundleID, default: "" as CFString) as String
    }
}
