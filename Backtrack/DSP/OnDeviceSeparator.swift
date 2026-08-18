import AVFoundation
import CoreML
import Foundation

/// Runs the full on-device isolation: audio file -> 44.1k stereo floats ->
/// multiband spectrogram -> windowed Core ML inference -> instrumental m4a.
final class OnDeviceSeparator {
    typealias Progress = (String, Double) -> Void  // (stage label, 0...1)

    private let dsp = UVRDSP()
    private var model: MLModel?

    static let shared = OnDeviceSeparator()

    private func loadModel() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: "UVR2HP", withExtension: "mlmodelc") else {
            throw UVRDSPError.model("UVR2HP.mlmodelc missing from app bundle")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all  // ANE/GPU when available
        let m = try MLModel(contentsOf: url, configuration: config)
        model = m
        return m
    }

    // MARK: - Public entry

    func separate(inputURL: URL, progress: @escaping Progress) throws -> URL {
        progress("Decoding audio…", 0.02)
        let wave = try Self.decodeToStereo44k(inputURL)

        progress("Analyzing spectrum…", 0.06)
        let (specs, highEnds) = inputPipeline(wave)

        let masked = try runModel(specs, progress: progress)

        progress("Rebuilding audio…", 0.9)
        let mirrored = Self.applyMirroring(masked, highEnds: highEnds)
        let out = outputPipeline(mirrored)

        progress("Encoding…", 0.96)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("instrumental-\(UUID().uuidString).m4a")
        try Self.writeM4A(out, to: dest)
        progress("Done", 1.0)
        return dest
    }

    // MARK: - Input pipeline (port of uvr_dsp.input_pipeline)

    /// Returns per-channel combined spectrograms and the high-end slices
    /// used later for mirroring.
    private func inputPipeline(_ wave44: [[Float]])
        -> (specs: [Spectrogram], highEnds: [Spectrogram]) {
        let bands = UVRParams.bands
        let bandsN = bands.count
        var bandWaves: [Int: [[Float]]] = [bandsN: wave44]
        for d in stride(from: bandsN - 1, through: 1, by: -1) {
            let srAbove = bands[d].sr       // band d+1 (0-indexed d)
            let srHere = bands[d - 1].sr
            if srHere == srAbove {
                bandWaves[d] = bandWaves[d + 1]
            } else {
                let q = srAbove / srHere
                bandWaves[d] = bandWaves[d + 1]!.map {
                    UVRDSP.resamplePolyDown($0, q: q)
                }
            }
        }

        var bandSpecs: [Int: [Spectrogram]] = [:]
        var highEnds: [Spectrogram] = []
        let heH = Self.highEndH
        for d in 1...bandsN {
            let bp = bands[d - 1]
            let spec = bandWaves[d]!.map {
                dsp.stft($0, nFFT: bp.nFFT, hop: bp.hl)
            }
            bandSpecs[d] = spec
            if d == bandsN {
                let maxBin = bp.nFFT / 2
                highEnds = spec.map { s in
                    var he = Spectrogram(bins: heH, frames: s.frames)
                    for (i, b) in ((maxBin - heH)..<maxBin).enumerated() {
                        for t in 0..<s.frames {
                            he.re[he.idx(i, t)] = s.re[s.idx(b, t)]
                            he.im[he.idx(i, t)] = s.im[s.idx(b, t)]
                        }
                    }
                    return he
                }
            }
        }
        return (Self.combineSpectrograms(bandSpecs), highEnds)
    }

    static var highEndH: Int {
        let top = UVRParams.bands.last!
        return (top.nFFT / 2 - top.cropStop)
            + (UVRParams.preFilterStop - UVRParams.preFilterStart)
    }

    static func combineSpectrograms(_ specs: [Int: [Spectrogram]]) -> [Spectrogram] {
        let bands = UVRParams.bands
        let frames = (1...bands.count)
            .map { specs[$0]![0].frames }.min()!
        var out = [Spectrogram(bins: UVRParams.bins + 1, frames: frames),
                   Spectrogram(bins: UVRParams.bins + 1, frames: frames)]
        for ch in 0..<2 {
            var offset = 0
            for d in 1...bands.count {
                let bp = bands[d - 1]
                let s = specs[d]![ch]
                for (i, b) in (bp.cropStart..<bp.cropStop).enumerated() {
                    for t in 0..<frames {
                        out[ch].re[out[ch].idx(offset + i, t)] = s.re[s.idx(b, t)]
                        out[ch].im[out[ch].idx(offset + i, t)] = s.im[s.idx(b, t)]
                    }
                }
                offset += bp.cropStop - bp.cropStart
            }
            // pre-filter rolloff (multi-band branch of combine_spectrograms)
            var gp: Float = 1
            for b in (UVRParams.preFilterStart + 1)..<UVRParams.preFilterStop {
                let g = pow(10, -Float(b - UVRParams.preFilterStart) * (3.5 - gp) / 20.0)
                gp = g
                for t in 0..<frames {
                    out[ch].re[out[ch].idx(b, t)] *= g
                    out[ch].im[out[ch].idx(b, t)] *= g
                }
            }
        }
        return out
    }

    // MARK: - Core ML inference (port of uvr5_pack/utils.inference)

    private func runModel(_ specs: [Spectrogram],
                          progress: @escaping Progress) throws -> [Spectrogram] {
        let model = try loadModel()
        let bins = specs[0].bins          // 673
        let frames = specs[0].frames
        let window = UVRParams.windowSize // 512
        let offset = UVRParams.modelOffset
        let roi = window - 2 * offset     // 256

        // magnitudes + global normalization
        var mag = [[Float]](repeating: [Float](repeating: 0, count: bins * frames), count: 2)
        var coef: Float = 0
        for ch in 0..<2 {
            let s = specs[ch]
            for i in 0..<(bins * frames) {
                let m = (s.re[i] * s.re[i] + s.im[i] * s.im[i]).squareRoot()
                mag[ch][i] = m
                coef = max(coef, m)
            }
        }
        if coef == 0 { coef = 1 }

        let nWindow = Int(ceil(Double(frames) / Double(roi)))
        let shape: [NSNumber] = [1, 2, NSNumber(value: bins), NSNumber(value: window)]
        var pred = [[Float]](repeating: [Float](repeating: 0, count: bins * frames), count: 2)

        for w in 0..<nWindow {
            progress("Isolating on device…", 0.1 + 0.78 * Double(w) / Double(nWindow))
            let start = w * roi - offset   // window w covers padded [start, start+512)
            let input = try MLMultiArray(shape: shape, dataType: .float32)
            let ptr = input.dataPointer.bindMemory(to: Float.self,
                                                   capacity: 2 * bins * window)
            for ch in 0..<2 {
                for b in 0..<bins {
                    let rowIn = mag[ch]
                    let base = (ch * bins + b) * window
                    for t in 0..<window {
                        let src = start + t
                        ptr[base + t] = (src >= 0 && src < frames)
                            ? rowIn[b * frames + src] / coef : 0
                    }
                }
            }
            let fp = try MLDictionaryFeatureProvider(dictionary: ["mag": input])
            let result = try model.prediction(from: fp)
            guard let out = result.featureValue(for: "masked_mag")?.multiArrayValue else {
                throw UVRDSPError.model("model returned no masked_mag")
            }
            let optr = out.dataPointer.bindMemory(to: Float.self,
                                                  capacity: 2 * bins * window)
            // aggressiveness pow on the recovered mask, then crop the roi
            for ch in 0..<2 {
                for b in 0..<bins {
                    let base = (ch * bins + b) * window
                    let exponent: Float = b < UVRParams.aggSplitBin
                        ? 1 + UVRParams.aggValue / 3 : 1 + UVRParams.aggValue
                    for t in offset..<(window - offset) {
                        let src = start + t
                        guard src >= 0 && src < frames else { continue }
                        let mix = mag[ch][b * frames + src] / coef
                        let masked = optr[base + t]
                        let mask = mix > 1e-10 ? min(max(masked / mix, 0), 1) : 0
                        pred[ch][b * frames + src] = pow(mask, exponent) * mix * coef
                    }
                }
            }
        }

        // reapply original phase: out = pred * spec/|spec|
        var out = [Spectrogram(bins: bins, frames: frames),
                   Spectrogram(bins: bins, frames: frames)]
        for ch in 0..<2 {
            let s = specs[ch]
            for i in 0..<(bins * frames) {
                let m = mag[ch][i]
                if m > 1e-10 {
                    out[ch].re[i] = pred[ch][i] * s.re[i] / m
                    out[ch].im[i] = pred[ch][i] * s.im[i] / m
                }
            }
        }
        return out
    }

    // MARK: - Mirroring + output pipeline

    static func applyMirroring(_ specs: [Spectrogram],
                               highEnds: [Spectrogram]) -> (specs: [Spectrogram], highEnds: [Spectrogram]) {
        let pfs = UVRParams.preFilterStart
        var mirrored: [Spectrogram] = []
        for ch in 0..<2 {
            let s = specs[ch]
            let he = highEnds[ch]
            let h = he.bins
            var outHe = Spectrogram(bins: h, frames: he.frames)
            for i in 0..<h {
                // mirror = flip(abs(spec[pfs-10-h : pfs-10]), bins axis)
                let srcBin = pfs - 10 - h + (h - 1 - i)
                for t in 0..<min(he.frames, s.frames) {
                    let mm = (s.re[s.idx(srcBin, t)] * s.re[s.idx(srcBin, t)]
                        + s.im[s.idx(srcBin, t)] * s.im[s.idx(srcBin, t)]).squareRoot()
                    let hr = he.re[he.idx(i, t)]
                    let hi = he.im[he.idx(i, t)]
                    let hm = (hr * hr + hi * hi).squareRoot()
                    if hm <= mm || hm < 1e-12 {
                        outHe.re[outHe.idx(i, t)] = hr
                        outHe.im[outHe.idx(i, t)] = hi
                    } else {
                        // mirror magnitude with the high end's phase
                        outHe.re[outHe.idx(i, t)] = mm * hr / hm
                        outHe.im[outHe.idx(i, t)] = mm * hi / hm
                    }
                }
            }
            mirrored.append(outHe)
        }
        return (specs, mirrored)
    }

    private func outputPipeline(_ input: (specs: [Spectrogram], highEnds: [Spectrogram])) -> [[Float]] {
        let bands = UVRParams.bands
        let bandsN = bands.count
        let frames = input.specs[0].frames
        var waves = [[Float]](repeating: [], count: 2)

        for ch in 0..<2 {
            let specM = input.specs[ch]
            var offset = 0
            var wave: [Float] = []
            for d in 1...bandsN {
                let bp = bands[d - 1]
                var specS = Spectrogram(bins: bp.nFFT / 2 + 1, frames: frames)
                let h = bp.cropStop - bp.cropStart
                for i in 0..<h {
                    for t in 0..<frames {
                        specS.re[specS.idx(bp.cropStart + i, t)] =
                            specM.re[specM.idx(offset + i, t)]
                        specS.im[specS.idx(bp.cropStart + i, t)] =
                            specM.im[specM.idx(offset + i, t)]
                    }
                }
                offset += h

                if d == bandsN {
                    // insert mirrored high end
                    let he = input.highEnds[ch]
                    let maxBin = bp.nFFT / 2
                    for i in 0..<he.bins {
                        for t in 0..<min(frames, he.frames) {
                            specS.re[specS.idx(maxBin - he.bins + i, t)] = he.re[he.idx(i, t)]
                            specS.im[specS.idx(maxBin - he.bins + i, t)] = he.im[he.idx(i, t)]
                        }
                    }
                    UVRDSP.fftHPFilter(&specS, bp.hpfStart, bp.hpfStop - 1)
                    let w = dsp.istft(specS, hop: bp.hl)
                    for i in 0..<min(wave.count, w.count) { wave[i] += w[i] }
                } else if d == 1 {
                    UVRDSP.fftLPFilter(&specS, bp.lpfStart, bp.lpfStop)
                    wave = dsp.istft(specS, hop: bp.hl)
                    // 4band_v2: band1.sr == band2.sr, no resample here
                } else {
                    UVRDSP.fftHPFilter(&specS, bp.hpfStart, bp.hpfStop - 1)
                    UVRDSP.fftLPFilter(&specS, bp.lpfStart, bp.lpfStop)
                    let w = dsp.istft(specS, hop: bp.hl)
                    var wave2 = wave
                    for i in 0..<min(wave2.count, w.count) { wave2[i] += w[i] }
                    let factor = bands[d].sr / bp.sr
                    wave = UVRDSP.upsampleSinc(wave2, factor: factor)
                }
            }
            waves[ch] = wave
        }
        return waves
    }

    // MARK: - Audio I/O

    static func decodeToStereo44k(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 44100, channels: 2,
                                      interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: outFormat)!
        var left: [Float] = []
        var right: [Float] = []
        let inCap: AVAudioFrameCount = 65536
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: inCap)!
        let outBuf = AVAudioPCMBuffer(
            pcmFormat: outFormat,
            frameCapacity: AVAudioFrameCount(Double(inCap) * 44100.0
                / file.processingFormat.sampleRate + 4096))!
        var eof = false
        while !eof {
            var consumed = false
            let status = converter.convert(to: outBuf, error: nil) { _, outStatus in
                if consumed || eof {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    inBuf.frameLength = 0
                    try file.read(into: inBuf, frameCount: inCap)
                } catch { }
                if inBuf.frameLength == 0 {
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { break }
            let n = Int(outBuf.frameLength)
            if n > 0, let data = outBuf.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
                let rc = outFormat.channelCount > 1 ? data[1] : data[0]
                right.append(contentsOf: UnsafeBufferPointer(start: rc, count: n))
            }
            outBuf.frameLength = 0
            if status == .endOfStream { break }
        }
        return [left, right]
    }

    static func writeM4A(_ wave: [[Float]], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44100, channels: 2,
                                   interleaved: false)!
        let n = min(wave[0].count, wave[1].count)
        let chunk = 65536
        var pos = 0
        while pos < n {
            let len = min(chunk, n - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: format,
                                       frameCapacity: AVAudioFrameCount(len))!
            buf.frameLength = AVAudioFrameCount(len)
            for ch in 0..<2 {
                let dst = buf.floatChannelData![ch]
                wave[ch].withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress! + pos, count: len)
                }
            }
            try file.write(from: buf)
            pos += len
        }
    }
}
