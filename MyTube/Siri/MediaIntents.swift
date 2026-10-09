import Intents
import UIKit

/// "Play Dune on MyTube" and "Search for Dune on MyTube". SiriKit's media intents carry the spoken
/// title through, which App Shortcut phrases can't, and are handled in the app rather than an extension.
final class MediaIntentHandler: NSObject, INPlayMediaIntentHandling, INSearchForMediaIntentHandling {
    private enum Prefix {
        static let book = "book:"
        static let video = "video:"
    }

    // MARK: - Play

    /// A book already in the library wins; otherwise the top YouTube result. No title resumes the last book.
    @MainActor
    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        guard let term = intent.mediaSearch?.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !term.isEmpty else {
            guard let book = PlayerEngine.shared.currentBook ?? Library.shared.books.first else {
                return [.unsupported(forReason: .unsupportedMediaType)]
            }
            return [.success(with: item(for: book))]
        }
        if let book = Library.shared.books.first(where: { $0.title.localizedCaseInsensitiveContains(term) }) {
            return [.success(with: item(for: book))]
        }
        do {
            guard let result = try await YouTubeSearch.videos(matching: term).first else {
                return [.unsupported()]
            }
            // Added to the library now, so `handle` only has to look the book up.
            return [.success(with: item(for: Library.shared.book(for: result)))]
        } catch {
            return [.unsupported(forReason: .serviceUnavailable)]
        }
    }

    @MainActor
    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        guard let identifier = intent.mediaItems?.first?.identifier, identifier.hasPrefix(Prefix.book),
              let bookID = UUID(uuidString: String(identifier.dropFirst(Prefix.book.count))),
              Library.shared.book(bookID) != nil else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
        PlayerEngine.shared.play(bookID: bookID)
        return INPlayMediaIntentResponse(code: .success, userActivity: nil)
    }

    // MARK: - Search

    @MainActor
    func handle(intent: INSearchForMediaIntent) async -> INSearchForMediaIntentResponse {
        SearchModel.shared.search(intent.mediaSearch?.mediaName ?? "")
        // The search screen is up by the time Siri brings the app forward.
        return INSearchForMediaIntentResponse(code: .continueInApp, userActivity: nil)
    }

    private func item(for book: Audiobook) -> INMediaItem {
        INMediaItem(
            identifier: Prefix.book + book.id.uuidString,
            title: book.title,
            type: .audioBook,
            artwork: nil,
            artist: book.author.isEmpty ? nil : book.author
        )
    }
}

/// Hands Siri's media intents to `MediaIntentHandler`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Siri won't route "Play … on MyTube" here until the listener allows it.
        INPreferences.requestSiriAuthorization { _ in }
        return true
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent || intent is INSearchForMediaIntent ? MediaIntentHandler() : nil
    }
}
