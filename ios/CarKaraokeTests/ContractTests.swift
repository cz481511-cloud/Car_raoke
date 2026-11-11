import Foundation
import Testing
@testable import CarKaraoke

// 第二層之一：契約測試。同一組測試跑過每一個實作；新增實作只要在 arguments 多一行。

/// 去人聲引擎的實作清單
enum SeparatorUnderTest: String, CaseIterable, CustomTestStringConvertible {
    case fake = "假的（測試用）"
    case demucs = "Demucs（真的模型，只用 CPU）"

    var testDescription: String { rawValue }

    func make() -> any VocalSeparating {
        switch self {
        case .fake: return FakeSeparator()
        case .demucs: return DemucsSeparator()
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    private var checks = 0
    func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    func check() { lock.lock(); checks += 1; lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    var checkpoints: Int { lock.lock(); defer { lock.unlock() }; return checks }
}

@Suite("契約：去人聲引擎", .serialized)
struct VocalSeparatorContractTests {
    @Test("輸出長度和輸入一樣、沒有 NaN、伴唱 + 人聲 = 原曲", arguments: SeparatorUnderTest.allCases)
    func lengthsAndSum(_ impl: SeparatorUnderTest) async throws {
        let (mix, _) = TestAudio.song(seconds: 9)
        let stems = try await impl.make().separate(mix, progress: { _ in }, checkpoint: {})
        #expect(stems.vocals.frameCount == mix.frameCount)
        #expect(stems.accompaniment.frameCount == mix.frameCount)
        #expect(!stems.vocals.left.contains { $0.isNaN } && !stems.accompaniment.right.contains { $0.isNaN })
        let sumL = zip(stems.vocals.left, stems.accompaniment.left).map(+)
        #expect(TestAudio.sdr(sumL, mix.left) > 60)
    }

    @Test("進度由小到大、最後是 1；每一段前都會呼叫 checkpoint", arguments: SeparatorUnderTest.allCases)
    func progressAndCheckpoints(_ impl: SeparatorUnderTest) async throws {
        let (mix, _) = TestAudio.song(seconds: 9)
        let log = ProgressLog()
        _ = try await impl.make().separate(mix, progress: { log.add($0) }, checkpoint: { log.check() })
        let p = log.all
        #expect(p.first == 0 && p.last == 1)
        #expect(zip(p, p.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(log.checkpoints >= 1)
        #expect(log.checkpoints == p.count - 1)  // 每一段一次
    }

    @Test("checkpoint 丟出取消 → separate 也丟出取消", arguments: SeparatorUnderTest.allCases)
    func cancellation(_ impl: SeparatorUnderTest) async throws {
        let (mix, _) = TestAudio.song(seconds: 9)
        await #expect(throws: CancellationError.self) {
            _ = try await impl.make().separate(mix, progress: { _ in }, checkpoint: { throw CancellationError() })
        }
    }

    // 去人聲的品質不在這裡測：合成的正弦波不像人聲，模型會（正確地）把它當成樂器。
    // 品質用真的歌在模擬器裡比對 Mac 版的結果（見測試報告的系統測試）。
}

/// 歌詞來源的實作清單
enum LyricsSourceUnderTest: String, CaseIterable, CustomTestStringConvertible {
    case lrclib = "LRCLIB（模擬的網路回應）"
    case fixed = "固定答案（測試用）"

    var testDescription: String { rawValue }

    static let candidate = LyricsCandidate(id: 42, duration: 269.7, syncedLyrics: "[00:01.00]晴天", instrumental: false)

    func make(failing: Bool = false, empty: Bool = false) -> any LyricsSource {
        switch self {
        case .lrclib:
            StubLRCLIBProtocol.handler = { req in
                if failing { return (500, Data()) }
                if empty { return (200, Data("[]".utf8)) }
                let json = #"[{"id":42,"duration":269.7,"syncedLyrics":"[00:01.00]晴天","instrumental":false}]"#
                return (200, Data(json.utf8))
            }
            return LRCLIBSource(session: StubLRCLIBProtocol.session())
        case .fixed:
            return StaticLyricsSource(fallback: empty ? [] : [Self.candidate], failing: failing)
        }
    }
}

@Suite("契約：歌詞來源", .serialized)
struct LyricsSourceContractTests {
    @Test("查得到：原樣回傳候選", arguments: LyricsSourceUnderTest.allCases)
    func found(_ impl: LyricsSourceUnderTest) async throws {
        let result = try await impl.make().search(.track(name: "晴天", artist: "周杰倫"))
        #expect(result == [LyricsSourceUnderTest.candidate])
    }

    @Test("查不到：空陣列", arguments: LyricsSourceUnderTest.allCases)
    func empty(_ impl: LyricsSourceUnderTest) async throws {
        #expect(try await impl.make(empty: true).search(.text("不存在的歌")).isEmpty)
    }

    @Test("網路或伺服器錯誤：丟出錯誤", arguments: LyricsSourceUnderTest.allCases)
    func failure(_ impl: LyricsSourceUnderTest) async {
        await #expect(throws: (any Error).self) { try await impl.make(failing: true).search(.text("晴天")) }
    }

    @Test("LRCLIB 只送歌名和歌手，並帶 App 名稱")
    func lrclibRequest() async throws {
        let box = RequestBox()
        StubLRCLIBProtocol.handler = { req in box.set(req); return (200, Data("[]".utf8)) }
        _ = try await LRCLIBSource(session: StubLRCLIBProtocol.session()).search(.track(name: "晴天", artist: "周杰倫"))
        let req = try #require(box.get())
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(req.url?.host == "lrclib.net")
        #expect(Set(items.map(\.name)) == ["track_name", "artist_name"])
        #expect(req.value(forHTTPHeaderField: "User-Agent") == LRCLIBSource.userAgent)
    }
}

final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var req: URLRequest?
    func set(_ r: URLRequest) { lock.lock(); req = r; lock.unlock() }
    func get() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return req }
}
