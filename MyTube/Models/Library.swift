import Foundation
import Observation

/// The saved audiobooks and their bookmarks, persisted as JSON in Application Support.
@MainActor @Observable
final class Library {
    static let shared = Library()

    private(set) var books: [Audiobook] = []

    @ObservationIgnored private let fileURL: URL

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("library.json")

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Audiobook].self, from: data) {
            books = saved
        } else if !FileManager.default.fileExists(atPath: fileURL.path) {
            books = [Self.foucaultsPendulum]
            save()
        }
    }

    func book(_ id: UUID) -> Audiobook? {
        books.first { $0.id == id }
    }

    func add(_ book: Audiobook) {
        books.append(book)
        save()
    }

    /// The one-part book for a search result. Reuses the book made the last time the result was
    /// picked, so its bookmark is kept.
    func book(for result: SearchResult) -> Audiobook {
        if let existing = books.first(where: { $0.parts.map(\.videoID) == [result.videoID] }) { return existing }
        let book = Audiobook(
            title: result.title,
            author: result.channel,
            parts: [Part(videoID: result.videoID, title: result.title)]
        )
        add(book)
        return book
    }

    func remove(_ id: UUID) {
        books.removeAll { $0.id == id }
        save()
    }

    func update(_ id: UUID, _ mutate: (inout Audiobook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        mutate(&books[index])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Seeded on first launch.
    private static let foucaultsPendulum = Audiobook(
        title: "Foucault's Pendulum",
        author: "Umberto Eco",
        parts: [
            Part(videoID: "Scoyeq3NPoY", title: "Part 1"),
            Part(videoID: "xOOQhx_h8Ac", title: "Part 2"),
        ]
    )
}
