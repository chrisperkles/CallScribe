import SwiftUI

@main
struct CallScribeApp: App {
    @StateObject private var state = AppState()

    init() {
        if SelfTest.isRequested { SelfTest.run() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Label("CallScribe", systemImage: state.symbolName)
                .labelStyle(.iconOnly)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var state: AppState
    @State private var elapsed = ""

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        switch state.status {
        case .recording(let since):
            Text("Recording — \(elapsed)")
            Button("Stop & Transcribe") { state.stop() }
                .keyboardShortcut("r")
            Divider()
                .onReceive(tick) { _ in
                    elapsed = Transcriber.clock(Date().timeIntervalSince(since))
                }

        case .transcribing(let session):
            Text("Transcribing \(session)…")
            Divider()

        case .failed(let message):
            Text(message)
            Button("Dismiss") { state.dismissError() }
            Divider()
            Button("Start Recording") { state.toggle() }
                .keyboardShortcut("r")
            Divider()

        case .idle:
            Button("Start Recording") { state.toggle() }
                .keyboardShortcut("r")
            Divider()
        }

        if !state.recent.isEmpty {
            Menu("Recent Transcripts") {
                ForEach(state.recent, id: \.self) { url in
                    Button(url.deletingLastPathComponent().lastPathComponent) { state.open(url) }
                }
            }
        }
        Button("Open Recordings Folder") { state.openRecordingsFolder() }
        Toggle("Launch at Login", isOn: Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { _ in LaunchAtLogin.toggle() }))
        Divider()
        Button("Quit CallScribe") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension AppState {
    var symbolName: String {
        switch status {
        case .idle: return "mic"
        case .recording: return "record.circle"
        case .transcribing: return "waveform"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
