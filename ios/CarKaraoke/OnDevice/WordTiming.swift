import Accelerate
import Foundation

/// 逐字歌詞時間（KTV 跑字對上每一個字）：Mac 轉換工具 wordtiming.py 的 Swift 版。
///
/// 做法（傳統訊號處理，不是 AI）：唱到新的字時，聲音通常有「起音」（子音的噪音、音量突然變大、或換音高）。
/// 先算出人聲軌每 10 ms 的起音強度，再在每一行的時間範圍內用動態規劃挑出 N 個位置
/// （N = 這一行的字數；英文是單字數），讓挑到的位置都是明顯的起音、而且每個字的長度不要差太多。
enum WordTiming {
    static let sr = 16_000
    static let fps = 100            // 每 10 ms 一格
    static let hop = sr / fps
    static let nfft = 512
    static let pitchFPS = 20        // 評分用的音高資料每秒 20 點

    static let dMin = 0.07          // 一個字最短 70 ms
    static let dMax = 3.0           // 句子中間的字最長 3 秒（句尾拉長音不限）
    static let lambda = 0.35        // 字長偏離平均的懲罰
    static let mu = 0.6             // 第一個字偏離 LRC 行首時間的懲罰（每 0.25 秒）
    static let silentPenalty = 1.2  // 在沒聲音的地方「開始唱一個字」的懲罰

    struct Result {
        var lines: [LRCLine]
        var timed: Int
        var sung: Int
    }

    // MARK: 切字

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }

    private static let wordRE = try! NSRegularExpression(pattern: "[0-9A-Za-zÀ-ɏ]+(?:['’][A-Za-z]+)*")
    private static let vowelRE = try! NSRegularExpression(pattern: "[aeiouyàâäéèêëîïôöùûü]+")

    static func syllables(_ word: String) -> Int {
        if !word.isEmpty && word.allSatisfy(\.isASCII) && word.allSatisfy(\.isNumber) { return max(1, word.count) }
        let w = word.lowercased()
        var n = vowelRE.numberOfMatches(in: w, range: NSRange(w.startIndex..., in: w))
        if n > 1 && w.hasSuffix("e") && !(w.hasSuffix("le") || w.hasSuffix("ee") || w.hasSuffix("ye")) { n -= 1 }
        return max(1, n)
    }

    /// 一行歌詞 → [(開始, 結束, 權重, 句尾?)]。開始／結束是 Unicode scalar 位置（和 Python 的字元位置一樣）。
    /// 中日韓每個字一個單位；英文每個單字一個單位（權重 = 音節數）。標點和空白併進前一個單位。
    static func units(_ text: String) -> [(start: Int, end: Int, weight: Double, phraseEnd: Bool)] {
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        var spans: [(Int, Int, Double)] = []
        var i = 0
        let utf16Offsets: [Int] = {  // scalar 位置 → NSString 位置
            var out = [Int](), pos = 0
            for s in scalars { out.append(pos); pos += String(s).utf16.count }
            out.append(pos)
            return out
        }()
        let ns = text as NSString
        while i < n {
            if isCJK(scalars[i]) {
                spans.append((i, i + 1, 1))
                i += 1
                continue
            }
            if let m = wordRE.firstMatch(in: text, options: [.anchored],
                                         range: NSRange(location: utf16Offsets[i], length: ns.length - utf16Offsets[i])) {
                let endUTF16 = m.range.location + m.range.length
                let end = utf16Offsets.firstIndex(of: endUTF16) ?? n
                spans.append((i, end, Double(syllables(ns.substring(with: m.range)))))
                i = end
                continue
            }
            i += 1
        }
        guard !spans.isEmpty else { return [] }
        var out: [(Int, Int, Double, Bool)] = []
        for (k, (a, b, w)) in spans.enumerated() {
            let start = k == 0 ? 0 : a
            let end = k + 1 < spans.count ? spans[k + 1].0 : n
            let gap = String(String.UnicodeScalarView(scalars[b..<end]))
            let phraseEnd = k + 1 == spans.count || !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || gap.contains(" ") || gap.contains("　")
            out.append((start, end, w, phraseEnd))
        }
        return out
    }

    static func slice(_ text: String, _ a: Int, _ b: Int) -> String {
        let s = Array(text.unicodeScalars)
        return String(String.UnicodeScalarView(s[a..<b]))
    }

    // MARK: 起音特徵

    /// 人聲軌每 10 ms 的：起音強度（頻譜變化）、音量（dB）、有沒有聲音、音高跳動
    struct Features {
        let n: Int
        let flux: [Double]
        let db: [Double]
        let gate: Double
        let voiced: [Bool]
        let rise: [Double]
        let pjump: [Double]

        init(mono16k: [Float], pitch: [UInt8]?) {
            let half = nfft / 2
            var x = [Float](repeating: 0, count: half + mono16k.count + nfft)
            x.replaceSubrange(half..<(half + mono16k.count), with: mono16k)
            let n = max(0, (x.count - nfft) / hop)
            self.n = n
            let lo = 3, hi = 193  // 約 94 Hz～6 kHz
            let bands = hi - lo
            // np.hanning：對稱的 Hann 窗
            let win = (0..<nfft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nfft - 1))) }
            var logmag = [Float](repeating: 0, count: n * bands)
            var db = [Double](repeating: 0, count: n)
            let log2n = vDSP_Length(log2(Double(nfft)))
            let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            defer { vDSP_destroy_fftsetup(setup) }
            var frame = [Float](repeating: 0, count: nfft)
            var re = [Float](repeating: 0, count: nfft / 2), im = [Float](repeating: 0, count: nfft / 2)
            x.withUnsafeBufferPointer { xp in
                for f in 0..<n {
                    let p = xp.baseAddress! + f * hop
                    var ms: Float = 0
                    vDSP_measqv(p, 1, &ms, vDSP_Length(nfft))
                    db[f] = 10 * log10(Double(ms) + 1e-10)
                    vDSP_vmul(p, 1, win, 1, &frame, 1, vDSP_Length(nfft))
                    re.withUnsafeMutableBufferPointer { rp in
                        im.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            frame.withUnsafeBufferPointer { fp in
                                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nfft / 2) {
                                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(nfft / 2))
                                }
                            }
                            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        }
                    }
                    // vDSP_fft_zrip 的結果是數學 DFT 的 2 倍
                    for k in lo..<hi {
                        let mag = 0.5 * sqrt(re[k] * re[k] + im[k] * im[k])
                        logmag[f * bands + (k - lo)] = log1p(200 * mag)
                    }
                }
            }
            var flux = [Double](repeating: 0, count: n)
            if n > 2 {
                for f in 2..<n {
                    var pos = 0.0, neg = 0.0
                    for k in 0..<bands {
                        let d = Double(logmag[f * bands + k] - logmag[(f - 2) * bands + k])
                        if d > 0 { pos += d } else { neg -= d }
                    }
                    flux[f] = max(0, pos - 0.5 * min(pos, neg))  // 整體變小聲不算起音
                }
            }
            self.flux = flux
            // 「有在唱」的門檻：比最大聲小 30 dB 以內，而且明顯高過安靜時的雜訊（去人聲殘留）
            let gate = n > 0 ? max(SignalMath.percentile(db, 95) - 30, SignalMath.percentile(db, 10) + 10, -62) : -60
            self.gate = gate
            self.db = db
            self.voiced = db.map { $0 > gate }
            let smooth = SignalMath.convolveSame(db.map { max($0, gate) }, [Double](repeating: 0.2, count: 5))
            var rise = [Double](repeating: 0, count: n)
            if n > 8 { for f in 4..<(n - 4) { rise[f] = max(0, smooth[f + 4] - smooth[f - 4]) } }
            self.rise = rise
            var pjump = [Double](repeating: 0, count: n)
            if let pitch, !pitch.isEmpty, n > 8 {
                let rep = fps / pitchFPS
                var up = [Double](repeating: .nan, count: n)
                for (i, p) in pitch.enumerated() where p > 0 {
                    for r in 0..<rep where i * rep + r < n { up[i * rep + r] = Double(p) / 4 + 24 }
                }
                for f in 4..<(n - 4) {
                    let a = up[f - 4], b = up[f + 4]
                    if !a.isNaN && !b.isNaN { pjump[f] = min(1, max(0, (abs(b - a) - 0.7) / 1.5)) }  // 換了大約一個半音以上
                }
            }
            self.pjump = pjump
        }

        /// a～b 這段每一格「像是一個字開始」的分數
        func score(_ a: Int, _ b: Int) -> [Double] {
            let len = b - a
            guard len > 0 else { return [] }
            let flux = Array(self.flux[a..<b]), rise = Array(self.rise[a..<b])
            let vEnd = min(n, b + 10)
            let voicedSlice = (a < vEnd ? Array(voiced[a..<vEnd]) : []).map { $0 ? 1.0 : 0.0 }
            let fScale = max(SignalMath.percentile(flux, 97), 1e-6)
            let rScale = max(SignalMath.percentile(rise, 97), 3.0)
            // 一個字開始後應該有聲音：看後面 80 ms 有幾成在唱
            var ahead = [Double](repeating: 0, count: len)
            for i in 0..<len {
                var s = 0.0
                for j in i..<min(i + 8, voicedSlice.count) { s += voicedSlice[j] }
                ahead[i] = s / 8
            }
            return (0..<len).map { i in
                min(flux[i] / fScale, 1.5) + 0.8 * min(rise[i] / rScale, 1.5) + 0.7 * pjump[a + i]
                    - silentPenalty * (1 - ahead[i])
            }
        }
    }

    // MARK: 對齊一行

    /// 動態規劃：在 score（每格分數）上挑 weights.count 個開始位置，最後一個字唱到 end 為止。
    static func align(_ score: [Double], weights: [Double], finals: [Bool], t0: Int, end: Int) -> [Int]? {
        let F = score.count, N = weights.count
        let dmin = Int(dMin * Double(fps)), dmax = Int(dMax * Double(fps))
        guard N > 0, end - N * dmin >= 0, F > 0 else { return nil }
        let u = max(Double(end - max(t0, 0)) / weights.reduce(0, +), Double(dmin))
        let NEG = -1e18
        var dp = (0..<F).map { f -> Double in
            f <= end - N * dmin ? score[f] - mu * pow(Double(f - t0) / 25, 2) : NEG
        }
        var backs: [[Int32]] = []
        for i in 1..<max(N, 1) where N > 1 {
            let expD = weights[i - 1] * u
            var best = [Double](repeating: NEG, count: F)
            var arg = [Int32](repeating: 0, count: F)
            let top = finals[i - 1] ? F - 1 : min(dmax, F - 1)
            if dmin <= top {
                for d in dmin...top {
                    let r = log(Double(d) / expD)
                    let pen = (r < 0 || !finals[i - 1]) ? lambda * r * r : lambda * 0.15 * r * r
                    for f in d..<F {
                        let cand = dp[f - d] - pen
                        if cand > best[f] { best[f] = cand; arg[f] = Int32(f - d) }
                    }
                }
            }
            for f in 0..<F { dp[f] = f <= end - (N - i) * dmin ? best[f] + score[f] : NEG }
            backs.append(arg)
        }
        // 最後一個字：唱到 end
        let expD = weights[N - 1] * u
        var s = -1
        var bestTotal = NEG
        for f in 0..<F {
            let lastD = Double(max(end - f, 1))
            let r = log(lastD / expD)
            var total = dp[f] - (r < 0 ? lambda * r * r : lambda * 0.15 * r * r)
            if end - f < dmin { total = NEG }
            if s < 0 || total > bestTotal { bestTotal = total; s = f }
        }
        guard s >= 0, bestTotal > NEG / 2 else { return nil }
        var starts = [s]
        for arg in backs.reversed() {
            s = Int(arg[s])
            starts.append(s)
        }
        return starts.reversed()
    }

    /// 這一行唱完的位置。停頓之後、在下一行時間前後 0.5 秒內才開始的那段聲音，算下一行的。
    static func lineEnd(_ voiced: [Bool], nextStart: Int) -> Int {
        var runs: [(Int, Int)] = []
        var i = 0
        while i < voiced.count {
            guard voiced[i] else { i += 1; continue }
            var j = i
            while j < voiced.count && voiced[j] { j += 1 }
            runs.append((i, j))
            i = j
        }
        while runs.count > 1, runs[runs.count - 1].0 >= nextStart - 50,
              runs[runs.count - 1].0 - runs[runs.count - 2].1 >= 12 {
            runs.removeLast()
        }
        return runs.last?.1 ?? 0
    }

    /// 整行時間 → 加上逐字時間；對不出來的行維持整行。
    static func addWordTimes(_ lines: [LRCLine], mono16k: [Float], pitch: [UInt8]?) -> Result {
        let feat = Features(mono16k: mono16k, pitch: pitch)
        let F = Double(fps)
        var out: [LRCLine] = []
        var bound = 0  // 下一行的第一個字不能早於這裡（上一行最後一個字開始後 0.15 秒）
        var timed = 0
        let sung = lines.filter { !$0.text.isEmpty }.count
        for (k, line) in lines.enumerated() {
            let t = line.time, text = line.text
            let us = text.isEmpty ? [] : units(text)
            guard !us.isEmpty else { out.append(LRCLine(time: t, text: text)); continue }
            let nxt = k + 1 < lines.count ? lines[k + 1].time : t + 12
            let floor = out.last.map { Int($0.time * F) + 1 } ?? 0  // 行的順序不能亂
            let a = max(Int((t - 0.6) * F), bound, floor, 0)
            let b = min(Int((nxt + 0.1) * F), feat.n)
            guard b - a >= us.count * Int(dMin * F) + 5 else { out.append(LRCLine(time: t, text: text)); continue }
            let v = Array(feat.voiced[a..<b])
            guard v.contains(true) else { out.append(LRCLine(time: t, text: text)); continue }
            let t0 = Int(SignalMath.roundHalfEven(t * F)) - a
            let end = lineEnd(v, nextStart: Int(SignalMath.roundHalfEven(nxt * F)) - a)
            let from = max(t0, 0)
            let ratio = end > from ? Double(v[from..<end].filter { $0 }.count) / Double(end - from) : 0
            guard ratio >= 0.3 else { out.append(LRCLine(time: t, text: text)); continue }  // 和聲、口白：不做逐字
            let score = Array(feat.score(a, b).prefix(end))
            guard let starts = align(score, weights: us.map(\.weight), finals: us.map(\.phraseEnd), t0: t0, end: end) else {
                out.append(LRCLine(time: t, text: text))
                continue
            }
            let words = starts.enumerated().map { i, s in
                (time: SignalMath.round2(Double(a + s) / F), text: slice(text, us[i].start, us[i].end))
            }
            out.append(LRCLine(time: SignalMath.round2(min(t, words[0].time)), text: text, words: words,
                               end: SignalMath.round2(Double(a + end) / F)))
            bound = a + starts.last! + Int(0.15 * F)
            timed += 1
        }
        // 連著唱的兩行：上一行唱完的時間 = 下一行第一個字開始
        for k in 0..<max(out.count - 1, 0) {
            guard let words = out[k].words, let end = out[k].end else { continue }
            if let nxt = out[(k + 1)...].first(where: { !$0.text.isEmpty }), let nw = nxt.words, nxt.end != nil,
               nw[0].time < end {
                out[k].end = max(nw[0].time, SignalMath.round2(words.last!.time + dMin))
            }
        }
        return Result(lines: out, timed: timed, sung: sung)
    }
}
