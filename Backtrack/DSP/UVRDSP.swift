import Accelerate
import CoreML
import Foundation

/// Swift port of tools/uvr_dsp.py (the numpy reference validated at 138 dB
/// against the original librosa pipeline) plus the windowed Core ML
/// inference loop from uvr5_pack/utils.py.
///
/// Hardcoded to the 4band_v2 model params used by 2_HP-UVR.
enum UVRParams {
    struct Band {
        let sr: Int, hl: Int, nFFT: Int
        let cropStart: Int, cropStop: Int
        let hpfStart: Int, hpfStop: Int
        let lpfStart: Int, lpfStop: Int
    }
    static let bins = 672
    static let sr = 44100
    static let preFilterStart = 668
    static let preFilterStop = 672
    // band index 1...4, matching modelparams/4band_v2.json
    static let bands: [Band] = [
        Band(sr: 7350, hl: 80, nFFT: 640, cropStart: 0, cropStop: 85,
             hpfStart: 0, hpfStop: 0, lpfStart: 25, lpfStop: 53),
        Band(sr: 7350, hl: 80, nFFT: 320, cropStart: 4, cropStop: 87,
             hpfStart: 25, hpfStop: 12, lpfStart: 31, lpfStop: 62),
        Band(sr: 14700, hl: 160, nFFT: 512, cropStart: 17, cropStop: 216,
             hpfStart: 48, hpfStop: 24, lpfStart: 139, lpfStop: 210),
        Band(sr: 44100, hl: 480, nFFT: 960, cropStart: 78, cropStop: 383,
             hpfStart: 130, hpfStop: 86, lpfStart: 0, lpfStop: 0),
    ]
    static let windowSize = 512   // model time window (frames)
    static let modelOffset = 128  // CascadedASPPNet.offset
    static let aggValue: Float = 0.1        // agg 10 / 100
    static let aggSplitBin = 85             // band[1].crop_stop
}

/// One channel's complex spectrogram, bins x frames, flat row-major.
struct Spectrogram {
    var re: [Float]
    var im: [Float]
    let bins: Int
    var frames: Int
    init(bins: Int, frames: Int) {
        self.bins = bins
        self.frames = frames
        re = [Float](repeating: 0, count: bins * frames)
        im = [Float](repeating: 0, count: bins * frames)
    }
    @inline(__always) func idx(_ b: Int, _ t: Int) -> Int { b * frames + t }
}

enum UVRDSPError: LocalizedError {
    case model(String)
    var errorDescription: String? {
        if case .model(let m) = self { return m }
        return nil
    }
}

final class UVRDSP {

    // MARK: - Real DFT via vDSP (lengths 2^a * {1,3,5,15})

    private var forwardSetups: [Int: vDSP_DFT_Setup] = [:]
    private var inverseSetups: [Int: vDSP_DFT_Setup] = [:]

    deinit {
        for s in forwardSetups.values { vDSP_DFT_DestroySetup(s) }
        for s in inverseSetups.values { vDSP_DFT_DestroySetup(s) }
    }

    private func forwardSetup(_ n: Int) -> vDSP_DFT_Setup {
        if let s = forwardSetups[n] { return s }
        let s = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        forwardSetups[n] = s
        return s
    }

    private func inverseSetup(_ n: Int) -> vDSP_DFT_Setup {
        if let s = inverseSetups[n] { return s }
        let s = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
        inverseSetups[n] = s
        return s
    }

    private static func hann(_ n: Int) -> [Float] {
        (0..<n).map { 0.5 - 0.5 * cos(2.0 * Float.pi * Float($0) / Float(n)) }
    }

    /// librosa-0.9-compatible STFT: hann(n_fft), center=True, zero padding.
    /// Returns (n_fft/2 + 1) x frames.
    func stft(_ signal: [Float], nFFT: Int, hop: Int) -> Spectrogram {
        let pad = nFFT / 2
        var y = [Float](repeating: 0, count: signal.count + 2 * pad)
        y.replaceSubrange(pad..<(pad + signal.count), with: signal)
        let nFrames = 1 + (y.count - nFFT) / hop
        let half = nFFT / 2
        var spec = Spectrogram(bins: half + 1, frames: nFrames)
        let window = Self.hann(nFFT)
        let setup = forwardSetup(nFFT)

        var frame = [Float](repeating: 0, count: nFFT)
        var evens = [Float](repeating: 0, count: half)
        var odds = [Float](repeating: 0, count: half)
        var outRe = [Float](repeating: 0, count: half)
        var outIm = [Float](repeating: 0, count: half)

        for t in 0..<nFrames {
            let s = t * hop
            for i in 0..<nFFT { frame[i] = y[s + i] * window[i] }
            for i in 0..<half {
                evens[i] = frame[2 * i]
                odds[i] = frame[2 * i + 1]
            }
            vDSP_DFT_Execute(setup, evens, odds, &outRe, &outIm)
            // vDSP zrop forward = 2x the mathematical DFT; DC in re[0],
            // Nyquist in im[0].
            spec.re[spec.idx(0, t)] = outRe[0] * 0.5
            spec.im[spec.idx(0, t)] = 0
            spec.re[spec.idx(half, t)] = outIm[0] * 0.5
            spec.im[spec.idx(half, t)] = 0
            for b in 1..<half {
                spec.re[spec.idx(b, t)] = outRe[b] * 0.5
                spec.im[spec.idx(b, t)] = outIm[b] * 0.5
            }
        }
        return spec
    }

    /// librosa-compatible iSTFT (hann overlap-add with window-square
    /// normalization, centered trim).
    func istft(_ spec: Spectrogram, hop: Int) -> [Float] {
        let nFFT = 2 * (spec.bins - 1)
        let half = nFFT / 2
        let nFrames = spec.frames
        let outLen = nFFT + hop * (nFrames - 1)
        var out = [Float](repeating: 0, count: outLen)
        var wsum = [Float](repeating: 0, count: outLen)
        let window = Self.hann(nFFT)
        let wsq = window.map { $0 * $0 }
        let setup = inverseSetup(nFFT)

        var inRe = [Float](repeating: 0, count: half)
        var inIm = [Float](repeating: 0, count: half)
        var outEv = [Float](repeating: 0, count: half)
        var outOd = [Float](repeating: 0, count: half)
        let scale = 1.0 / Float(nFFT)

        for t in 0..<nFrames {
            inRe[0] = spec.re[spec.idx(0, t)]
            inIm[0] = spec.re[spec.idx(half, t)]  // Nyquist packed in im[0]
            for b in 1..<half {
                inRe[b] = spec.re[spec.idx(b, t)]
                inIm[b] = spec.im[spec.idx(b, t)]
            }
            vDSP_DFT_Execute(setup, inRe, inIm, &outEv, &outOd)
            let s = t * hop
            for i in 0..<half {
                out[s + 2 * i] += outEv[i] * scale * window[2 * i]
                out[s + 2 * i + 1] += outOd[i] * scale * window[2 * i + 1]
                wsum[s + 2 * i] += wsq[2 * i]
                wsum[s + 2 * i + 1] += wsq[2 * i + 1]
            }
        }
        for i in 0..<outLen where wsum[i] > 1e-10 { out[i] /= wsum[i] }
        return Array(out[half..<(outLen - half)])
    }

    // MARK: - Resampling

    /// Integer-factor decimation matching scipy resample_poly(x, 1, q)
    /// with the default ('kaiser', 5.0) design (see uvr_dsp.resample_poly_down).
    static func resamplePolyDown(_ x: [Float], q: Int) -> [Float] {
        let half = 10 * q
        let taps = 2 * half + 1
        var h = [Double](repeating: 0, count: taps)
        let fc = 1.0 / Double(q)
        // kaiser(beta=5.0) * sinc lowpass, normalized to unity DC gain
        let beta = 5.0
        let i0beta = besselI0(beta)
        var sum = 0.0
        for i in 0..<taps {
            let m = Double(i - half)
            let sinc = m == 0 ? fc : sin(.pi * fc * m) / (.pi * m)
            let r = 2.0 * Double(i) / Double(taps - 1) - 1.0
            let win = besselI0(beta * (1 - r * r).squareRoot()) / i0beta
            h[i] = sinc * win
            sum += h[i]
        }
        for i in 0..<taps { h[i] /= sum }

        // zero-pad by `half` on both sides, then y[k] = sum h[j] x[kq - half + j]
        let n = x.count
        let nOut = (n + q - 1) / q
        var padded = [Double](repeating: 0, count: n + 2 * half)
        for i in 0..<n { padded[half + i] = Double(x[i]) }
        var out = [Float](repeating: 0, count: nOut)
        for k in 0..<nOut {
            var acc = 0.0
            let base = k * q
            for j in 0..<taps { acc += h[j] * padded[base + j] }
            out[k] = Float(acc)
        }
        return out
    }

    private static func besselI0(_ x: Double) -> Double {
        // series expansion, converges fast for |x| <= ~20
        var sum = 1.0, term = 1.0
        var k = 1.0
        while true {
            term *= (x / (2 * k)) * (x / (2 * k))
            sum += term
            if term < 1e-16 * sum { break }
            k += 1
        }
        return sum
    }

    /// Integer-factor upsampling. The reference uses an FFT resample
    /// (librosa res_type='scipy'); arbitrary-length FFTs aren't available
    /// in vDSP, so we use a windowed-sinc interpolator instead - the
    /// deviation is confined to the transition band and inaudible.
    static func upsampleSinc(_ x: [Float], factor u: Int) -> [Float] {
        let halfPer = 32  // taps per phase (each side)
        let n = x.count
        var out = [Float](repeating: 0, count: n * u)
        let fc = 1.0 / Double(u)
        let beta = 8.0
        let i0beta = besselI0(beta)
        // polyphase kernels
        var phases = [[Double]](repeating: [], count: u)
        for p in 0..<u {
            var kernel = [Double](repeating: 0, count: 2 * halfPer)
            for j in 0..<(2 * halfPer) {
                // output sample (k*u + p) sits at input position k + p/u;
                // kernel taps at input offsets j - halfPer + 1 ... relative
                let m = Double(j - halfPer + 1) - Double(p) / Double(u)
                let sinc = m == 0 ? 1.0 : sin(.pi * m) / (.pi * m)
                let r = m / Double(halfPer)
                let win = abs(r) >= 1 ? 0.0
                    : besselI0(beta * (1 - r * r).squareRoot()) / i0beta
                kernel[j] = sinc * win
            }
            phases[p] = kernel
        }
        for k in 0..<n {
            for p in 0..<u {
                var acc = 0.0
                let kernel = phases[p]
                for j in 0..<(2 * halfPer) {
                    let src = k + j - halfPer + 1
                    if src >= 0 && src < n { acc += kernel[j] * Double(x[src]) }
                }
                out[k * u + p] = Float(acc)
            }
        }
        return out
    }

    // MARK: - Spectrogram assembly (ports of uvr_dsp.py)

    static func fftLPFilter(_ spec: inout Spectrogram, _ start: Int, _ stop: Int) {
        var g: Float = 1.0
        for b in start..<stop {
            g -= 1.0 / Float(stop - start)
            for t in 0..<spec.frames {
                spec.re[spec.idx(b, t)] *= g
                spec.im[spec.idx(b, t)] *= g
            }
        }
        for b in stop..<spec.bins {
            for t in 0..<spec.frames {
                spec.re[spec.idx(b, t)] = 0
                spec.im[spec.idx(b, t)] = 0
            }
        }
    }

    static func fftHPFilter(_ spec: inout Spectrogram, _ start: Int, _ stop: Int) {
        var g: Float = 1.0
        var b = start
        while b > stop {
            g -= 1.0 / Float(start - stop)
            for t in 0..<spec.frames {
                spec.re[spec.idx(b, t)] *= g
                spec.im[spec.idx(b, t)] *= g
            }
            b -= 1
        }
        for bb in 0...(max(stop, 0)) where bb < spec.bins {
            for t in 0..<spec.frames {
                spec.re[spec.idx(bb, t)] = 0
                spec.im[spec.idx(bb, t)] = 0
            }
        }
    }
}
