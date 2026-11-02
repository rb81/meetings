import FluidAudio
import Foundation
import Observation
import os

/// Downloads the speech models once, then loads them from disk on every later launch.
///
/// After a successful setup a marker file is written. From then on the app never contacts
/// Hugging Face by itself: loading runs with FluidAudio's network access switched off, and a
/// problem is reported instead of silently downloading again. Downloading again is always your choice.
@MainActor
@Observable
final class ModelManager {
    enum State: Equatable {
        case notDownloaded
        case working(progress: Double, detail: String)
        case loading
        case ready
        case failed(String)
    }

    static let version = AsrModelVersion.v3

    private(set) var state: State = .notDownloaded
    private(set) var asr: AsrManager?
    private(set) var vad: VadManager?
    private(set) var diarizer: OfflineDiarizerManager?
    private(set) var diarizerModels: OfflineDiarizerModels?
    private(set) var speakerModelIssue: String?
    /// The streaming model that tells voices apart in the room while a meeting is still running.
    private(set) var liveSpeakers: Nemotron3Models?
    /// True when every model for in-person meetings is on disk: the live one, the careful one used after the
    /// meeting, and the voice print model that joins a voice the speaker model split in two.
    private(set) var hasRoomModels = false
    private(set) var liveSpeakerIssue: String?
    private(set) var isDownloadingRoomModels = false
    /// How far the in-person model download has got, from 0 to 1.
    private(set) var roomDownloadProgress = 0.0
    @ObservationIgnored private var roomTask: Task<Bool, Never>?

    private var root: URL?
    private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.rakan.Meetings", category: "models")

    var isReady: Bool { state == .ready }

    #if DEBUG
    func setPreviewReady() {
        state = .ready
    }
    #endif

    /// Points the manager at a data folder. If setup was completed there, models load quietly from disk.
    func configure(dataFolder: URL) {
        task?.cancel()
        task = nil
        asr = nil
        vad = nil
        diarizer = nil
        diarizerModels = nil
        speakerModelIssue = nil
        liveSpeakers = nil
        hasRoomModels = false
        liveSpeakerIssue = nil

        let root = dataFolder.appendingPathComponent("models", isDirectory: true)
        self.root = root
        state = .notDownloaded

        if FileManager.default.fileExists(atPath: Self.markerURL(in: root).path) {
            task = Task { [weak self] in await self?.loadLocal(root: root) }
        } else if AsrModels.modelsExist(at: Self.asrDirectory(in: root), version: Self.version) {
            // Downloaded by an earlier build that wrote no marker. Verify once, then it stays offline.
            prepare()
        }
    }

    /// Downloads whatever is missing (or checks the files again), then loads. This is the only path that uses the network.
    func prepare() {
        guard let root, task == nil else { return }
        task = Task { [weak self] in
            await self?.download(root: root)
        }
    }

    /// A speaker separator for one pass over a recording. `maxSpeakers` stops one voice from being split into
    /// many, which is the usual way room recordings go wrong. Falls back to the standard separator.
    /// Pass `exactly` when you know how many people there were, which is the strongest hint there is.
    func makeDiarizer(maxSpeakers: Int?, exactly: Int? = nil) -> OfflineDiarizerManager? {
        guard let diarizerModels else { return diarizer }

        let config: OfflineDiarizerConfig
        if let exactly {
            config = OfflineDiarizerConfig.default.withSpeakers(exactly: exactly)
        } else if let maxSpeakers {
            config = OfflineDiarizerConfig.default.withSpeakers(max: maxSpeakers)
        } else {
            return diarizer
        }

        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: diarizerModels)
        return manager
    }

    /// The speaker models that are still missing, in plain words. Nil when everything is in place.
    var missingSpeakerModels: String? {
        guard state == .ready else { return nil }
        switch (diarizer == nil, !hasRoomModels || liveSpeakers == nil) {
        case (true, true): return "the speaker models"
        case (true, false): return "the speaker model for online meetings"
        case (false, true): return "the in-person speaker models"
        case (false, false): return nil
        }
    }

    /// Downloads whichever speaker models are missing. Like every download here, only when you ask.
    func downloadMissingSpeakerModels() {
        if diarizer == nil {
            prepare()
        } else {
            downloadRoomModels()
        }
    }

    /// Downloads the in-person speaker models, for installs that were set up before they existed.
    /// Like every other model download, this only happens when you ask for it. Asking again while it's running
    /// returns the same download. The task's value is true once the models are ready.
    @discardableResult
    func downloadRoomModels() -> Task<Bool, Never>? {
        if let roomTask { return roomTask }
        guard let root else { return nil }
        isDownloadingRoomModels = true
        roomDownloadProgress = 0
        liveSpeakerIssue = nil

        let task = Task { [weak self] () -> Bool in
            var ready = false
            do {
                let live = try await Self.fetchRoomModels(root: root) { fraction in
                    Task { @MainActor in self?.roomDownloadProgress = fraction }
                }
                if let self, self.root == root {
                    self.liveSpeakers = live
                    self.hasRoomModels = true
                    Self.writeMarker(in: root, speakerModels: self.diarizerModels != nil, roomModels: true)
                    ready = true
                }
            } catch {
                self?.liveSpeakerIssue = error.localizedDescription
                self?.log.error("In-person speaker models failed to download: \(error.localizedDescription)")
            }
            self?.isDownloadingRoomModels = false
            self?.roomTask = nil
            return ready
        }
        roomTask = task
        return task
    }

    /// The careful speaker model and the voice print model, loaded from disk for one pass over a recording.
    /// They are loaded only when needed, because together they are large. Nil when they aren't downloaded.
    func loadRoomModels() async -> (speakers: Nemotron3Models, prints: CampPlusModels?)? {
        guard let root else { return nil }
        return await Self.loadRoomModels(in: root)
    }

    /// Loads the in-person models from a models folder, without ever downloading. Also used by the scoring tests.
    static func loadRoomModels(in root: URL) async -> (speakers: Nemotron3Models, prints: CampPlusModels?)? {
        guard roomModelsExist(in: root) else { return nil }
        do {
            let speakers = try await Nemotron3Models.loadFromHuggingFace(
                config: SpeakerModels.careful,
                cacheDirectory: roomDirectory(in: root)
            )
            let prints = try? CampPlusModels.load(from: voicePrintDirectory(in: root))
            return (speakers, prints)
        } catch {
            Logger(subsystem: "com.rakan.Meetings", category: "models")
                .error("The careful speaker model couldn't be loaded: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Locations

    private static func asrDirectory(in root: URL) -> URL {
        root.appendingPathComponent("asr", isDirectory: true)
    }

    private static func vadDirectory(in root: URL) -> URL {
        root.appendingPathComponent("vad", isDirectory: true)
    }

    private static func diarizerDirectory(in root: URL) -> URL {
        root.appendingPathComponent("diarizer", isDirectory: true)
    }

    /// Where an earlier build kept its live speaker model. Removed once the new models are in place.
    private static func oldLiveSpeakerDirectory(in root: URL) -> URL {
        root.appendingPathComponent("sortformer", isDirectory: true)
    }

    private static func roomDirectory(in root: URL) -> URL {
        root.appendingPathComponent("nemotron3", isDirectory: true)
    }

    /// FluidAudio's download puts the files in a folder named after the repository.
    private static func voicePrintParent(in root: URL) -> URL {
        root.appendingPathComponent("campplus", isDirectory: true)
    }

    private static func voicePrintDirectory(in root: URL) -> URL {
        voicePrintParent(in: root).appendingPathComponent(Repo.campPlus.folderName, isDirectory: true)
    }

    /// Checked before every load, so a missing file is reported instead of quietly downloaded.
    private static func roomModelsExist(in root: URL) -> Bool {
        let fm = FileManager.default
        let repo = roomDirectory(in: root).appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
        let assets = [ModelNames.Nemotron3.silenceEmbeddingFile, ModelNames.Nemotron3.weightsVersionFile]
        let bundles = [SpeakerModels.live, SpeakerModels.careful].map {
            "\($0.hubSubdirectory)/\($0.modelFileName)/coremldata.bin"
        }
        return (assets + bundles).allSatisfy { fm.fileExists(atPath: repo.appendingPathComponent($0).path) }
            && CampPlusModels.modelsExist(at: voicePrintDirectory(in: root))
    }

    /// Downloads the in-person models (about 430 MB) and returns the live one, loaded.
    /// `progress` gets the overall fraction done, from 0 to 1.
    private static func fetchRoomModels(
        root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Nemotron3Models {
        let directory = roomDirectory(in: root)
        // The two speaker models are about 200 MB each and the voice print model about 30 MB.
        func stage(_ offset: Double, _ scale: Double) -> ProgressHandler {
            { update in progress(offset + scale * min(max(update.fractionCompleted, 0), 1)) }
        }
        progress(0)
        _ = try await Nemotron3Models.loadFromHuggingFace(
            config: SpeakerModels.careful,
            cacheDirectory: directory,
            progressHandler: stage(0, 0.46)
        )
        try await ModelHub.download(.campPlus, to: voicePrintParent(in: root))
        progress(0.54)
        let live = try await Nemotron3Models.loadFromHuggingFace(
            config: SpeakerModels.live,
            cacheDirectory: directory,
            progressHandler: stage(0.54, 0.46)
        )
        progress(1)
        try? FileManager.default.removeItem(at: oldLiveSpeakerDirectory(in: root))
        return live
    }

    private static func markerURL(in root: URL) -> URL {
        root.appendingPathComponent(".setup-complete.json")
    }

    private static func writeMarker(in root: URL, speakerModels: Bool, roomModels: Bool) {
        let info: [String: Any] = [
            "model": "parakeet-tdt-0.6b-v3",
            "speakerModels": speakerModels,
            "roomSpeakerModels": roomModels ? "nemotron-3-diarization + campplus-v2" : false,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: markerURL(in: root), options: .atomic)
        }
    }

    // MARK: - Loading from disk (no network)

    private func loadLocal(root: URL) async {
        state = .loading

        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }

        do {
            let models = try await AsrModels.load(from: Self.asrDirectory(in: root), version: Self.version)
            let manager = AsrManager()
            try await manager.loadModels(models)

            let vadManager = try await VadManager(modelDirectory: Self.vadDirectory(in: root))

            var speakerManager: OfflineDiarizerManager?
            var speakerModels: OfflineDiarizerModels?
            var issue: String?
            do {
                let loaded = try await OfflineDiarizerModels.load(from: Self.diarizerDirectory(in: root))
                let created = OfflineDiarizerManager()
                created.initialize(models: loaded)
                speakerManager = created
                speakerModels = loaded
            } catch {
                issue = error.localizedDescription
                log.error("Speaker models unavailable offline: \(error.localizedDescription)")
            }

            var live: Nemotron3Models?
            var liveIssue: String?
            let hasRoom = Self.roomModelsExist(in: root)
            if hasRoom {
                do {
                    live = try await Nemotron3Models.loadFromHuggingFace(
                        config: SpeakerModels.live,
                        cacheDirectory: Self.roomDirectory(in: root)
                    )
                } catch {
                    liveIssue = error.localizedDescription
                    log.error("Live speaker model unavailable offline: \(error.localizedDescription)")
                }
            }

            guard self.root == root, !Task.isCancelled else { return }
            asr = manager
            vad = vadManager
            diarizer = speakerManager
            diarizerModels = speakerModels
            speakerModelIssue = issue
            liveSpeakers = live
            hasRoomModels = hasRoom
            liveSpeakerIssue = liveIssue
            state = .ready
        } catch {
            log.error("Loading models from disk failed: \(error.localizedDescription)")
            guard self.root == root, !Task.isCancelled else { return }
            state = .failed("The speech model couldn't be loaded from your data folder. \(error.localizedDescription)")
        }
        task = nil
    }

    // MARK: - Downloading (network, only when you ask)

    private func download(root: URL) async {
        state = .working(progress: 0, detail: "Preparing…")

        do {
            let asrProgress: ProgressHandler = { progress in
                Task { @MainActor in self.report(progress, scale: 0.8, offset: 0) }
            }
            let models = try await AsrModels.downloadAndLoad(
                to: Self.asrDirectory(in: root),
                version: Self.version,
                progressHandler: asrProgress
            )
            let manager = AsrManager()
            try await manager.loadModels(models)

            let vadProgress: ProgressHandler = { progress in
                Task { @MainActor in self.report(progress, scale: 0.04, offset: 0.8) }
            }
            let vadManager = try await VadManager(
                modelDirectory: Self.vadDirectory(in: root),
                progressHandler: vadProgress
            )

            state = .working(progress: 0.85, detail: "Downloading speaker models…")
            let speakerManager = OfflineDiarizerManager()
            var issue: String?
            do {
                try await speakerManager.prepareModels(directory: Self.diarizerDirectory(in: root))
            } catch {
                issue = error.localizedDescription
                log.error("Speaker models failed to download: \(error.localizedDescription)")
            }

            var speakerModels: OfflineDiarizerModels?
            if issue == nil {
                speakerModels = try? await OfflineDiarizerModels.load(from: Self.diarizerDirectory(in: root))
            }

            state = .working(progress: 0.88, detail: "Downloading in-person speaker models…")
            let roomProgress: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in
                    guard case .working = self.state else { return }
                    self.state = .working(progress: 0.88 + 0.06 * fraction, detail: "Downloading in-person speaker models…")
                }
            }
            var live: Nemotron3Models?
            var liveIssue: String?
            do {
                live = try await Self.fetchRoomModels(root: root, progress: roomProgress)
            } catch {
                liveIssue = error.localizedDescription
                log.error("Live speaker model failed to download: \(error.localizedDescription)")
            }

            guard self.root == root, !Task.isCancelled else { return }
            asr = manager
            vad = vadManager
            diarizer = issue == nil ? speakerManager : nil
            diarizerModels = speakerModels
            speakerModelIssue = issue
            liveSpeakers = live
            hasRoomModels = live != nil
            liveSpeakerIssue = liveIssue
            Self.writeMarker(in: root, speakerModels: issue == nil, roomModels: live != nil)
            state = .ready
        } catch {
            guard self.root == root, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
        task = nil
    }

    private func report(_ progress: DownloadProgress, scale: Double, offset: Double) {
        guard case .working = state else { return }

        let detail: String
        switch progress.phase {
        case .listing:
            detail = "Preparing…"
        case .downloading(let done, let total):
            detail = "Downloading model files (\(done) of \(total))"
        case .compiling:
            detail = "Optimizing for your Mac…"
        }
        state = .working(progress: offset + progress.fractionCompleted * scale, detail: detail)
    }
}
