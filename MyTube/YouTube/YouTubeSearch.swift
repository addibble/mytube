import Foundation
import Observation

/// A video found by searching YouTube.
struct SearchResult: Identifiable, Hashable {
    let videoID: String
    let title: String
    let channel: String
    /// As YouTube displays it, e.g. "6:20:18". Empty for live streams.
    let length: String

    var id: String { videoID }
}

enum YouTubeSearch {
    /// Videos matching a query, from the same endpoint youtube.com's own search page uses.
    static func videos(matching query: String) async throws -> [SearchResult] {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20250101.00.00", "hl": "en"]],
            "query": query,
            // Videos only: no channels, playlists or shorts shelves.
            "params": "EgIQAQ==",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        var results: [SearchResult] = []
        collect(from: try JSONSerialization.jsonObject(with: data), into: &results)
        return results
    }

    /// The response nests results several renderers deep, so walk it for `videoRenderer` entries.
    private static func collect(from json: Any, into results: inout [SearchResult]) {
        if let array = json as? [Any] {
            for element in array { collect(from: element, into: &results) }
        } else if let object = json as? [String: Any] {
            if let video = object["videoRenderer"] as? [String: Any] {
                guard let videoID = video["videoId"] as? String, let title = text(video["title"]),
                      !results.contains(where: { $0.videoID == videoID }) else { return }
                results.append(SearchResult(
                    videoID: videoID,
                    title: title,
                    channel: text(video["ownerText"]) ?? "",
                    length: text(video["lengthText"]) ?? ""
                ))
            } else {
                for value in object.values { collect(from: value, into: &results) }
            }
        }
    }

    /// YouTube text is either `{"simpleText": …}` or `{"runs": [{"text": …}, …]}`.
    private static func text(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        let simple = object["simpleText"] as? String
        let runs = (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        return (simple ?? runs)?.trimmingCharacters(in: .whitespaces)
    }
}

/// The current YouTube search, shared by the search screen and Siri.
@MainActor @Observable
final class SearchModel {
    static let shared = SearchModel()

    var query = ""
    /// Whether the search screen is showing. Siri sets this to bring it up.
    var isPresented = false
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {}

    /// Shows the search screen with results for `term`.
    func search(_ term: String) {
        query = term
        isPresented = true
        search()
    }

    /// Searches for the current `query`.
    func search() {
        task?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        task = Task {
            do {
                let found = try await YouTubeSearch.videos(matching: term)
                guard !Task.isCancelled else { return }
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}
