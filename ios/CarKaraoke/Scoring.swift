import Accelerate
import AVFoundation
import Foundation

// 唱歌評分：麥克風音高 vs 原唱旋律（Mac 轉換時從人聲軌抓出、存在伴唱檔裡）
// 全部是傳統訊號處理（YIN 音高偵測），不用 AI、不連網。

/// YIN 音高偵測。參數必須和 Mac 端 karaoke.py 的 melody_pitch 一致。
struct PitchDetector {
    static let sampleRate = 16_000.0
    static let hop = 800  // 50 ms → 每秒 20 點
    static let window = 512
    static let tauMin = 16  // 1000 Hz
    static let tauMax = 229  // 70 Hz
    static let span = window + tauMax

    private var diff = [Float](repeating: 0, count: tauMax + 1)
    private var cmnd = [Float](repeating: 1, count: tauMax + 1)

    /// frame 至少要有 span 個 16 kHz 樣本。回傳 MIDI 音高（沒偵測到 = nil）和音量 dBFS。
    mutating func analyze(_ frame: UnsafePointer<Float>) -> (midi: Float?, db: Float) {
        var meanSquare: Float = 0
        vDSP_measqv(frame, 1, &meanSquare, vDSP_Length(Self.window))
        let db = 10 * log10(meanSquare + 1e-12)
        guard db > -70 else { return (nil, db) }

        var running: Float = 0
        for tau in 1...Self.tauMax {
            var d: Float = 0
            vDSP_distancesq(frame, 1, frame + tau, 1, &d, vDSP_Length(Self.window))
            diff[tau] = d
            running += d
            cmnd[tau] = running > 1e-12 ? d * Float(tau) / running : 1
        }

        var t = -1
        for tau in Self.tauMin..<Self.tauMax where cmnd[tau] < 0.15 {
            t = tau
            while t + 1 < Self.tauMax && cmnd[t + 1] < cmnd[t] { t += 1 }
            break
        }
        if t < 0 {
            var best = Self.tauMin
            for tau in Self.tauMin..<Self.tauMax where cmnd[tau] < cmnd[best] { best = tau }
            guard cmnd[best] <= 0.25 else { return (nil, db) }
            t = best
        }
        let a = cmnd[t - 1], b = cmnd[t], c = cmnd[t + 1]
        let den = a - 2 * b + c
        let shift = abs(den) > 1e-12 ? min(max(0.5 * (a - c) / den, -1), 1) : 0
        let f0 = Float(Self.sampleRate) / (Float(t) + shift)
        return (69 + 12 * log2(f0 / 440), db)
    }

    /// 剛分析的那一格裡，「預期音高」（±0.6 半音、任一八度）的週期有多明顯：越小越明顯，< 0.3 算有唱到。
    /// 有背景音樂時，人聲常常不是最大聲的音高，但仍會在預期位置留下痕跡，所以比「猜最大聲的音高」可靠。
    func strength(at expected: Float) -> Float {
        var best: Float = 9
        for octave: Float in [-12, 0, 12] {
            let tau = Float(Self.sampleRate) / (440 * pow(2, (expected + octave - 69) / 12))
            let lo = max(Self.tauMin, Int((tau * 0.9660).rounded(.down)))  // -0.6 半音
            let hi = min(Self.tauMax - 1, Int((tau * 1.0353).rounded(.up)))  // +0.6 半音
            guard lo <= hi else { continue }
            for t in lo...hi { best = min(best, cmnd[t]) }
        }
        return best
    }
}

/// 任意取樣率 → 16 kHz 單聲道（簡單平均降頻，對人聲音高夠用、很省運算）
struct Downsampler {
    let ratio: Double
    private var phase = 0.0
    private var sum: Float = 0
    private var count = 0
    private var last: Float = 0

    init(inputRate: Double) { ratio = inputRate / PitchDetector.sampleRate }

    mutating func process(_ input: UnsafePointer<Float>, count n: Int, into out: inout [Float]) {
        for i in 0..<n {
            sum += input[i]
            count += 1
            phase += 1
            while phase >= ratio {
                if count > 0 { last = sum / Float(count) }
                out.append(last)
                sum = 0
                count = 0
                phase -= ratio
            }
        }
    }
}

struct ScoreResult: Equatable, Sendable {
    let title: String
    let score: Int
    let accuracy: Double

    var comment: String {
        switch score {
        case 95...: return "完美！"
        case 90..<95: return "太厲害了！"
        case 80..<90: return "唱得很好！"
        case 70..<80: return "不錯喔！"
        default: return "再接再厲！"
        }
    }
}

/// 收集一首歌的麥克風音高，唱完算分。
final class ScoreKeeper: @unchecked Sendable {
    let title: String
    let fps: Double
    private let reference: [UInt8]  // 0 = 沒唱；否則 (MIDI-24)*4
    private let instrumental: [Bool]  // 前後 0.5 秒都沒人聲 → 用來學喇叭漏音的音量
    private let lock = NSLock()
    private var credit: [Float]  // 每個原唱音高點的得分：0、0.5（差 1.5 半音內）、1（差 1 半音內）
    private var heard: [Bool]  // 附近有偵測到歌聲
    private var covered: [Bool]  // 開著評分播過的部分
    private var bleedDB: Float?

    /// 容許的時間誤差：±0.25 秒（搶拍、拖拍；喇叭和麥克風延遲另外扣掉）
    private static let window = 5

    init(title: String, reference: [UInt8], fps: Double) {
        self.title = title
        self.reference = reference
        self.fps = fps
        let n = reference.count
        credit = [Float](repeating: 0, count: n)
        heard = [Bool](repeating: false, count: n)
        covered = [Bool](repeating: false, count: n)
        instrumental = (0..<n).map { i in
            reference[max(0, i - 10)...min(n - 1, i + 10)].allSatisfy { $0 == 0 }
        }
    }

    /// 加入一格麥克風分析結果。position：歌曲第幾秒；keyShift：目前升降 Key（唱的音要跟著升降）
    func add(position: Double, midi: Float?, db: Float, keyShift: Int, detector: PitchDetector) {
        let i = Int((position * fps).rounded())
        lock.lock()
        defer { lock.unlock() }
        guard reference.indices.contains(i) else { return }
        covered[i] = true
        if instrumental[i] {  // 間奏：麥克風收到的是喇叭漏音＋車內噪音
            bleedDB = bleedDB.map { $0 * 0.95 + db * 0.05 } ?? db
        }
        guard db >= max(-50, (bleedDB ?? -60) + 3) else { return }  // 要比漏音大聲才算在唱

        var strengthCache: [UInt8: Float] = [:]
        for j in max(0, i - Self.window)...min(reference.count - 1, i + Self.window) where reference[j] != 0 {
            let expected = Float(reference[j]) / 4 + 24 + Float(keyShift)
            var c: Float = 0
            if let midi {
                let d = midi - expected
                let off = abs(d - 12 * (d / 12).rounded())  // 高八度、低八度都算對
                c = off <= 1 ? 1 : (off <= 1.5 ? 0.5 : 0)
                heard[j] = true
            }
            // 「預期音高在不在」只比對當下 ±0.05 秒的音，否則旋律相鄰的音會被誤算成唱對
            if c < 1 && abs(j - i) <= 1 {
                let s = strengthCache[reference[j]] ?? detector.strength(at: expected)
                strengthCache[reference[j]] = s
                if s < 0.3 {
                    c = 1
                    heard[j] = true
                }
            }
            credit[j] = max(credit[j], c)
        }
    }

    /// 至少唱到 2 秒的人聲段落、而且有開口唱，才給分；否則回傳 nil
    func result() -> ScoreResult? {
        lock.lock()
        defer { lock.unlock() }
        var frames = 0
        var sung = 0
        var hits = 0.0
        for i in reference.indices where covered[i] && reference[i] != 0 {
            frames += 1
            hits += Double(credit[i])
            if heard[i] { sung += 1 }
        }
        guard frames >= 40, Double(sung) / Double(frames) >= 0.2 else { return nil }
        let accuracy = hits / Double(frames)
        return ScoreResult(title: title, score: Int((40 + 60 * pow(accuracy, 0.9)).rounded()), accuracy: accuracy)
    }
}

/// 從伴唱檔讀出原唱音高（Mac 轉換工具寫在 description 標籤：「CKP1:每秒點數:base64」）
enum ReferencePitch {
    static func load(_ url: URL) async -> (data: [UInt8], fps: Double)? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            guard let text = try? await item.load(.stringValue), text.hasPrefix("CKP1:") else { continue }
            let parts = text.split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let fps = Double(parts[1]), fps > 0,
                  let data = Data(base64Encoded: String(parts[2])) else { return nil }
            return ([UInt8](data), fps)
        }
        return nil
    }
}

/// 麥克風收音 → 音高 → ScoreKeeper。
/// 麥克風接在播放器自己的音訊引擎上（同一個引擎同時收音和放音）：
/// 兩個引擎各開各的，在 iPhone 上重新開始播放時，播放的那個可能不出聲。
final class SingingScorer: @unchecked Sendable {
    private let lock = NSLock()
    private var keeper: ScoreKeeper?
    private var playing = false
    private var startedFrom = 0.0
    private var startedHostTime: UInt64 = 0
    private var keyShift = 0
    private var latency = 0.0
    private var downsampler: Downsampler?
    private var samples: [Float] = []
    private var detector = PitchDetector()
    private var level: Float = -100

    /// 麥克風目前音量（dBFS），給畫面上的音量條用
    var levelDB: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    // MARK: 播放器通知

    func begin(_ keeper: ScoreKeeper?) {
        lock.lock(); defer { lock.unlock() }
        self.keeper = keeper
    }

    func finish() -> ScoreResult? {
        lock.lock()
        let k = keeper
        keeper = nil
        lock.unlock()
        return k?.result()
    }

    func updateTiming(playing: Bool, startedFrom: Double, startedHostTime: UInt64, keyShift: Int) {
        lock.lock(); defer { lock.unlock() }
        self.playing = playing
        self.startedFrom = startedFrom
        self.startedHostTime = startedHostTime
        self.keyShift = keyShift
    }

    // MARK: 麥克風

    /// 在播放器引擎的麥克風上開始收音（播放器只在引擎停著時呼叫）；接不上回傳 false。
    /// format 要用麥克風「現在」的格式，否則引擎啟動時會因為格式不合而失敗。
    /// 剛好在接上車機、藍牙的瞬間，麥克風格式會變，系統會丟出 Objective-C 例外，這裡接住（不閃退，這首先不評分）。
    @discardableResult
    func listen(to input: AVAudioInputNode, format: AVAudioFormat) -> Bool {
        let session = AVAudioSession.sharedInstance()
        lock.lock()
        downsampler = Downsampler(inputRate: format.sampleRate)
        samples.removeAll(keepingCapacity: true)
        latency = session.inputLatency + session.outputLatency + session.ioBufferDuration
        lock.unlock()
        let rate = format.sampleRate
        do {
            try ObjCException.run {
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
                    guard let channel = buffer.floatChannelData?[0] else { return }
                    let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
                    self?.feed(channel, count: Int(buffer.frameLength), hostTime: host, sampleRate: rate)
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// 停止收音（音量條歸零）
    func stopListening(to input: AVAudioInputNode) {
        input.removeTap(onBus: 0)
        lock.lock()
        level = -100
        lock.unlock()
    }

    /// 處理一段麥克風聲音（也用於測試）。hostTime = 這段聲音第一個樣本的時間。
    func feed(_ input: UnsafePointer<Float>, count: Int, hostTime: UInt64, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        if downsampler == nil || downsampler?.ratio != sampleRate / PitchDetector.sampleRate {
            downsampler = Downsampler(inputRate: sampleRate)
            samples.removeAll(keepingCapacity: true)
        }
        downsampler!.process(input, count: count, into: &samples)
        // samples 最後一個樣本對應的時間
        let endHost = hostTime + AVAudioTime.hostTime(forSeconds: Double(count) / sampleRate)
        // 分析窗（span）比每步前進的量（hop）短，所以要湊滿 hop 才能分析並往前移
        while samples.count >= max(PitchDetector.span, PitchDetector.hop) {
            let result = samples.withUnsafeBufferPointer { detector.analyze($0.baseAddress!) }
            level = result.db
            // 這個分析窗中心的時間 → 歌曲位置（扣掉喇叭和麥克風延遲）
            let centerOffset = Double(samples.count - PitchDetector.span / 2) / PitchDetector.sampleRate
            let frameHost = endHost - min(endHost, AVAudioTime.hostTime(forSeconds: centerOffset))
            if playing, let keeper, frameHost > startedHostTime {
                let position = startedFrom + AVAudioTime.seconds(forHostTime: frameHost - startedHostTime) - latency
                keeper.add(position: position, midi: result.midi, db: result.db, keyShift: keyShift, detector: detector)
            }
            samples.removeFirst(PitchDetector.hop)
        }
    }

    /// 測試用：手動設定延遲
    func setLatencyForTesting(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        latency = seconds
    }
}

enum ScoringError: LocalizedError {
    case noMicrophone
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "找不到可以用的麥克風。"
        case .permissionDenied: return "沒有麥克風權限。請到「設定 → 車上K歌」打開麥克風。"
        }
    }
}
