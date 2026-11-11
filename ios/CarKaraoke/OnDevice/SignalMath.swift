import Foundation

/// numpy 對應的幾個小工具，讓移植過來的演算法和 Mac 版算出一樣的結果。
enum SignalMath {
    /// np.percentile（線性內插）
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let pos = Double(s.count - 1) * p / 100
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    /// np.convolve(a, ones(width), mode="full")[0..<a.count]：每個位置往前 width 格（含自己）的總和
    static func trailingSum(_ a: [Double], width: Int) -> [Double] {
        var out = [Double](repeating: 0, count: a.count)
        var run = 0.0
        for i in 0..<a.count {
            run += a[i]
            if i >= width { run -= a[i - width] }
            out[i] = run
        }
        return out
    }

    /// np.convolve(a, kernel, mode="same")（長度和 a 一樣，置中）
    static func convolveSame(_ a: [Double], _ kernel: [Double]) -> [Double] {
        let n = a.count, m = kernel.count
        guard n > 0, m > 0 else { return a }
        let length = max(n, m)
        let start = (m - 1) / 2
        var out = [Double](repeating: 0, count: length)
        for k in 0..<length {
            let full = k + start  // full 卷積的位置
            var s = 0.0
            let jLo = max(0, full - (n - 1)), jHi = min(m - 1, full)
            if jLo <= jHi {
                for j in jLo...jHi { s += kernel[j] * a[full - j] }
            }
            out[k] = s
        }
        return out
    }

    /// np.round（四捨六入五成雙）
    static func roundHalfEven(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

    /// Python round(x, 2)
    static func round2(_ x: Double) -> Double { (x * 100).rounded(.toNearestOrEven) / 100 }
}
