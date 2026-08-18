import Foundation

struct NowPlaying: Codable, Equatable {
    var playing: Bool
    var title: String?
    var artist: String?
    var url: String?
    var artwork: String?
    var duration: Int?
}

struct JobStatus: Codable, Equatable {
    var job: String
    var url: String?
    var stage: String   // queued|fetching|downloading|separating|encoding|done|error
    var error: String?
    var title: String?
    var artist: String?
    var duration: Double?
    var artwork: String?
    var elapsed: Double?

    var isDone: Bool { stage == "done" }
    var isError: Bool { stage == "error" }

    var stageLabel: String {
        switch stage {
        case "queued": return "Queued…"
        case "fetching": return "Fetching track info…"
        case "downloading": return "Downloading from Spotify…"
        case "separating": return "Isolating background music…"
        case "encoding": return "Finishing up…"
        case "done": return "Done"
        case "error": return "Failed"
        default: return stage
        }
    }
}

struct HealthInfo: Codable {
    var ok: Bool
    var model_loaded: Bool?
    var device: String?
    var spotify_configured: Bool?
    var auth_required: Bool?
}

enum AppPhase: Equatable {
    case idle
    case working(String)   // stage label
    case ready
    case failed(String)
}
