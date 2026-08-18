import Foundation

struct ServerError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Thin REST client for the desktop server (see desktop-server/server.py).
struct ServerClient {
    var baseURL: URL
    var token: String

    init?(urlString: String, token: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        self.baseURL = url
        self.token = token
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 15
        if !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            if let err = try? JSONDecoder().decode([String: String].self, from: data),
               let msg = err["error"] {
                throw ServerError(message: msg)
            }
            throw ServerError(message: "Server returned \(http.statusCode)")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func health() async throws -> HealthInfo {
        let (data, resp) = try await URLSession.shared.data(for: request("health"))
        return try decode(HealthInfo.self, from: data, response: resp)
    }

    func nowPlaying() async throws -> NowPlaying {
        let (data, resp) = try await URLSession.shared.data(for: request("now-playing"))
        return try decode(NowPlaying.self, from: data, response: resp)
    }

    func extract(url: String) async throws -> JobStatus {
        let body = try JSONEncoder().encode(["url": url])
        let (data, resp) = try await URLSession.shared.data(
            for: request("extract", method: "POST", body: body))
        return try decode(JobStatus.self, from: data, response: resp)
    }

    func status(job: String) async throws -> JobStatus {
        let (data, resp) = try await URLSession.shared.data(for: request("status/\(job)"))
        return try decode(JobStatus.self, from: data, response: resp)
    }

    /// Downloads the finished instrumental to a local file and returns its URL.
    func downloadAudio(job: String) async throws -> URL {
        var req = request("audio/\(job)")
        req.timeoutInterval = 120
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw ServerError(message: "Audio not ready (\(http.statusCode))")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("instrumental-\(job).m4a")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
