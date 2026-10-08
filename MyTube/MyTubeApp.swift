import SwiftUI

@main
struct MyTubeApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(Library.shared)
                .environment(PlayerEngine.shared)
                .environment(SearchModel.shared)
                #if DEBUG
                .task {
                    // `-autoplay` starts the first book at launch, for testing without tapping.
                    if ProcessInfo.processInfo.arguments.contains("-autoplay"), let book = Library.shared.books.first {
                        PlayerEngine.shared.play(bookID: book.id)
                    }
                    // `-search <term>` opens search results at launch, the way the Siri intents do.
                    if let term = UserDefaults.standard.string(forKey: "search") {
                        SearchModel.shared.search(term)
                    }
                }
                #endif
        }
    }
}
