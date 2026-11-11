import Foundation
import Testing
@testable import CarKaraoke

// 第二層之二：模組。先列出「正常運作」需要的條件，再一個一個破壞。
// 正常運作：音檔讀得出來、長度夠、去人聲成功、歌詞查得到、存得下來、歌曲庫裡還沒有這首。

@Suite("模組：一首歌的轉換流程", .serialized)
struct PipelineModuleTests {
    // 20 秒的合成歌有 10 句；去人聲用「完美分離」的替身，逐字時間才有真的人聲可以對
    static let lrc = syntheticLRC(lines: 10)
    static let perfect = FakeSeparator(knownVocals: TestAudio.song(seconds: 20).vocals)

    func pipeline(separator: any VocalSeparating = PipelineModuleTests.perfect, lyricsFailing: Bool = false,
                  lyrics: [LyricsCandidate]? = nil) -> SongPipeline {
        let candidates = lyrics ?? [LyricsCandidate(id: 1, duration: 20, syncedLyrics: Self.lrc)]
        return SongPipeline(separator: separator,
                            lyrics: LyricsFinder(source: StaticLyricsSource(fallback: candidates, failing: lyricsFailing)))
    }

    func plainSong(in folder: URL, name: String = "晴天 - 周杰倫.m4a", seconds: Double = 20,
                   title: String? = nil, artist: String? = nil) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        try await TestAudio.writePlainFile(TestAudio.song(seconds: seconds).mix, to: url, title: title, artist: artist)
        return url
    }

    func convert(_ p: SongPipeline, _ src: URL, _ folder: URL,
                 checkpoint: @escaping @Sendable () async throws -> Void = {}) async throws -> SongPipeline.Outcome {
        try await p.convert(src, in: folder, progress: { _, _ in }, checkpoint: checkpoint)
    }

    @Test("全部正常：產生伴唱、人聲、歌詞，刪掉原檔；歌曲庫看到一首可切原唱、有歌詞的歌")
    @MainActor func happyPath() async throws {
        let folder = try makeTempFolder()
        let src = try await plainSong(in: folder)
        let outcome = try await convert(pipeline(), src, folder)
        #expect(outcome == .converted(base: "晴天 - 周杰倫", hasLyrics: true))
        #expect(!FileManager.default.fileExists(atPath: src.path))
        let songs = Library.scan(folder)
        #expect(songs.count == 1)
        let song = try #require(songs.first)
        #expect(song.isBackingTrack && song.canSwitchVocals && song.lyricsURL != nil)
        #expect(song.title == "晴天" && song.artist == "周杰倫")
        // 評分用音高：App 原本的讀取器讀得到
        let ref = try #require(await ReferencePitch.load(song.mainURL))
        #expect(ref.fps == 20 && ref.data.contains { $0 > 0 })
        // 歌詞：App 原本的讀取器讀得到，而且有逐字時間
        let lyrics = try #require(Lyrics.load(song.lyricsURL!))
        #expect(lyrics.lines.count == 10)
        #expect(lyrics.lines.contains { !$0.words.isEmpty })
        // 沒有殘留暫存檔
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.allSatisfy { !$0.contains(".tmp") && !$0.hasPrefix(".raw-") })
    }

    @Test("歌名歌手：優先用音檔標籤，不是檔名")
    func tagsPreferred() async throws {
        let folder = try makeTempFolder()
        let src = try await plainSong(in: folder, name: "track01.m4a", title: "晴天", artist: "周杰倫")
        let outcome = try await convert(pipeline(), src, folder)
        #expect(outcome == .converted(base: "晴天 - 周杰倫", hasLyrics: true))
    }

    @Test("破壞：檔案讀不出來 → 失敗「讀不出聲音」，原檔保留")
    func unreadable() async throws {
        let folder = try makeTempFolder()
        let src = folder.appendingPathComponent("壞掉 - 某人.mp3")
        try Data("not audio".utf8).write(to: src)
        await #expect(throws: ConversionError.unreadable) { try await convert(pipeline(), src, folder) }
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test("破壞：不到 1 秒 → 失敗「太短」，原檔保留")
    func tooShort() async throws {
        let folder = try makeTempFolder()
        let src = try await plainSong(in: folder, seconds: 0.5)
        await #expect(throws: ConversionError.tooShort) { try await convert(pipeline(), src, folder) }
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test("破壞：去人聲失敗 → 丟出錯誤，原檔保留，沒有留下半套檔案")
    func separatorFails() async throws {
        let folder = try makeTempFolder()
        let src = try await plainSong(in: folder)
        let p = pipeline(separator: FakeSeparator(failure: ConversionError.modelMissing))
        await #expect(throws: ConversionError.modelMissing) { try await convert(p, src, folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [src.lastPathComponent])
    }

    @Test("破壞：歌詞查不到 → 照樣完成，沒有 .lrc")
    func noLyrics() async throws {
        let folder = try makeTempFolder()
        let src = try await plainSong(in: folder)
        let outcome = try await convert(pipeline(lyrics: []), src, folder)
        #expect(outcome == .converted(base: "晴天 - 周杰倫", hasLyrics: false))
        #expect(Library.scan(folder).first?.lyricsURL == nil)
    }

    @Test("破壞：網路不通 → 照樣完成，沒有 .lrc")
    func networkDown() async throws {
        let folder = try makeTempFolder()
        let src = try await plainSong(in: folder)
        let outcome = try await convert(pipeline(lyricsFailing: true), src, folder)
        #expect(outcome == .converted(base: "晴天 - 周杰倫", hasLyrics: false))
    }

    @Test("破壞：歌曲庫已經有同一首 → 不重做、不覆蓋")
    func alreadyExists() async throws {
        let folder = try makeTempFolder()
        let existing = folder.appendingPathComponent("晴天 - 周杰倫.伴唱.m4a")
        try Data("existing".utf8).write(to: existing)
        let src = try await plainSong(in: folder, name: "晴天 - 周杰倫 (1).m4a", title: "晴天", artist: "周杰倫")
        let outcome = try await convert(pipeline(), src, folder)
        #expect(outcome == .alreadyExists(base: "晴天 - 周杰倫"))
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    }

    @Test("破壞：處理到一半被取消 → 丟出取消，原檔保留，沒有半套檔案")
    func cancelled() async throws {
        let folder = try makeTempFolder()
        let src = try await plainSong(in: folder)
        let counter = ProgressLog()
        await #expect(throws: CancellationError.self) {
            try await convert(pipeline(), src, folder, checkpoint: {
                counter.check()
                if counter.checkpoints > 2 { throw CancellationError() }
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [src.lastPathComponent])
    }

    @Test("破壞：存檔的資料夾不見了 → 失敗，原檔保留")
    func saveFails() async throws {
        let folder = try makeTempFolder()
        let src = try await plainSong(in: folder)
        let missing = folder.appendingPathComponent("不存在的資料夾")
        await #expect(throws: (any Error).self) { try await convert(pipeline(), src, missing) }
        #expect(FileManager.default.fileExists(atPath: src.path))
    }
}

@Suite("模組：排隊和暫停", .serialized)
@MainActor
struct ConverterQueueTests {
    func make(_ folder: URL, delay: Duration = .zero, failure: Error? = nil) -> (SongConverter, Library, UserDefaults) {
        let defaults = UserDefaults(suiteName: "ck-test-\(UUID().uuidString)")!
        let pipeline = SongPipeline(separator: FakeSeparator(delayPerSegment: delay, failure: failure),
                                    lyrics: LyricsFinder(source: StaticLyricsSource()))
        return (SongConverter(pipeline: pipeline, defaults: defaults), Library(folder: folder), defaults)
    }

    func addPlain(_ folder: URL, _ name: String) async throws {
        try await TestAudio.writePlainFile(TestAudio.song(seconds: 3).mix, to: folder.appendingPathComponent(name))
    }

    @Test("第一次啟用時，原本就在的一般音檔不自動處理；之後新加的自動處理")
    func baseline() async throws {
        let folder = try makeTempFolder()
        try await addPlain(folder, "舊歌 - 甲.m4a")
        let (converter, library, _) = make(folder)
        library.reload()
        converter.attach(library: library)
        #expect(converter.jobs.isEmpty)
        try await addPlain(folder, "新歌 - 乙.m4a")
        library.reload()
        converter.scan()
        #expect(converter.jobs.map(\.title) == ["新歌"])
        #expect(await waitUntil { library.songs.contains { $0.title == "新歌" && $0.isBackingTrack } })
        #expect(library.songs.contains { $0.title == "舊歌" && !$0.isBackingTrack })
    }

    @Test("長按「手機去人聲」可以處理原本就在的歌")
    func manualEnqueue() async throws {
        let folder = try makeTempFolder()
        try await addPlain(folder, "舊歌 - 甲.m4a")
        let (converter, library, _) = make(folder)
        converter.attach(library: library)
        let song = try #require(library.songs.first)
        converter.enqueue(song)
        #expect(converter.isQueued(song))
        #expect(await waitUntil { library.songs.first?.isBackingTrack == true })
    }

    @Test("一次匯入多首：照順序一首一首做")
    func oneAtATime() async throws {
        let folder = try makeTempFolder()
        let (converter, library, _) = make(folder, delay: .milliseconds(150))
        converter.attach(library: library)
        try await addPlain(folder, "第一首 - 甲.m4a")
        try await Task.sleep(for: .milliseconds(20))
        try await addPlain(folder, "第二首 - 乙.m4a")
        library.reload()
        converter.scan()
        #expect(converter.jobs.map(\.title) == ["第一首", "第二首"])
        var sawBothWorking = false
        let finished = await waitUntil {
            let working = converter.jobs.filter { if case .working = $0.stage { return true } else { return false } }
            if working.count > 1 { sawBothWorking = true }
            return library.songs.filter(\.isBackingTrack).count == 2
        }
        #expect(finished)
        #expect(!sawBothWorking)
    }

    @Test("手機太熱：暫停，不往下做；降溫後自動繼續")
    func pauseWhenHot() async throws {
        let folder = try makeTempFolder()
        let (converter, library, _) = make(folder, delay: .milliseconds(100))
        converter.attach(library: library)
        converter.setPaused(.hot, true)
        try await addPlain(folder, "熱 - 甲.m4a")
        library.reload()
        converter.scan()
        try await Task.sleep(for: .seconds(1.5))
        #expect(!library.songs.contains { $0.isBackingTrack })
        #expect(converter.isPaused)
        converter.setPaused(.hot, false)
        #expect(await waitUntil { library.songs.contains { $0.isBackingTrack } })
    }

    @Test("離開 App、接著 CarPlay 也會暫停")
    func otherPauses() {
        let (converter, _, _) = make(FileManager.default.temporaryDirectory)
        converter.setActive(false)
        #expect(converter.pauseReasons == [.background])
        converter.setPaused(.carPlay, true)
        converter.setActive(true)
        #expect(converter.pauseReasons == [.carPlay])
    }

    @Test("失敗：顯示原因、原檔保留、之後不自動重做；按重試會再做")
    func failureAndRetry() async throws {
        let folder = try makeTempFolder()
        let (converter, library, defaults) = make(folder, failure: ConversionError.modelMissing)
        converter.attach(library: library)
        try await addPlain(folder, "壞 - 甲.m4a")
        library.reload()
        converter.scan()
        #expect(await waitUntil { converter.jobs.first.map { if case .failed = $0.stage { true } else { false } } ?? false })
        #expect(library.songs.first?.isBackingTrack == false)
        #expect(defaults.stringArray(forKey: "onDevice.skippedPlainFiles")?.contains("壞 - 甲.m4a") == true)
        // 重新掃描不會再排一次
        let id = try #require(converter.jobs.first?.id)
        converter.dismiss(id)
        converter.scan()
        #expect(converter.jobs.isEmpty)
    }

    @Test("同一首重複匯入：不重做，刪掉重複的那份")
    func duplicateImport() async throws {
        let folder = try makeTempFolder()
        let (converter, library, _) = make(folder)
        converter.attach(library: library)
        try await addPlain(folder, "晴天 - 周杰倫.m4a")
        library.reload()
        converter.scan()
        #expect(await waitUntil { library.songs.first?.isBackingTrack == true })
        try await TestAudio.writePlainFile(TestAudio.song(seconds: 3).mix, to: folder.appendingPathComponent("copy.m4a"),
                                           title: "晴天", artist: "周杰倫")
        library.reload()
        converter.scan()
        #expect(await waitUntil { library.songs.count == 1 && converter.jobs.allSatisfy { if case .done = $0.stage { true } else { false } } })
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("copy.m4a").path))
    }
}

// 第三層：系統。真的模型 + 真的檔案 + App 原本的歌曲庫、評分音高、歌詞讀取器接起來還對不對。

@Suite("系統：匯入一首歌到可以唱", .serialized)
@MainActor
struct SystemTests {
    @Test("真的模型：匯入 → 自動去人聲 → 歌曲庫出現可切原唱、有評分音高、有逐字歌詞的歌；伴唱 + 人聲 ≈ 原曲")
    func endToEnd() async throws {
        let folder = try makeTempFolder()
        let defaults = UserDefaults(suiteName: "ck-system-\(UUID().uuidString)")!
        let lyrics = LyricsFinder(source: StaticLyricsSource(fallback: [
            LyricsCandidate(id: 7, duration: 20, syncedLyrics: syntheticLRC(lines: 10)),
        ]))
        let converter = SongConverter(pipeline: SongPipeline(separator: DemucsSeparator(), lyrics: lyrics), defaults: defaults)
        let library = Library(folder: folder)
        converter.attach(library: library)

        let original = TestAudio.song(seconds: 20).mix
        try await TestAudio.writePlainFile(original, to: folder.appendingPathComponent("合成 - 測試.m4a"))
        library.reload()
        converter.scan()
        #expect(await waitUntil(timeout: 300) { library.songs.first?.isBackingTrack == true })

        let song = try #require(library.songs.first)
        #expect(song.canSwitchVocals && song.lyricsURL != nil)
        #expect(await ReferencePitch.load(song.mainURL) != nil)
        #expect(Lyrics.load(song.lyricsURL!)?.lines.contains { !$0.words.isEmpty } == true)

        let inst = try AudioDecoder.decode(song.mainURL), voc = try AudioDecoder.decode(song.vocalsURL!)
        let n = min(inst.frameCount, voc.frameCount, original.frameCount)
        let sum = (0..<n).map { inst.left[$0] + voc.left[$0] }
        // 兩個檔各自經過 AAC 壓縮，加回來和原曲差一點點
        #expect(TestAudio.sdr(sum, Array(original.left.prefix(n))) > 15)
        if case .done(let msg) = converter.jobs.first?.stage { #expect(msg.contains("歌詞")) }
    }
}
