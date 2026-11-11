import Foundation

/// 一段立體聲音訊（44.1 kHz，左右聲道分開存）。手機去人聲的每一步都用這個格式交接。
struct StereoAudio: Sendable {
    static let sampleRate = 44_100.0

    var left: [Float]
    var right: [Float]

    init(left: [Float], right: [Float]) {
        precondition(left.count == right.count, "左右聲道長度要一樣")
        self.left = left
        self.right = right
    }

    var frameCount: Int { left.count }
    var duration: Double { Double(frameCount) / Self.sampleRate }

    /// 左右平均的單聲道
    var mono: [Float] {
        var out = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount { out[i] = 0.5 * (left[i] + right[i]) }
        return out
    }

    /// 兩個聲道裡絕對值最大的樣本
    var peak: Float {
        var p: Float = 0
        for v in left { p = max(p, abs(v)) }
        for v in right { p = max(p, abs(v)) }
        return p
    }

    func scaled(by k: Float) -> StereoAudio {
        StereoAudio(left: left.map { $0 * k }, right: right.map { $0 * k })
    }

    /// self - other（逐樣本相減）
    func subtracting(_ other: StereoAudio) -> StereoAudio {
        precondition(frameCount == other.frameCount)
        var l = left, r = right
        for i in 0..<frameCount {
            l[i] -= other.left[i]
            r[i] -= other.right[i]
        }
        return StereoAudio(left: l, right: r)
    }
}
