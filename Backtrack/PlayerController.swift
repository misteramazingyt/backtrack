import AVFoundation
import Foundation

/// Plays the downloaded instrumental and exposes a waveform + scrub position.
final class PlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var waveform: [Float] = []

    private var player: AVAudioPlayer?
    private var timer: Timer?

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func load(fileURL: URL) throws {
        stop()
        let p = try AVAudioPlayer(contentsOf: fileURL)
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = 0
        waveform = Self.computeWaveform(fileURL: fileURL, buckets: 110)
    }

    func playPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, duration - 0.05))
        currentTime = player.currentTime
    }

    func skip(_ seconds: Double) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = duration
        stopTimer()
    }

    /// Per-bucket RMS of the decoded audio, normalized to 0...1.
    static func computeWaveform(fileURL: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return [] }
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [] }
        let framesPerBucket = max(1, totalFrames / buckets)
        var result: [Float] = []
        result.reserveCapacity(buckets)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerBucket)
        ) else { return [] }

        for _ in 0..<buckets {
            do {
                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: AVAudioFrameCount(framesPerBucket))
            } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            var sum: Float = 0
            if let data = buffer.floatChannelData {
                let channels = Int(format.channelCount)
                for c in 0..<channels {
                    let samples = data[c]
                    for i in 0..<n { sum += samples[i] * samples[i] }
                }
                sum /= Float(n * max(1, channels))
            }
            result.append(sqrt(sum))
        }
        let peak = result.max() ?? 1
        guard peak > 0 else { return result }
        return result.map { min(1, $0 / peak) }
    }
}
