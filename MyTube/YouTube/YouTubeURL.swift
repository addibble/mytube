import Foundation

enum YouTubeURL {
    /// Extracts the 11-character video ID from a YouTube URL (watch, youtu.be, shorts, embed, live) or a bare ID.
    static func videoID(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isVideoID(text) { return text }

        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme), let host = components.host?.lowercased() else {
            return nil
        }
        let path = components.path.split(separator: "/").map(String.init)

        var candidate: String?
        if host == "youtu.be" {
            candidate = path.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
                candidate = v
            } else if path.count >= 2, ["shorts", "embed", "live", "v"].contains(path[0]) {
                candidate = path[1]
            }
        }
        return candidate.flatMap { isVideoID($0) ? $0 : nil }
    }

    static func thumbnail(for videoID: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!
    }

    private static func isVideoID(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

struct VideoInfo: Decodable {
    let title: String
    let authorName: String

    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
    }

    /// Title and channel name via YouTube's public oEmbed endpoint.
    static func fetch(videoID: String) async throws -> VideoInfo {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(VideoInfo.self, from: data)
    }
}
