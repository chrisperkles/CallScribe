import Foundation

/// Whisper models are too big to ship inside the app (and would be re-downloaded
/// on every update), so they're fetched once on first run and kept in
/// Application Support.
@MainActor
final class ModelStore: ObservableObject {

    struct Model: Identifiable, Hashable {
        let id: String              // file name
        let name: String
        let detail: String
        let approximateBytes: Int64

        var url: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(id)")!
        }
    }

    nonisolated static let available: [Model] = [
        Model(id: "ggml-large-v3-turbo-q5_0.bin",
              name: "Turbo (recommended)",
              detail: "Best accuracy, fast on Apple Silicon",
              approximateBytes: 547_000_000),
        Model(id: "ggml-small-q5_1.bin",
              name: "Small",
              detail: "Lighter and quicker, noticeably less accurate",
              approximateBytes: 181_000_000),
    ]

    enum State: Equatable {
        case missing
        case downloading(progress: Double)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CallScribe/Models", isDirectory: true)
    }

    /// A model already on disk: the configured one, a previously downloaded one,
    /// or a hand-placed file in ~/whisper-models.
    nonisolated static func locateExisting(preferring configured: String?) -> URL? {
        let fm = FileManager.default

        if let configured, fm.fileExists(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }
        for model in available {
            let candidate = directory.appendingPathComponent(model.id)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // Respect a manually maintained collection.
        let manual = fm.homeDirectoryForCurrentUser.appendingPathComponent("whisper-models")
        if let files = try? fm.contentsOfDirectory(at: manual, includingPropertiesForKeys: nil),
           let match = files.first(where: { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }) {
            return match
        }
        return nil
    }

    func refresh(configured: String?) {
        if case .downloading = state { return }
        if let existing = Self.locateExisting(preferring: configured) {
            state = .ready(existing)
        } else {
            state = .missing
        }
    }

    func download(_ model: Model) {
        if case .downloading = state { return }
        state = .downloading(progress: 0)

        let destination = Self.directory.appendingPathComponent(model.id)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(with: model.url) { [weak self] temporary, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.observation = nil
                self.task = nil

                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                guard let temporary,
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    self.state = .failed("Download failed — check your internet connection.")
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    self.state = .ready(destination)
                } catch {
                    self.state = .failed(explain(error))
                }
            }
        }

        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(progress: progress.fractionCompleted)
            }
        }

        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        observation = nil
        state = .missing
    }
}
