import Accelerate
import Foundation

/// STFT / iSTFT matching demucs HTDemucs._spec / _ispec (n_fft 4096, hop 1024, periodic Hann,
/// normalized=True, center=True, reflect padding). Pure signal processing via vDSP.
/// Verified against numpy: max error 2e-7 (forward) and 5e-7 (inverse).
final class DemucsSTFT {
    static let nfft = 4096
    static let hop = 1024
    static let bins = 2048  // last (Nyquist) bin is dropped, as in demucs

    let length: Int      // samples per segment (343980)
    let frames: Int      // ceil(length / hop) = 336
    private let window: [Float]
    private let fwd: vDSP_DFT_Setup
    private let inv: vDSP_DFT_Setup
    private let envelopeInv: [Float]  // 1 / sum(window^2) at each output sample

    init(length: Int) {
        let n = DemucsSTFT.nfft
        self.length = length
        self.frames = (length + DemucsSTFT.hop - 1) / DemucsSTFT.hop
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
        fwd = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inv = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
        let padded = frames + 4
        let total = n + DemucsSTFT.hop * (padded - 1)
        var env = [Float](repeating: 0, count: total)
        for p in 0..<padded {
            for i in 0..<n { env[p * DemucsSTFT.hop + i] += window[i] * window[i] }
        }
        let origin = n / 2 + DemucsSTFT.hop / 2 * 3
        envelopeInv = (0..<length).map { 1 / max(env[origin + $0], 1e-11) }
    }

    deinit {
        vDSP_DFT_DestroySetup(fwd)
        vDSP_DFT_DestroySetup(inv)
    }

    private static func reflectPad(_ x: [Float], _ left: Int, _ right: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: left + n + right)
        for i in 0..<left { out[i] = x[left - i] }
        for i in 0..<n { out[left + i] = x[i] }
        for i in 0..<right { out[left + n + i] = x[n - 2 - i] }
        return out
    }

    /// seg: channel-major [2 * length]. Writes complex-as-channels spectrogram [4, 2048, frames] into `out`.
    func forward(_ seg: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let n = DemucsSTFT.nfft, hop = DemucsSTFT.hop, bins = DemucsSTFT.bins, half = n / 2
        let scale = 0.5 / sqrt(Float(n))  // vDSP zrop forward is 2x the math DFT; demucs normalizes by 1/sqrt(n)
        var frame = [Float](repeating: 0, count: n)
        var ir = [Float](repeating: 0, count: half), ii = [Float](repeating: 0, count: half)
        var or = [Float](repeating: 0, count: half), oi = [Float](repeating: 0, count: half)
        for ch in 0..<2 {
            let x = Array(UnsafeBufferPointer(start: seg + ch * length, count: length))
            let pad = hop / 2 * 3
            let p1 = DemucsSTFT.reflectPad(x, pad, pad + frames * hop - length)
            let p2 = DemucsSTFT.reflectPad(p1, half, half)
            let re = out + (ch * 2) * bins * frames
            let im = out + (ch * 2 + 1) * bins * frames
            for t in 0..<frames {
                let start = (t + 2) * hop
                p2.withUnsafeBufferPointer { p in
                    vDSP_vmul(p.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
                }
                for j in 0..<half { ir[j] = frame[2 * j]; ii[j] = frame[2 * j + 1] }
                vDSP_DFT_Execute(fwd, ir, ii, &or, &oi)
                re[t] = or[0] * scale  // DC; Nyquist (in oi[0]) is dropped
                im[t] = 0
                for k in 1..<bins {
                    re[k * frames + t] = or[k] * scale
                    im[k * frames + t] = oi[k] * scale
                }
            }
        }
    }

    /// spec: [4, 2048, frames] complex-as-channels. Adds the time-domain result to `out` [2 * length].
    func inverseAdd(_ spec: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let n = DemucsSTFT.nfft, hop = DemucsSTFT.hop, bins = DemucsSTFT.bins, half = n / 2
        let scale = [sqrt(Float(n)) / Float(n)]  // vDSP inverse gives 2n*x for 2x-scaled input; demucs multiplies by sqrt(n)
        let origin = half + hop / 2 * 3
        var ir = [Float](repeating: 0, count: half), ii = [Float](repeating: 0, count: half)
        var or = [Float](repeating: 0, count: half), oi = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var tmp = [Float](repeating: 0, count: n)
        for ch in 0..<2 {
            let re = spec + (ch * 2) * bins * frames
            let im = spec + (ch * 2 + 1) * bins * frames
            let dst = out + ch * length
            for t in 0..<frames {
                ir[0] = re[t]; ii[0] = 0
                for k in 1..<bins { ir[k] = re[k * frames + t]; ii[k] = im[k * frames + t] }
                vDSP_DFT_Execute(inv, ir, ii, &or, &oi)
                for j in 0..<half { frame[2 * j] = or[j]; frame[2 * j + 1] = oi[j] }
                // frame t sits at padded index t + 2, i.e. OLA position (t + 2) * hop; output sample = position - origin
                let pos0 = (t + 2) * hop - origin
                let lo = max(0, -pos0), hi = min(n, length - pos0)
                if lo >= hi { continue }
                let cnt = vDSP_Length(hi - lo)
                frame.withUnsafeBufferPointer { f in window.withUnsafeBufferPointer { w in
                    vDSP_vmul(f.baseAddress! + lo, 1, w.baseAddress! + lo, 1, &tmp, 1, cnt)
                } }
                vDSP_vsmul(tmp, 1, scale, &tmp, 1, cnt)
                envelopeInv.withUnsafeBufferPointer { e in
                    vDSP_vma(tmp, 1, e.baseAddress! + pos0 + lo, 1, dst + pos0 + lo, 1, dst + pos0 + lo, 1, cnt)
                }
            }
        }
    }
}
