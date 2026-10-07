import Foundation

/// One YouTube video within an audiobook, with the listener's bookmark.
struct Part: Identifiable, Codable, Hashable {
    var id = UUID()
    var videoID: String
    var title: String
    /// Seconds. 0 until the part has been loaded once.
    var duration: TimeInterval = 0
    /// Bookmark: where playback last left off, in seconds.
    var position: TimeInterval = 0

    var isFinished: Bool { duration > 0 && position >= duration - 5 }
    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
}

struct Audiobook: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var author: String = ""
    var parts: [Part]
    var currentPartIndex = 0
    var lastPlayed: Date?

    var currentPart: Part? {
        parts.indices.contains(currentPartIndex) ? parts[currentPartIndex] : parts.first
    }

    /// Overall progress through the book, 0...1.
    var progress: Double {
        guard !parts.isEmpty else { return 0 }
        let index = min(currentPartIndex, parts.count - 1)
        if parts.allSatisfy({ $0.duration > 0 }) {
            let total = parts.reduce(0) { $0 + $1.duration }
            let before = parts[..<index].reduce(0) { $0 + $1.duration }
            return min(1, (before + parts[index].position) / total)
        }
        return (Double(index) + parts[index].progress) / Double(parts.count)
    }
}

extension TimeInterval {
    /// "1:02:03" or "2:03".
    var clockString: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(self)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
