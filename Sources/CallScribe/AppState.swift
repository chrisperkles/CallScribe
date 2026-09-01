import Foundation
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppState: ObservableObject {

    enum Status: Equatable {
        case idle
        case recording(mode: RecordingMode, since: Date)
        case transcribing(session: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var recent: [URL] = []      // transcript files, newest first
    @Published var models = ModelStore()

    private let systemAudio = SystemAudioRecorder()
    private let mic = MicRecorder()
    private var settings = Settings.load()
    private var session: (directory: URL, mode: RecordingMode)?

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    var isBusy: Bool {
        if case .transcribing = status { return true }
        return false
    }

    var needsModel: Bool {
        if case .ready = models.state { return false }
        return true
    }

    init() {
        models.refresh(configured: settings.modelPath)
        loadRecent()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        LaunchAtLogin.enableOnFirstRun()

        // Closing the lid mid-recording would record a silent gap at best and,
        // if the audio devices change across sleep, nothing at all afterwards.
        // Finalize and transcribe instead; the transcript completes after wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.stop()
            }
        }

        // Quitting mid-recording: tear the Core Audio tap down and finalize
        // both files before the process exits, instead of crashing through it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemAudio.stop()
                self?.mic.stop()
            }
        }
    }

    // MARK: - Actions

    func start(mode: RecordingMode) async {
        guard !isRecording, !isBusy else { return }

        settings = Settings.load()
        models.refresh(configured: settings.modelPath)

        guard case .ready = models.state else {
            status = .failed("Download a speech model first.")
            return
        }
        if let missing = settings.missingDependency(modelURL: modelURL) {
            status = .failed(missing)
            return
        }
        guard await MicRecorder.requestAccess() else {
            status = .failed("Microphone access denied — enable CallScribe in System Settings › Privacy & Security › Microphone.")
            return
        }

        let directory = settings.recordingsRoot
            .appendingPathComponent(Timestamps.sessionName(Date()))

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if mode.capturesSystemAudio {
                try systemAudio.start(writingTo: directory.appendingPathComponent("them.caf"))
            }
            do {
                try mic.start(writingTo: directory.appendingPathComponent("me.caf"))
            } catch where mode == .call {
                // In a call the far end still gets captured, so a dead mic is
                // a degraded recording rather than a failed one.
                NSLog("CallScribe: mic unavailable, system audio only: \(error)")
            }

            session = (directory, mode)
            status = .recording(mode: mode, since: Date())
        } catch {
            systemAudio.stop()
            mic.stop()
            try? FileManager.default.removeItem(at: directory)
            status = .failed(explain(error))
        }
    }

    func stop() {
        guard isRecording, let session else { return }
        let (directory, mode) = session

        let systemError = systemAudio.stop()
        let micError = mic.stop()
        self.session = nil

        if let error = systemError ?? micError {
            status = .failed(explain(error))
            return
        }

        status = .transcribing(session: directory.lastPathComponent)

        let settings = self.settings
        guard let modelPath = modelURL?.path else {
            status = .failed("No speech model available.")
            return
        }

        Task.detached(priority: .userInitiated) {
            var tracks: [Transcriber.Track] = []
            if mode.capturesSystemAudio {
                tracks.append(.init(label: "Them", url: directory.appendingPathComponent("them.caf")))
            }
            tracks.append(.init(label: mode.micLabel, url: directory.appendingPathComponent("me.caf")))
            tracks = tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }

            do {
                let transcriber = Transcriber(settings: settings, modelPath: modelPath)
                _ = try transcriber.run(tracks: tracks, in: directory)
                await MainActor.run {
                    self.status = .idle
                    self.loadRecent()
                    self.notify(title: "Transcript ready", body: directory.lastPathComponent)
                }
            } catch {
                let message = explain(error)
                await MainActor.run {
                    self.status = .failed(message)
                    self.notify(title: "Transcription failed", body: message)
                }
            }
        }
    }

    func dismissError() {
        if case .failed = status { status = .idle }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: settings.recordingsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.recordingsRoot)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    var modelURL: URL? {
        if case .ready(let url) = models.state { return url }
        return nil
    }

    // MARK: - Helpers

    private func loadRecent() {
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: settings.recordingsRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        recent = sessions
            .map { $0.appendingPathComponent("transcript.txt") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.deletingLastPathComponent().lastPathComponent > $1.deletingLastPathComponent().lastPathComponent }
            .prefix(8)
            .map { $0 }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
