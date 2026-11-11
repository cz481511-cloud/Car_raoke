import AVFoundation
import Foundation
import Observation

/// 手機去人聲的排隊和進度：歌曲庫裡出現新的一般音檔（從檔案匯入、AirDrop、Finder 拖進來）就自動排隊，
/// 一首一首做。離開 App、手機太熱、接著 CarPlay 時暫停，情況解除後自動繼續。
@MainActor
@Observable
final class SongConverter {
    enum PauseReason: Hashable, Sendable {
        case background, hot, carPlay

        var message: String {
            switch self {
            case .background: return "已暫停，回到車上K歌就會繼續"
            case .hot: return "手機有點熱，降溫後自動繼續"
            case .carPlay: return "接著 CarPlay，停車拔掉後自動繼續"
            }
        }
    }

    struct Job: Identifiable, Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case waiting
            case working(step: SongPipeline.Step, progress: Double)
            case failed(String)
            case done(String)
        }

        let id = UUID()
        let source: URL
        let title: String
        var stage: Stage = .waiting
    }

    private(set) var jobs: [Job] = []
    private(set) var pauseReasons: Set<PauseReason> = []
    var isPaused: Bool { !pauseReasons.isEmpty }

    /// 新歌做好、歌曲庫重新整理之後呼叫（讓播放器換成新的檔案）
    var onLibraryChanged: (() -> Void)?

    private let pipeline: SongPipeline
    private let defaults: UserDefaults
    private var library: Library?
    private var worker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// 不自動處理的一般音檔（檔名）：這版第一次打開時就在的、做失敗的、使用者移除的
    private var skipped: Set<String>
    private static let skippedKey = "onDevice.skippedPlainFiles"

    init(pipeline: SongPipeline = SongPipeline(separator: DemucsSeparator(), lyrics: LyricsFinder(source: LRCLIBSource())),
         defaults: UserDefaults = .standard) {
        self.pipeline = pipeline
        self.defaults = defaults
        skipped = Set(defaults.stringArray(forKey: Self.skippedKey) ?? [])
    }

    /// 開始管理這個歌曲庫。第一次（這個功能剛裝上）時，原本就在的一般音檔不會被自動處理，
    /// 要的話長按那首歌選「手機去人聲」。
    func attach(library: Library) {
        self.library = library
        if defaults.stringArray(forKey: Self.skippedKey) == nil {
            skipped = Set(library.songs.filter { !$0.isBackingTrack }.map { $0.mainURL.lastPathComponent })
            saveSkipped()
        }
        watchConditions()
        scan()
    }

    /// 找歌曲庫裡新出現的一般音檔，排進佇列
    func scan() {
        guard let library else { return }
        let queued = Set(jobs.map { $0.source.lastPathComponent })
        for song in library.songs.reversed() where !song.isBackingTrack {  // 先加進來的先做
            let name = song.mainURL.lastPathComponent
            guard !skipped.contains(name), !queued.contains(name) else { continue }
            jobs.append(Job(source: song.mainURL, title: song.title))
        }
        startIfNeeded()
    }

    /// 長按一首一般音檔 →「手機去人聲」
    func enqueue(_ song: Song) {
        guard !song.isBackingTrack else { return }
        let name = song.mainURL.lastPathComponent
        skipped.remove(name)
        saveSkipped()
        if let i = jobs.firstIndex(where: { $0.source.lastPathComponent == name }) {
            if case .failed = jobs[i].stage { jobs[i].stage = .waiting }
        } else {
            jobs.append(Job(source: song.mainURL, title: song.title))
        }
        startIfNeeded()
    }

    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), case .failed = jobs[i].stage else { return }
        skipped.remove(jobs[i].source.lastPathComponent)
        saveSkipped()
        jobs[i].stage = .waiting
        startIfNeeded()
    }

    /// 從列表移除（做失敗的那首不會再自動處理，原檔留在歌曲庫）
    func dismiss(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if case .working = jobs[i].stage { return }
        if case .waiting = jobs[i].stage { skip(jobs[i].source) }
        jobs.remove(at: i)
    }

    func isQueued(_ song: Song) -> Bool {
        jobs.contains { job in
            guard job.source.lastPathComponent == song.mainURL.lastPathComponent else { return false }
            if case .failed = job.stage { return false }
            return true
        }
    }

    // MARK: 暫停條件

    /// App 在前景時才做（iOS 不讓背景做這麼重的工作）
    func setActive(_ active: Bool) {
        setPaused(.background, !active)
    }

    func setPaused(_ reason: PauseReason, _ paused: Bool) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
    }

    private func watchConditions() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThermal() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCarPlay() }
        })
        updateThermal()
        updateCarPlay()
    }

    private func updateThermal() {
        let state = ProcessInfo.processInfo.thermalState
        setPaused(.hot, state == .serious || state == .critical)
    }

    private func updateCarPlay() {
        let car = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
        setPaused(.carPlay, car)
    }

    // MARK: 處理

    private func startIfNeeded() {
        guard worker == nil, jobs.contains(where: { $0.stage == .waiting }) else { return }
        worker = Task { [weak self] in
            await self?.work()
            self?.worker = nil
        }
    }

    private func work() async {
        while let i = jobs.firstIndex(where: { $0.stage == .waiting }), let folder = library?.folder {
            let id = jobs[i].id
            let source = jobs[i].source
            update(id, .working(step: .reading, progress: 0))
            let pipeline = self.pipeline
            let result: Result<SongPipeline.Outcome, Error> = await Task.detached(priority: .userInitiated) {
                // 這個迴圈本來就在 self 的工作裡跑，做完才結束，所以直接用 self（不需要 weak）
                do {
                    let outcome = try await pipeline.convert(source, in: folder, progress: { step, p in
                        Task { @MainActor in self.update(id, .working(step: step, progress: p)) }
                    }, checkpoint: {
                        while await self.isPaused {
                            try await Task.sleep(for: .milliseconds(500))
                        }
                        try Task.checkCancellation()
                    })
                    return .success(outcome)
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(.converted(_, let hasLyrics)):
                update(id, .done(hasLyrics ? "完成，可以切換原唱／伴唱，也有歌詞" : "完成，可以切換原唱／伴唱（找不到歌詞）"))
            case .success(.alreadyExists):
                try? FileManager.default.removeItem(at: source)  // 匯入的是重複的一份
                update(id, .done("歌曲庫裡已經有這首，沒有重做"))
            case .failure(let error):
                skip(source)
                update(id, .failed((error as? LocalizedError)?.errorDescription ?? "去人聲失敗：\(error.localizedDescription)"))
            }
            library?.reload()
            onLibraryChanged?()
            removeLater(id)
        }
    }

    private func update(_ id: UUID, _ stage: Job.Stage) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if case .working = stage {
            switch jobs[i].stage {
            case .done, .failed: return  // 已經做完，晚到的進度不要蓋掉結果
            default: break
            }
        }
        jobs[i].stage = stage
    }

    /// 做好的那一列 8 秒後自動收起（失敗的留著，讓使用者看原因、重試）
    private func removeLater(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), case .done = job.stage else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.jobs.removeAll { $0.id == id }
        }
    }

    private func skip(_ url: URL) {
        skipped.insert(url.lastPathComponent)
        saveSkipped()
    }

    private func saveSkipped() {
        defaults.set(Array(skipped).sorted(), forKey: Self.skippedKey)
    }
}
