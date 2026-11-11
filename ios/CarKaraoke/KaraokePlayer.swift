import AVFoundation
import MediaPlayer
import Observation
import UIKit

enum VocalMode: String, CaseIterable, Identifiable {
    case karaoke, guide, original
    var id: String { rawValue }

    var label: String {
        switch self {
        case .karaoke: return "伴唱"
        case .guide: return "導唱"
        case .original: return "原唱"
        }
    }

    /// 人聲音量
    var vocalVolume: Float {
        switch self {
        case .karaoke: return 0
        case .guide: return 0.3
        case .original: return 1
        }
    }
}

/// 播放器：伴唱軌＋人聲軌同步播放，可切 伴唱／導唱／原唱、升降 Key。
///
/// 為了省電、省運算：
/// - 伴唱模式完全不解碼人聲檔（只播一軌）
/// - Key = 0 時變調器直接旁路（bypass）
/// - 暫停時音訊引擎整個停下來
///
/// 車機（CarPlay）的「正在播放」畫面和方向盤按鍵，透過 MPNowPlayingInfoCenter／MPRemoteCommandCenter 控制。
@MainActor
@Observable
final class KaraokePlayer {
    private(set) var queue: [Song] = []
    private(set) var index: Int?
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var artwork: UIImage?
    var errorMessage: String?

    // 唱歌評分
    private(set) var scoringEnabled = false
    /// 這首歌有原唱音高資料（新版轉換工具轉的才有）
    private(set) var currentSongScorable = false
    private(set) var lastScore: ScoreResult?
    private(set) var inputOptions: [InputOption] = []
    var announceScore: Bool {
        didSet { UserDefaults.standard.set(announceScore, forKey: Keys.announce) }
    }

    // 歌詞
    /// 目前這首的時間同步歌詞（沒有就是 nil）
    private(set) var lyrics: Lyrics?
    /// 正在唱第幾行（nil = 前奏、還沒到第一行）
    private(set) var lyricIndex: Int?
    /// 這首歌的歌詞時間調整：正數 = 提早顯示（秒）
    private(set) var lyricsOffset: TimeInterval = 0
    /// 目前載入的歌詞檔修改時間（檔案換新時重新載入）
    @ObservationIgnored private var lyricsFileDate: Date?
    /// 車機「正在播放」畫面顯示歌詞（標題 = 這一行、副標 = 下一行）
    var carLyrics: Bool {
        didSet {
            UserDefaults.standard.set(carLyrics, forKey: Keys.carLyrics)
            updateNowPlaying()
        }
    }
    /// 字幕比歌聲早一點點出現，比較好跟著唱
    static let lyricLead: TimeInterval = 0.15

    struct InputOption: Identifiable, Hashable {
        let id: String
        let name: String
        let isCurrent: Bool
    }

    private(set) var mode: VocalMode
    /// 升降 Key（半音），-6 … +6
    private(set) var keyShift: Int

    static let keyRange = -6...6

    func setMode(_ newMode: VocalMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Keys.mode)
        syncVocals()
        updateNowPlaying()
    }

    func setKey(_ value: Int) {
        let clamped = min(max(value, Self.keyRange.lowerBound), Self.keyRange.upperBound)
        guard clamped != keyShift else { return }
        keyShift = clamped
        UserDefaults.standard.set(clamped, forKey: Keys.key)
        applyPitch()
        syncScorerTiming()
        updateNowPlaying()
    }

    // MARK: - 唱歌評分

    /// 開／關評分。開啟時才會用麥克風（關閉時完全不收音、不運算）。
    /// 麥克風接在播放器同一個音訊引擎上，播放時才收音。
    func setScoring(_ on: Bool) async {
        let session = AVAudioSession.sharedInstance()
        if on {
            guard await AVAudioApplication.requestRecordPermission() else {
                errorMessage = ScoringError.permissionDenied.localizedDescription
                return
            }
            guard !scoringEnabled else { return }
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true)
                guard session.isInputAvailable else { throw ScoringError.noMicrophone }
            } catch {
                try? session.setCategory(.playback, mode: .default)
                errorMessage = "無法開啟麥克風：\(error.localizedDescription)"
                refreshInputs()
                return
            }
            scoringEnabled = true
            restartAudio()  // 引擎停下重開，重開時才接上麥克風
        } else {
            guard scoringEnabled else { return }
            scoringEnabled = false
            // 碰過麥克風的引擎在「只播放」模式下開不起來，換一個新的
            restartAudio(rebuild: true) {
                try? session.setCategory(.playback, mode: .default)
            }
        }
        refreshInputs()
    }

    func selectInput(_ id: String) {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else { return }
        do {
            // 換了麥克風、格式跟著變的話，系統會通知引擎設定改變（handleConfigurationChange 會用新格式接回來）
            try session.setPreferredInput(port)
        } catch {
            errorMessage = "無法切換麥克風：\(error.localizedDescription)"
        }
        refreshInputs()
    }

    func dismissScore() {
        lastScore = nil
        scoreBadgeSongID = nil
        updateNowPlaying()
    }

    private func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        let currentID = session.currentRoute.inputs.first?.uid
        inputOptions = (session.availableInputs ?? []).map {
            InputOption(id: $0.uid, name: Self.inputName($0), isCurrent: $0.uid == currentID)
        }
    }

    private static func inputName(_ port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInMic: return "iPhone 麥克風"
        case .carAudio: return "車機麥克風"
        case .usbAudio: return "USB 麥克風（\(port.portName)）"
        case .headsetMic: return "耳機麥克風"
        default: return port.portName
        }
    }

    /// 換歌前結算上一首的分數；有算出分數時回傳 true
    @discardableResult
    private func finishScore() -> Bool {
        let result = scorer.finish()
        guard scoringEnabled, let result else { return false }
        lastScore = result
        if announceScore { announce("\(result.score)分，\(result.comment)") }
        return true
    }

    /// 用語音報分數。語音先合成成聲音，再從播放器自己的音訊引擎放出來：
    /// 不另外開一個聲音來源，才不會在換歌的瞬間把正在播的歌打斷或弄到沒聲音。
    private func announce(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        let synthesizer = speech ?? AVSpeechSynthesizer()
        speech = synthesizer
        let feed = VoiceFeed(node: voiceNode, format: Self.voiceFormat)
        let scheduled: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.voiceDidSchedule() } }
        let finished: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.voiceDidFinish() } }
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, feed.schedule(pcm, done: finished) else { return }
            scheduled()
        }
    }

    private func voiceDidSchedule() {
        voiceBuffers += 1
        guard mainFile != nil, engine.isRunning || startEngine() else { return }  // 按了停止就不報了
        if !voiceNode.isPlaying { _ = start(voiceNode) }
    }

    private func voiceDidFinish() {
        voiceBuffers = max(voiceBuffers - 1, 0)
        if voiceBuffers == 0, !isPlaying, retryTask == nil, engine.isRunning { stopEngine() }  // 最後一首唱完、報完分數才停引擎
    }

    private func beginScore(for song: Song) {
        currentSongScorable = false
        scorer.begin(nil)
        let id = song.id
        Task {
            let reference = await ReferencePitch.load(song.mainURL)
            guard current?.id == id, let reference else { return }
            scorer.begin(ScoreKeeper(title: song.title, reference: reference.data, fps: reference.fps))
            currentSongScorable = true
            self.reference = (reference.data, reference.fps)
            lyrics?.refineEnds(reference: reference.data, fps: reference.fps)
        }
    }

    private func syncScorerTiming() {
        scorer.updateTiming(playing: isPlaying, startedFrom: startedFrom, startedHostTime: startedHostTime,
                            keyShift: keyShift)
    }

    var current: Song? {
        guard let index, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    /// 目前播放到第幾秒（用系統時鐘推算，不必等音訊回呼）
    var currentTime: TimeInterval {
        guard isPlaying else { return pausedAt }
        let now = mach_absolute_time()
        let elapsed = now > startedHostTime ? AVAudioTime.seconds(forHostTime: now - startedHostTime) : 0
        return min(startedFrom + elapsed, duration)
    }

    // MARK: - 內部狀態

    private enum Keys {
        static let mode = "vocalMode"
        static let key = "keyShift"
        static let announce = "announceScore"
        static let carLyrics = "carLyrics"
        static let lyricsOffsets = "lyricsOffsets"
    }

    @ObservationIgnored let scorer = SingingScorer()
    /// 第一次報分時才建立（建立時會載入語音資料，不放在啟動流程裡拖慢開啟速度）
    @ObservationIgnored private var speech: AVSpeechSynthesizer?
    @ObservationIgnored private var scoreBadgeSongID: String?
    /// 用 playNext 插隊、還沒輪到的歌
    @ObservationIgnored private var upNext: Set<String> = []
    @ObservationIgnored private var queueSource: String?
    @ObservationIgnored private var lyricTimer: Timer?
    /// 原唱音高（評分用），也拿來算字幕跑色的速度
    @ObservationIgnored private var reference: (data: [UInt8], fps: Double)?

    /// 播放和評分收音共用的音訊引擎（關掉評分、或卡住接不回來時會換一個新的）
    @ObservationIgnored private var engine = AVAudioEngine()
    /// 麥克風收音有接在引擎上
    @ObservationIgnored private var listening = false
    @ObservationIgnored private let mainNode = AVAudioPlayerNode()
    @ObservationIgnored private let vocalNode = AVAudioPlayerNode()
    @ObservationIgnored private let stemMixer = AVAudioMixerNode()
    @ObservationIgnored private let pitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var mainFile: AVAudioFile?
    @ObservationIgnored private var vocalFile: AVAudioFile?
    @ObservationIgnored private var generation = 0
    /// 暫停在第幾秒（要讓畫面跟著更新：暫停中拖進度條、車機上拉進度）
    private var pausedAt: TimeInterval = 0
    @ObservationIgnored private var startedFrom: TimeInterval = 0
    @ObservationIgnored private var startedHostTime: UInt64 = 0
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// 報分語音專用的播放器（不經過變調器）
    @ObservationIgnored private let voiceNode = AVAudioPlayerNode()
    @ObservationIgnored private var voiceBuffers = 0
    /// 兩軌目前接上的格式；下一首格式一樣就不重接（播放中重接線可能讓聲音消失）
    @ObservationIgnored private var connected: (main: AVAudioFormat, vocal: AVAudioFormat)?
    /// 播放中的健康檢查（每 2 秒一次）
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var lastRendered: AVAudioFramePosition = -1
    @ObservationIgnored private var restarts = 0
    /// 音訊暫時起不來時，過一下再試
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    nonisolated private static let busFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    nonisolated private static let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    init() {
        let defaults = UserDefaults.standard
        mode = VocalMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .karaoke
        keyShift = min(max(defaults.integer(forKey: Keys.key), Self.keyRange.lowerBound), Self.keyRange.upperBound)
        announceScore = defaults.object(forKey: Keys.announce) as? Bool ?? true
        carLyrics = defaults.object(forKey: Keys.carLyrics) as? Bool ?? true  // 給副駕駛唱，預設開

        buildGraph()

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        setupRemoteCommands()
        observeSystemEvents()
    }

    // MARK: - 播放控制

    /// source：從哪個播放清單播的（清單後來做好的歌會自動接在後面）
    func play(_ songs: [Song], startAt i: Int, source: String? = nil) {
        queue = songs
        upNext = []
        queueSource = source
        load(i, autoplay: true)
    }

    /// 正在唱某個播放清單時，清單裡新做好的歌接到最後面
    func appendToQueue(_ song: Song, from source: String) {
        guard queueSource == source, index != nil, !queue.contains(where: { $0.id == song.id }) else { return }
        queue.append(song)
    }

    /// 排到目前這首的下一首播（連續加入好幾首時，依加入的順序排）。沒有在播的話直接播。
    func playNext(_ song: Song) {
        guard let cur = index, queue.indices.contains(cur) else {
            play([song], startAt: 0)
            return
        }
        if queue[cur].id == song.id { return }
        if let old = queue.firstIndex(where: { $0.id == song.id }), old > cur, upNext.contains(song.id) {
            return  // 已經排在待唱清單裡了
        }
        if let old = queue.firstIndex(where: { $0.id == song.id }) {
            queue.remove(at: old)
            if old < cur { index = cur - 1 }
        }
        let now = index ?? cur
        var at = now + 1
        while at < queue.count, upNext.contains(queue[at].id) { at += 1 }
        queue.insert(song, at: at)
        upNext.insert(song.id)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard !isPlaying else { return }
        guard mainFile != nil else {
            if !queue.isEmpty { load(index ?? 0, autoplay: true) }
            return
        }
        startPlayback(from: pausedAt >= duration - 0.5 ? 0 : pausedAt)
    }

    func pause() {
        cancelRetry()
        guard isPlaying else { return }
        pausedAt = currentTime
        stopNodes()
        stopEngine()  // 整個停下（下次播放重新準備），比 pause 穩：iPhone 上 pause 後再開，偶爾會不出聲
        isPlaying = false
        restarts = 0
        stopWatchdog()
        lyricTick()
        updateNowPlaying()
    }

    func stop() {
        cancelRetry()
        stopWatchdog()
        stopNodes()
        scorer.begin(nil)
        currentSongScorable = false
        stopEngine()
        mainFile = nil
        vocalFile = nil
        queue = []
        index = nil
        isPlaying = false
        pausedAt = 0
        duration = 0
        artwork = nil
        nowPlayingArtwork = nil
        lyrics = nil
        reference = nil
        lyricTick()
        updateNowPlaying()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func seek(to time: TimeInterval) {
        let target = min(max(time, 0), max(duration - 0.25, 0))
        if isPlaying {
            stopNodes()
            startPlayback(from: target)
        } else {
            pausedAt = target
            lyricTick()
            updateNowPlaying()
        }
    }

    func next() {
        advance(by: 1)
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
        } else {
            advance(by: -1)
        }
    }

    // MARK: - 歌詞

    /// 歌詞時間調整（正數 = 提早），每首歌分開記
    func adjustLyricsOffset(by delta: TimeInterval) {
        guard let song = current else { return }
        lyricsOffset = min(max((lyricsOffset + delta) * 10, -100), 100).rounded() / 10
        var all = UserDefaults.standard.dictionary(forKey: Keys.lyricsOffsets) as? [String: Double] ?? [:]
        all[song.stableKey] = lyricsOffset == 0 ? nil : lyricsOffset
        UserDefaults.standard.set(all, forKey: Keys.lyricsOffsets)
        lyricTick()
    }

    /// 點一行歌詞 → 音樂回到那一行（暫停中也會開始播）
    func jumpToLyric(_ i: Int) {
        guard let lyrics, lyrics.lines.indices.contains(i), mainFile != nil else { return }
        seek(to: lyrics.jumpStart(to: i, minLead: Self.lyricLead) - lyricsOffset)
        if !isPlaying { resume() }
    }

    /// 歌單重新整理後（例如歌詞剛從 Mac 傳過來、或 Mac 補上了逐字時間），更新目前這首的歌詞
    func refreshSongs(_ songs: [Song]) {
        guard let i = index, queue.indices.contains(i),
              let updated = songs.first(where: { $0.id == queue[i].id }) else { return }
        if updated != queue[i] { queue[i] = updated }
        guard Self.modified(updated.lyricsURL) != lyricsFileDate else { return }
        loadLyrics(for: updated)
        lyricTick()
        updateNowPlaying()
    }

    private static func modified(_ url: URL?) -> Date? {
        url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    }

    /// 字幕現在要顯示的時間（含提早量和使用者調整）
    var lyricClock: TimeInterval { currentTime + lyricsOffset }

    private func loadLyrics(for song: Song) {
        lyricTimer?.invalidate()
        lyricTimer = nil
        lyricIndex = nil
        lyricsFileDate = Self.modified(song.lyricsURL)
        var loaded = song.lyricsURL.flatMap(Lyrics.load)
        if let reference { loaded?.refineEnds(reference: reference.data, fps: reference.fps) }
        lyrics = loaded
        let offsets = UserDefaults.standard.dictionary(forKey: Keys.lyricsOffsets) as? [String: Double]
        lyricsOffset = offsets?[song.stableKey] ?? 0
    }

    /// 更新「正在唱第幾行」，並排好下一行開始時再叫一次（只在換行時動作，幾乎不耗電）
    private func lyricTick() {
        lyricTimer?.invalidate()
        lyricTimer = nil
        guard let lyrics, mainFile != nil else {
            if lyricIndex != nil { lyricIndex = nil }
            return
        }
        let t = lyricClock + Self.lyricLead
        let i = lyrics.index(at: t)
        if i != lyricIndex {
            lyricIndex = i
            if carLyrics { updateNowPlaying() }
        }
        let next = (i ?? -1) + 1
        guard isPlaying, lyrics.lines.indices.contains(next) else { return }
        let timer = Timer(timeInterval: max(lyrics.lines[next].time - t, 0.02), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.lyricTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lyricTimer = timer
    }

    // MARK: - 內部

    private func advance(by delta: Int) {
        guard let index else { return }
        let target = index + delta
        if queue.indices.contains(target) {
            load(target, autoplay: true)
        } else if delta < 0 {
            seek(to: 0)
        } else {  // 播完最後一首
            stopNodes()
            stopWatchdog()
            if finishScore() { scoreBadgeSongID = nil }
            if voiceBuffers == 0 { stopEngine() }  // 還在報分數的話，報完再停（voiceDidFinish）
            isPlaying = false
            pausedAt = 0
            lyricTick()
            updateNowPlaying()
        }
    }

    private func load(_ i: Int, autoplay: Bool) {
        guard queue.indices.contains(i) else { return }
        cancelRetry()
        stopNodes()
        restarts = 0
        let song = queue[i]
        scoreBadgeSongID = finishScore() ? song.id : nil  // 車機上顯示「上一首 xx 分」
        index = i
        upNext.remove(song.id)
        artwork = nil
        nowPlayingArtwork = nil
        reference = nil
        loadLyrics(for: song)
        do {
            let main = try AVAudioFile(forReading: song.mainURL)
            let vocals = song.canSwitchVocals ? song.vocalsURL.flatMap { try? AVAudioFile(forReading: $0) } : nil
            mainFile = main
            vocalFile = vocals
            duration = Double(main.length) / main.processingFormat.sampleRate
            connectStems()
            mainNode.volume = 1
            vocalNode.volume = mode.vocalVolume
            pausedAt = 0
            beginScore(for: song)
            if autoplay {
                startPlayback(from: 0)
            } else {
                isPlaying = false
                updateNowPlaying()
            }
            loadArtwork(for: song)
        } catch {
            mainFile = nil
            vocalFile = nil
            isPlaying = false
            duration = 0
            errorMessage = "無法播放「\(song.title)」，檔案可能已損壞或格式不支援。"
            updateNowPlaying()
        }
    }

    // MARK: - 音訊引擎
    //
    // 只用一個引擎：播放、報分語音、評分收音都在這裡。
    // 以前評分另外開一個收音引擎，iPhone 上播放的引擎停下再開（暫停後播放、換歌、點歌詞）就可能不出聲。

    /// 把播放器接到引擎上：兩軌 → 變調器 → 混音器；報分語音直接進混音器
    private func buildGraph() {
        for node: AVAudioNode in [mainNode, vocalNode, stemMixer, pitch, voiceNode] {
            engine.attach(node)
        }
        engine.connect(stemMixer, to: pitch, format: Self.busFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: Self.busFormat)
        engine.connect(voiceNode, to: engine.mainMixerNode, format: Self.voiceFormat)
        connected = nil
        applyPitch()
    }

    /// 換一個全新的引擎（關掉評分要把麥克風拿掉；或舊引擎卡住接不回來）
    private func rebuildEngine() {
        stopEngine()
        for node: AVAudioNode in [mainNode, vocalNode, stemMixer, pitch, voiceNode] {
            engine.detach(node)
        }
        engine = AVAudioEngine()
        voiceBuffers = 0  // 舊引擎上排好的報分語音不會播了
        buildGraph()
        connectStems()
    }

    /// 兩軌接到混音器；格式跟上次一樣就不重接（播放中改接線可能讓聲音消失）
    private func connectStems() {
        guard let main = mainFile else { return }
        let mainFormat = main.processingFormat
        let vocalFormat = vocalFile?.processingFormat ?? mainFormat
        guard connected?.main != mainFormat || connected?.vocal != vocalFormat else { return }
        stopEngine()  // 先讓引擎停下，startPlayback 會再啟動
        engine.connect(mainNode, to: stemMixer, fromBus: 0, toBus: 0, format: mainFormat)
        engine.connect(vocalNode, to: stemMixer, fromBus: 0, toBus: 1, format: vocalFormat)
        connected = (mainFormat, vocalFormat)
    }

    /// 啟動音訊引擎（已經在跑就不動）；失敗回傳 false
    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        try? AVAudioSession.sharedInstance().setActive(true)
        configureInput()
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            lastEngineError = error.localizedDescription
            stopListening()
            return false
        }
    }

    /// 停下引擎（麥克風也一起停）
    private func stopEngine() {
        stopListening()
        engine.stop()
    }

    /// 評分開著時接上麥克風。只在引擎停著時呼叫，每次都用麥克風現在的格式
    /// （接上車機、藍牙、換麥克風後格式會變，用舊格式啟動會失敗）。
    private func configureInput() {
        stopListening()
        guard scoringEnabled, AVAudioSession.sharedInstance().category == .playAndRecord else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        listening = scorer.listen(to: input, format: format)
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        scorer.stopListening(to: engine.inputNode)
    }

    /// 引擎整個停下再開，從同一個位置接著播（換評分設定、聲音卡住時）。
    /// rebuild：換一個新引擎；whileStopped：引擎停著時要做的事（例如改音訊類別）
    private func restartAudio(from time: TimeInterval? = nil, rebuild: Bool = false,
                              whileStopped: () -> Void = {}) {
        let wasPlaying = isPlaying || retryTask != nil
        let position = time ?? (isPlaying ? currentTime : pausedAt)
        cancelRetry()
        stopNodes()
        isPlaying = false
        pausedAt = position
        if rebuild { rebuildEngine() } else { stopEngine() }
        whileStopped()
        if wasPlaying {
            startPlayback(from: position)
        } else {
            stopWatchdog()
            updateNowPlaying()
        }
    }

    @ObservationIgnored private var lastEngineError = ""

    private func startPlayback(from time: TimeInterval, attempt: Int = 0) {
        guard let main = mainFile else { return }
        cancelRetry()
        connectStems()  // 換過引擎的話要重接
        guard startEngine() else {
            retryPlayback(from: time, attempt: attempt)
            return
        }
        generation += 1
        let gen = generation
        let startFrame = Self.frame(at: time, in: main)
        guard startFrame < main.length else {
            isPlaying = true
            advance(by: 1)
            return
        }
        mainNode.scheduleSegment(main, startingFrame: startFrame,
                                 frameCount: AVAudioFrameCount(main.length - startFrame), at: nil,
                                 completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.segmentDidFinish(gen) }
        }
        // 兩軌在同一個時間點開始，確保人聲和伴奏對齊
        let hostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        guard start(mainNode, at: AVAudioTime(hostTime: hostTime)) else {
            // 引擎說在跑、聲音其實送不出去（以前這裡會閃退）：換一個新引擎，等一下再試
            stopNodes()
            rebuildEngine()
            retryPlayback(from: time, attempt: attempt)
            return
        }
        startedFrom = time
        startedHostTime = hostTime
        isPlaying = true
        lastRendered = -1
        startWatchdog()
        syncScorerTiming()
        if let vocals = vocalFile, mode != .karaoke {
            startVocals(vocals, at: hostTime)
        }
        lyricTick()
        updateNowPlaying()
    }

    /// 音訊設定正在變（剛接上車機或藍牙、別的 app 剛放掉聲音、引擎卡住）：等一下再試，試幾次都不行才告訴使用者
    private func retryPlayback(from time: TimeInterval, attempt: Int) {
        stopNodes()
        isPlaying = false
        pausedAt = time
        stopWatchdog()
        if attempt < 4 {
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.startPlayback(from: self.pausedAt, attempt: attempt + 1)
            }
        } else {
            errorMessage = "無法啟動音訊：\(lastEngineError)\n請再按一次播放。"
        }
        lyricTick()
        updateNowPlaying()
    }

    /// 叫播放器開始播；引擎狀態不對時回傳 false，不會閃退
    private func start(_ node: AVAudioPlayerNode, at time: AVAudioTime? = nil) -> Bool {
        do {
            try node.safePlay(at: time)
            return true
        } catch {
            lastEngineError = "音訊引擎沒有回應"
            return false
        }
    }

    /// 在 hostTime 那一刻，從伴奏對應的位置開始播人聲
    private func startVocals(_ vocals: AVAudioFile, at hostTime: UInt64) {
        let position = startedFrom + (hostTime > startedHostTime
            ? AVAudioTime.seconds(forHostTime: hostTime - startedHostTime) : 0)
        let frame = Self.frame(at: position, in: vocals)
        guard frame < vocals.length else { return }
        vocalNode.scheduleSegment(vocals, startingFrame: frame,
                                  frameCount: AVAudioFrameCount(vocals.length - frame), at: nil)
        if !start(vocalNode, at: AVAudioTime(hostTime: max(hostTime, startedHostTime))) {
            _ = start(vocalNode)  // 對不準時間就先直接播，至少聽得到人聲
        }
    }

    /// 切換模式：伴唱 → 停掉人聲軌（省運算）；導唱／原唱 → 對齊目前位置接上人聲
    private func syncVocals() {
        vocalNode.volume = mode.vocalVolume
        guard isPlaying, let vocals = vocalFile else { return }
        if mode == .karaoke {
            vocalNode.stop()
        } else if !vocalNode.isPlaying {
            startVocals(vocals, at: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        }
    }

    private func segmentDidFinish(_ gen: Int) {
        guard gen == generation, isPlaying else { return }
        // 引擎被系統停掉時，播放器也會回報「播完」：還沒播到尾就不換歌，交給 handleConfigurationChange／健康檢查接回來
        guard currentTime >= duration - 1.5 else { return }
        advance(by: 1)
    }

    /// 播放器實際送出去的聲音播到第幾格（引擎沒在跑就是 nil）
    private var renderedFrames: AVAudioFramePosition? {
        guard engine.isRunning, mainNode.isPlaying, let now = mainNode.lastRenderTime, now.isSampleTimeValid,
              let t = mainNode.playerTime(forNodeTime: now) else { return nil }
        return t.sampleTime
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// 播放中每 2 秒看一次（只讀兩個數字，幾乎不耗電）：
    /// 聲音沒在走（引擎被系統停掉、播放器卡住）就從目前位置接回來；播到尾卻沒收到「播完」就換下一首
    private func checkHealth() {
        guard isPlaying, let main = mainFile else {
            stopWatchdog()
            return
        }
        guard currentTime - startedFrom > 1 else { return }  // 剛開始播，還沒出聲
        let rendered = renderedFrames
        let previous = lastRendered
        lastRendered = rendered ?? -1
        let rate = main.processingFormat.sampleRate
        if let rendered, startedFrom + Double(rendered) / rate >= duration + 1 {
            advance(by: 1)
            return
        }
        if let rendered, rendered > max(previous, 0) {
            restarts = 0
            return
        }
        if currentTime >= duration - 0.5 {
            advance(by: 1)
            return
        }
        restarts += 1
        guard restarts <= 3 else {
            pause()
            errorMessage = "聲音一直中斷，已經先暫停。請再按一次播放。"
            return
        }
        let position = min(max(previous >= 0 ? startedFrom + Double(previous) / rate : currentTime, 0),
                           max(duration - 0.25, 0))
        // 一次比一次徹底：重新播放 → 引擎停下重開 → 換一個新引擎
        switch restarts {
        case 1:
            stopNodes()
            startPlayback(from: position)
        case 2:
            restartAudio(from: position)
        default:
            restartAudio(from: position, rebuild: true)
        }
    }

    private func stopNodes() {
        generation += 1  // 讓 stop() 觸發的完成回呼失效
        mainNode.stop()
        vocalNode.stop()
        scorer.updateTiming(playing: false, startedFrom: startedFrom, startedHostTime: startedHostTime,
                            keyShift: keyShift)
    }

    private func applyPitch() {
        pitch.pitch = Float(keyShift * 100)
        pitch.bypass = keyShift == 0
    }

    nonisolated private static func frame(at time: TimeInterval, in file: AVAudioFile) -> AVAudioFramePosition {
        min(max(AVAudioFramePosition(time * file.processingFormat.sampleRate), 0), file.length)
    }

    private func loadArtwork(for song: Song) {
        let id = song.id
        Task {
            let image = await ArtworkCache.shared.image(for: song.mainURL)
            guard current?.id == id else { return }
            artwork = image
            nowPlayingArtwork = image.map(Self.makeArtwork)
            updateNowPlaying()
        }
    }

    // MARK: - 車機「正在播放」與方向盤按鍵

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let song = current, mainFile != nil else {
            center.nowPlayingInfo = nil
            return
        }
        var title = song.title
        var artist = song.artist
        var subtitle = ["車上K歌", song.canSwitchVocals ? mode.label : (song.isBackingTrack ? "伴唱" : "原曲")]
        if carLyrics, let lyrics {
            // 車機上的 KTV 字幕：大字 = 正在唱的這一行，下面 = 下一行，最下面 = 歌名
            let line = lyricIndex.map { lyrics.lines[$0].text } ?? ""
            title = line.isEmpty ? song.title : line
            artist = lyrics.nextSung(after: lyricIndex).map { lyrics.lines[$0].text } ?? song.artist
            subtitle[0] = [song.title, song.artist].compactMap { $0 }.joined(separator: " - ")
        }
        if keyShift != 0 { subtitle.append("Key \(keyShift > 0 ? "+" : "")\(keyShift)") }
        if let lastScore, scoreBadgeSongID == song.id { subtitle.append("上一首 \(lastScore.score) 分") }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: subtitle.joined(separator: " · "),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        center.nowPlayingInfo = info
    }

    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
        for command in [center.skipForwardCommand, center.skipBackwardCommand, center.seekForwardCommand,
                        center.seekBackwardCommand, center.changePlaybackRateCommand, center.changeRepeatModeCommand,
                        center.changeShuffleModeCommand, center.likeCommand, center.dislikeCommand,
                        center.bookmarkCommand, center.ratingCommand] {
            command.isEnabled = false
        }
    }

    private func observeSystemEvents() {
        let nc = NotificationCenter.default
        // 來電、Siri、導航語音打斷
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                        queue: .main) { @Sendable [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor in self?.handleInterruption(began: began, shouldResume: shouldResume) }
        })
        // 拔掉耳機、斷開 CarPlay → 暫停
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                        queue: .main) { @Sendable [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let deviceGone = raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            Task { @MainActor in self?.handleRouteChange(deviceGone: deviceGone) }
        })
        // 接上 CarPlay 時取樣率可能改變，引擎會自己停掉，要重新接上。
        // 引擎可能換過（關掉評分、卡住重建），所以不綁定某一個引擎，收到時再比對是不是現在這個
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil,
                                        queue: .main) { @Sendable [weak self] note in
            guard let source = note.object as AnyObject? else { return }
            let id = ObjectIdentifier(source)
            Task { @MainActor in
                guard let self, id == ObjectIdentifier(self.engine) else { return }
                self.handleConfigurationChange()
            }
        })
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            if isPlaying {
                resumeAfterInterruption = true
                pause()
            }
        } else {
            if resumeAfterInterruption && shouldResume { resume() }
            resumeAfterInterruption = false
        }
    }

    private func handleRouteChange(deviceGone: Bool) {
        if deviceGone { pause() }
        // 麥克風換了（接上車機、插上 USB 麥克風）：格式有變的話系統會通知引擎設定改變，
        // handleConfigurationChange 重開引擎時就會用新麥克風收音
        if scoringEnabled { refreshInputs() }
    }

    private func handleConfigurationChange() {
        restartAudio { [engine] in
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            if hardware.sampleRate > 0, hardware.channelCount > 0,
               let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                          channels: hardware.channelCount) {
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
            }
        }
    }
}

/// 報分語音：把語音合成出來的聲音轉成播放器引擎的格式，排進語音播放器。
/// 在語音合成的執行緒上呼叫（一次只會有一個執行緒用它）。
private final class VoiceFeed: @unchecked Sendable {
    private let node: AVAudioPlayerNode
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(node: AVAudioPlayerNode, format: AVAudioFormat) {
        self.node = node
        self.format = format
    }

    /// 轉好並排進去就回傳 true（沒有聲音、或轉換失敗回傳 false）；播完會呼叫 done
    func schedule(_ input: AVAudioPCMBuffer, done: @escaping @Sendable () -> Void) -> Bool {
        guard input.frameLength > 0 else { return false }
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { return false }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return false }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return false }
        node.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { _ in done() }
        return true
    }
}

extension AVAudioPlayerNode {
    /// 開始播放，引擎狀態不對時丟出 Swift 接得到的錯誤，而不是讓 App 閃退。
    /// AVAudioPlayerNode 遇到這種情況會丟出 Objective-C 例外（Swift 的 do/catch 接不到），例如：
    /// 引擎說在跑、聲音其實卡住時指定時間開始播（player did not see an IO cycle）、引擎沒在跑就開始播。
    func safePlay(at time: AVAudioTime? = nil) throws {
        try ObjCException.run { self.play(at: time) }
    }
}
