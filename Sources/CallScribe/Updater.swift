import AppKit
import Combine
import Sparkle

/// In-app updates, with Sparkle. Once a day CallScribe reads its appcast
/// (`SUFeedURL` in Info.plist); a newer version is downloaded, checked against
/// the EdDSA key (`SUPublicEDKey`) and Apple's signature, put in place of this
/// copy and reopened, after one click.
///
/// A daily check that finds something doesn't pop up mid-call: it waits in the
/// panel as "Update to CallScribe 1.2…" until you open it. And an update is
/// never installed while a recording or transcription is running — the
/// relaunch is held back until the app is idle again.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    /// Version found by the daily check, waiting for the user to open it.
    @Published private(set) var available: String?
    /// The user said install, but a recording is running: it goes in afterwards.
    @Published private(set) var waitingForIdle = false
    @Published private(set) var canCheck = false

    private var controller: SPUStandardUpdaterController!
    private var postponedInstall: (() -> Void)?
    private var isBusy = false
    private var subscriptions: Set<AnyCancellable> = []

    init(state: AppState) {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &subscriptions)

        state.$status
            .sink { [weak self] status in self?.statusChanged(status) }
            .store(in: &subscriptions)

        // A build without a feed (a source build that didn't set one) has
        // nothing to check against.
        guard controller.updater.feedURL != nil else { return }
        controller.startUpdater()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// "Check for Updates…" and the waiting update's button: Sparkle's window, in front.
    func checkNow() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    private func statusChanged(_ status: AppState.Status) {
        switch status {
        case .recording, .transcribing: isBusy = true
        case .idle, .failed: isBusy = false
        }
        guard !isBusy, let install = postponedInstall else { return }
        postponedInstall = nil
        waitingForIdle = false
        install()
    }

    // MARK: Never in the middle of a call

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle calls this, and later wants the handler called, on the main thread.
        nonisolated(unsafe) let install = installHandler
        return MainActor.assumeIsolated {
            guard isBusy else { return false }
            postponedInstall = install
            waitingForIdle = true
            NSLog("CallScribe: update \(item.displayVersionString) waits for the recording to finish")
            return true
        }
    }

    // MARK: Gentle reminders

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// An update the daily check found waits in the panel instead of popping up.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                NSApp.activate()
            } else {
                available = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { available = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { available = nil }
    }
}
