import SwiftUI
import Sparkle

/// Keeps every install in the office current without anyone touching a terminal:
/// Sparkle checks the appcast, and offers the update in place.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = 60 * 60 * 24   // daily

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates… (v\(updater.currentVersion))") {
            updater.checkForUpdates()
        }
        .buttonStyle(.link)
        .disabled(!updater.canCheck)
    }
}
