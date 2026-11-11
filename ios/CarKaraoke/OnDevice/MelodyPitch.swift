import Accelerate
import Foundation

/// 從人聲軌抓原唱旋律（評分用）：Mac 轉換工具 karaoke.py melody_pitch 的 Swift 版。
/// YIN 演算法（傳統訊號處理），每 50 ms 一點，1 byte：(MIDI - 24) * 4，0 = 沒有唱。
/// 參數和 App 的 PitchDetector 一樣，評分時才比得起來。
enum MelodyPitch {
    static let fps = Int(PitchDetector.sampleRate) / PitchDetector.hop  // 20

    /// mono16k：16 kHz 單聲道人聲
    static func extract(_ mono16k: [Float]) -> [UInt8] {
        let W = PitchDetector.window, hop = PitchDetector.hop
        let tauMin = PitchDetector.tauMin, tauMax = PitchDetector.tauMax
        let span = W + tauMax
        guard mono16k.count >= span else { return [] }
        let count = 1 + (mono16k.count - span) / hop

        var rmsDB = [Double](repeating: 0, count: count)
        var cmnd = [[Float]](repeating: [], count: count)
        mono16k.withUnsafeBufferPointer { x in
            var diff = [Float](repeating: 0, count: tauMax + 1)
            for i in 0..<count {
                let frame = x.baseAddress! + i * hop
                var ms: Float = 0
                vDSP_measqv(frame, 1, &ms, vDSP_Length(W))
                rmsDB[i] = 10 * log10(Double(ms) + 1e-12)
                var c = [Float](repeating: 1, count: tauMax + 1)
                var running = 0.0
                for tau in 1...tauMax {
                    var d: Float = 0
                    vDSP_distancesq(frame, 1, frame + tau, 1, &d, vDSP_Length(W))
                    diff[tau] = d
                    running += Double(d)
                    c[tau] = Float(Double(d) * Double(tau) / max(running, 1e-12))
                }
                cmnd[i] = c
            }
        }
        let gate = max(-50.0, SignalMath.percentile(rmsDB, 95) - 30.0)

        var midi = [Double](repeating: 0, count: count)
        for i in 0..<count where rmsDB[i] >= gate {
            let dp = cmnd[i]
            var t = -1
            if let first = (tauMin..<tauMax).first(where: { dp[$0] < 0.15 }) {
                t = first
                while t + 1 < tauMax && dp[t + 1] < dp[t] { t += 1 }
            } else {
                var best = tauMin
                for tau in tauMin..<tauMax where dp[tau] < dp[best] { best = tau }
                if dp[best] > 0.25 { continue }
                t = best
            }
            let a = Double(dp[t - 1]), b = Double(dp[t]), c = Double(dp[t + 1])
            let den = a - 2 * b + c
            let shift = abs(den) > 1e-12 ? 0.5 * (a - c) / den : 0
            let f0 = PitchDetector.sampleRate / (Double(t) + min(1, max(-1, shift)))
            midi[i] = 69 + 12 * log2(f0 / 440)
        }

        // 去雜訊：前後各 2 點的中位數平滑，刪掉短於 150 ms（3 點）的片段
        var out = midi
        for i in 0..<count where midi[i] > 0 {
            let win = midi[max(0, i - 2)..<min(count, i + 3)].filter { $0 > 0 }.sorted()
            let m = win.count
            out[i] = m % 2 == 1 ? win[m / 2] : 0.5 * (win[m / 2 - 1] + win[m / 2])
        }
        var i = 0
        while i < count {
            guard out[i] > 0 else { i += 1; continue }
            var j = i
            while j < count && out[j] > 0 { j += 1 }
            if j - i < 3 { for k in i..<j { out[k] = 0 } }
            i = j
        }
        return out.map { v in
            v > 0 ? UInt8(min(255, max(1, SignalMath.roundHalfEven((v - 24) * 4)))) : 0
        }
    }

    /// 伴唱檔 description 標籤的內容，ReferencePitch.load 讀它
    static func tag(_ pitch: [UInt8]) -> String {
        "CKP1:\(fps):" + Data(pitch).base64EncodedString()
    }

    /// 每 50 ms 有沒有在唱（歌詞對齊用）
    static func voiced(_ pitch: [UInt8]) -> [Bool] { pitch.map { $0 > 0 } }
}
