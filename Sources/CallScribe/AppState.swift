import Foundation
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppState: ObservableObject {

    enum Status: Equatable {
        case idle
        case recording(since: Date)
        case transcribing(session: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var recent: [URL] = []      // transcript files, newest first

    private let systemAudio = SystemAudioRecorder()
    private let mic = MicRecorder()
    private var settings = Settings.load()
    private var sessionDirectory: URL?

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    var isBusy: Bool {
        if case .transcribing = status { return true }
        return false
    }

    init() {
        loadRecent()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Actions

    func toggle() {
        if isRecording {
            stop()
        } else if !isBusy {
            Task { await start() }
        }
    }

    func start() async {
        settings = Settings.load()
        if let missing = settings.missingDependency {
            status = .failed(missing)
            return
        }

        guard await MicRecorder.requestAccess() else {
            status = .failed("Microphone access denied — grant it in System Settings › Privacy & Security › Microphone.")
            return
        }

        let name = Timestamps.sessionName(Date())
        let directory = settings.recordingsRoot.appendingPathComponent(name)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try systemAudio.start(writingTo: directory.appendingPathComponent("them.caf"))
            do {
                try mic.start(writingTo: directory.appendingPathComponent("me.caf"))
            } catch {
                // A missing or busy mic shouldn't cost you the call audio.
                NSLog("CallScribe: mic unavailable, recording system audio only: \(error)")
            }
            sessionDirectory = directory
            status = .recording(since: Date())
        } catch {
            systemAudio.stop()
            mic.stop()
            try? FileManager.default.removeItem(at: directory)
            status = .failed(explain(error))
        }
    }

    func stop() {
        guard isRecording, let directory = sessionDirectory else { return }

        let systemError = systemAudio.stop()
        let micError = mic.stop()
        sessionDirectory = nil

        if let error = systemError ?? micError {
            status = .failed(explain(error))
            return
        }

        status = .transcribing(session: directory.lastPathComponent)
        let settings = self.settings

        Task.detached(priority: .userInitiated) {
            let transcriber = Transcriber(settings: settings)
            let tracks = [
                Transcriber.Track(label: "Them", url: directory.appendingPathComponent("them.caf")),
                Transcriber.Track(label: "Me", url: directory.appendingPathComponent("me.caf")),
            ].filter { FileManager.default.fileExists(atPath: $0.url.path) }

            do {
                let transcript = try transcriber.run(tracks: tracks, in: directory)
                await MainActor.run {
                    self.status = .idle
                    self.loadRecent()
                    self.notify(title: "Transcript ready",
                                body: directory.lastPathComponent,
                                open: transcript)
                }
            } catch {
                await MainActor.run {
                    self.status = .failed(explain(error))
                    self.notify(title: "Transcription failed", body: explain(error), open: nil)
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

    // MARK: - Helpers

    private func loadRecent() {
        let root = settings.recordingsRoot
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        recent = sessions
            .map { $0.appendingPathComponent("transcript.txt") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.deletingLastPathComponent().lastPathComponent > $1.deletingLastPathComponent().lastPathComponent }
            .prefix(8)
            .map { $0 }
    }

    private func notify(title: String, body: String, open url: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

}
