import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: "serverURL") }
    }
    @Published var serverToken: String {
        didSet { UserDefaults.standard.set(serverToken, forKey: "serverToken") }
    }
    @Published var linkText = ""
    @Published var nowPlaying: NowPlaying?
    @Published var phase: AppPhase = .idle
    @Published var job: JobStatus?
    @Published var showSettings = false

    let player = PlayerController()

    private var pollTask: Task<Void, Never>?
    private var nowPlayingTask: Task<Void, Never>?

    init() {
        serverURLString = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        serverToken = UserDefaults.standard.string(forKey: "serverToken") ?? ""
    }

    var client: ServerClient? {
        ServerClient(urlString: serverURLString, token: serverToken)
    }

    static func isTrackLink(_ s: String) -> Bool {
        s.contains("open.spotify.com") && s.contains("/track/")
            || s.contains("spotify:track:")
    }

    /// The link field wins when it holds a valid track link; otherwise fall
    /// back to whatever Spotify is currently playing.
    var sourceURL: String? {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isTrackLink(trimmed) { return trimmed }
        if let np = nowPlaying, let url = np.url { return url }
        return nil
    }

    var usesNowPlaying: Bool {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !Self.isTrackLink(trimmed) && nowPlaying?.url != nil
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    func pasteFromClipboard() {
        if let s = UIPasteboard.general.string {
            linkText = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func startNowPlayingRefresh() {
        nowPlayingTask?.cancel()
        nowPlayingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let client = self.client {
                    if let np = try? await client.nowPlaying(), np.url != nil {
                        self.nowPlaying = np
                    } else {
                        self?.nowPlaying = nil
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func isolate() {
        guard let client else {
            phase = .failed("Set the server address in Settings first.")
            showSettings = true
            return
        }
        guard let src = sourceURL else {
            phase = .failed("Paste a Spotify track link or play something on Spotify.")
            return
        }
        player.stop()
        job = nil
        phase = .working("Starting…")
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            do {
                var status = try await client.extract(url: src)
                self?.job = status
                while !status.isDone && !status.isError {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    status = try await client.status(job: status.job)
                    self?.job = status
                    self?.phase = .working(status.stageLabel)
                }
                if status.isError {
                    self?.phase = .failed(status.error ?? "Extraction failed on the server.")
                    return
                }
                self?.phase = .working("Loading audio…")
                let file = try await client.downloadAudio(job: status.job)
                try self?.player.load(fileURL: file)
                self?.phase = .ready
            } catch is CancellationError {
                // superseded by a newer request
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }
}
