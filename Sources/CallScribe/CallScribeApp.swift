import SwiftUI

@main
struct CallScribeApp: App {
    @StateObject private var state = AppState()

    init() {
        if SelfTest.isRequested { SelfTest.run() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(state: state)
                .frame(width: 320)
        } label: {
            Image(systemName: state.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppState {
    var symbolName: String {
        switch status {
        case .idle: return needsModel ? "mic.badge.xmark" : "mic"
        case .recording: return "record.circle.fill"
        case .transcribing: return "waveform"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var state: AppState
    @State private var elapsed = "00:00:00"
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch state.models.state {
            case .ready:
                controls
            default:
                ModelSetupView(store: state.models)
            }

            Divider()
            footer
        }
        .padding(14)
        .onReceive(tick) { _ in
            if case .recording(_, let since) = state.status {
                elapsed = Transcriber.clock(Date().timeIntervalSince(since))
            }
        }
    }

    private var header: some View {
        HStack {
            Text("CallScribe").font(.headline)
            Spacer()
            if case .recording(let mode, _) = state.status {
                Label(mode == .call ? "Call" : "Room", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state.status {
        case .recording:
            VStack(spacing: 8) {
                Text(elapsed)
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Button {
                    state.stop()
                } label: {
                    Label("Stop & Transcribe", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

        case .transcribing(let session):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing \(session)…").font(.callout)
                Text("This runs entirely on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { state.dismissError() }
            }

        case .idle:
            VStack(spacing: 8) {
                Button {
                    Task { await state.start(mode: .call) }
                } label: {
                    Label(RecordingMode.call.title, systemImage: "phone")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await state.start(mode: .meeting) }
                } label: {
                    Label(RecordingMode.meeting.title, systemImage: "person.3")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                Text("Call records both sides. Room records the microphone only, for meetings in person.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.recent.isEmpty {
                Menu("Recent Transcripts") {
                    ForEach(state.recent, id: \.self) { url in
                        Button(url.deletingLastPathComponent().lastPathComponent) { state.open(url) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button("Open Recordings Folder") { state.openRecordingsFolder() }
                .buttonStyle(.link)

            Toggle("Start at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.callout)
                .onChange(of: launchAtLogin) { _, value in LaunchAtLogin.setEnabled(value) }

            CheckForUpdatesButton()

            Button("Quit CallScribe") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
    }
}

// MARK: - Model setup

struct ModelSetupView: View {
    @ObservedObject var store: ModelStore

    var body: some View {
        switch store.state {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading speech model…").font(.callout)
                ProgressView(value: progress)
                HStack {
                    Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { store.cancel() }.buttonStyle(.link).font(.caption)
                }
            }

        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("One-time setup").font(.callout).bold()
                Text("CallScribe transcribes on your Mac, so it needs to download a speech model once. Nothing is ever sent to a server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .failed(let message) = store.state {
                    Text(message).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(ModelStore.available) { model in
                    Button {
                        store.download(model)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(model.name) · \(model.approximateBytes / 1_000_000) MB")
                            Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
