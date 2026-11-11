import CoreML
import Foundation

/// 去人聲的結果：伴唱 + 人聲 = 原曲（逐樣本相加剛好還原）
struct SeparatedStems: Sendable {
    var accompaniment: StereoAudio
    var vocals: StereoAudio
}

/// 去人聲引擎。轉換流程只認這個介面：以後換模型（或改用 GPU）只要新增一個實作。
///
/// 契約（CarKaraokeTests/VocalSeparatorContractTests 對每個實作都會驗證）：
/// - 輸出兩軌的長度和輸入一樣，沒有 NaN
/// - 伴唱 + 人聲 ≈ 原曲
/// - progress 從小到大，最後一次是 1
/// - 每處理一段前呼叫 checkpoint；checkpoint 丟出錯誤（取消）時，separate 也丟出同一個錯誤
protocol VocalSeparating: Sendable {
    func separate(_ audio: StereoAudio,
                  progress: @Sendable (Double) -> Void,
                  checkpoint: @Sendable () async throws -> Void) async throws -> SeparatedStems
}

/// Meta 開源的 Demucs v4（htdemucs，MIT 授權），和 Mac 轉換工具用同一個模型。
/// 模型轉成 Core ML、權重壓成 int8（55 MB）；頻譜轉換在 DemucsSTFT 用 Accelerate 算。
/// 一定要只用 CPU：Core ML 預設的「自動」在這個模型上會卡十幾分鐘後被系統關掉（iPhone 17 實測）。
final class DemucsSeparator: VocalSeparating, @unchecked Sendable {
    static let modelName = "HTDemucsVocals"
    static let segmentLength = 343_980  // 7.8 秒：模型訓練時的長度，固定
    static let overlap = 0.25

    private let modelURL: URL?
    private let lock = NSLock()
    private var model: MLModel?

    init(bundle: Bundle = .main) {
        modelURL = bundle.url(forResource: Self.modelName, withExtension: "mlmodelc")
    }

    private func loadModel() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let model { return model }
        guard let modelURL else { throw ConversionError.modelMissing }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        let m = try MLModel(contentsOf: modelURL, configuration: cfg)
        model = m
        return m
    }

    func separate(_ audio: StereoAudio,
                  progress: @Sendable (Double) -> Void,
                  checkpoint: @Sendable () async throws -> Void) async throws -> SeparatedStems {
        let model = try loadModel()
        let L = Self.segmentLength
        let N = audio.frameCount
        let stft = DemucsSTFT(length: L)

        // 和 demucs 一樣：用整首歌單聲道的平均和標準差正規化
        var mean = 0.0, sq = 0.0
        for i in 0..<N { mean += 0.5 * Double(audio.left[i] + audio.right[i]) }
        mean /= Double(max(N, 1))
        for i in 0..<N { let d = 0.5 * Double(audio.left[i] + audio.right[i]) - mean; sq += d * d }
        let fmean = Float(mean), fstd = Float(sqrt(sq / Double(max(N - 1, 1))) + 1e-8)

        // 每段之間重疊 25%，用三角形權重接起來（demucs.apply.apply_model 的做法）
        let stride = Int((1 - Self.overlap) * Double(L))
        var weight = [Float](repeating: 0, count: L)
        for i in 0..<(L / 2) { weight[i] = Float(i + 1) }
        for i in (L / 2)..<L { weight[i] = Float(L - i) }
        let wmax = weight.max() ?? 1
        for i in 0..<L { weight[i] /= wmax }

        var accL = [Float](repeating: 0, count: N), accR = [Float](repeating: 0, count: N)
        var sumW = [Float](repeating: 0, count: N)
        let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: L)], dataType: .float32)
        let specArr = try MLMultiArray(shape: [1, 4, 2048, NSNumber(value: stft.frames)], dataType: .float32)
        var voc = [Float](repeating: 0, count: 2 * L)
        let offsets = Array(Swift.stride(from: 0, to: N, by: stride))

        progress(0)
        for (k, off) in offsets.enumerated() {
            try await checkpoint()
            let clen = min(L, N - off)
            let delta = L - clen
            let start = off - delta / 2  // 最後一段不足 7.8 秒：往前多拿一點當上下文
            let mp = mixArr.dataPointer.assumingMemoryBound(to: Float.self)
            for c in 0..<2 {
                let src = c == 0 ? audio.left : audio.right
                let dst = mp + c * L
                src.withUnsafeBufferPointer { s in
                    for i in 0..<L {
                        let j = start + i
                        dst[i] = (j >= 0 && j < N) ? (s[j] - fmean) / fstd : 0
                    }
                }
            }
            stft.forward(UnsafePointer(mp), into: specArr.dataPointer.assumingMemoryBound(to: Float.self))
            let out = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": mixArr, "spec": specArr]))
            guard let specOut = out.featureValue(for: "vocals_spec")?.multiArrayValue,
                  let waveOut = out.featureValue(for: "vocals_wave")?.multiArrayValue else {
                throw ConversionError.modelMissing
            }
            voc.withUnsafeMutableBufferPointer { v in
                Self.withContiguousFloats(waveOut) { v.baseAddress!.update(from: $0, count: 2 * L) }
                Self.withContiguousFloats(specOut) { stft.inverseAdd($0, into: v.baseAddress!) }
            }
            let lo = delta / 2
            for i in 0..<clen {
                let w = weight[i]
                accL[off + i] += w * voc[lo + i]
                accR[off + i] += w * voc[L + lo + i]
                sumW[off + i] += w
            }
            progress(Double(k + 1) / Double(offsets.count))
        }

        var vocL = accL, vocR = accR
        var instL = audio.left, instR = audio.right
        for i in 0..<N {
            vocL[i] = accL[i] / sumW[i] * fstd + fmean
            vocR[i] = accR[i] / sumW[i] * fstd + fmean
            instL[i] -= vocL[i]
            instR[i] -= vocR[i]
        }
        return SeparatedStems(accompaniment: StereoAudio(left: instL, right: instR),
                              vocals: StereoAudio(left: vocL, right: vocR))
    }

    /// 模型輸出通常是連續的 float32，直接讀不複製；不是的話先轉一份。
    private static func withContiguousFloats(_ a: MLMultiArray, _ body: (UnsafePointer<Float>) -> Void) {
        var expected = 1
        var contiguous = a.dataType == .float32
        for d in Swift.stride(from: a.shape.count - 1, through: 0, by: -1) {
            if a.strides[d].intValue != expected { contiguous = false }
            expected *= a.shape[d].intValue
        }
        if contiguous {
            body(UnsafePointer(a.dataPointer.assumingMemoryBound(to: Float.self)))
        } else {
            MLShapedArray<Float>(converting: a).withUnsafeShapedBufferPointer { p, _, _ in body(p.baseAddress!) }
        }
    }
}
