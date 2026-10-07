import SwiftUI

@main
struct MyTubeApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(Library.shared)
                .environment(PlayerEngine.shared)
                #if DEBUG
                .task {
                    // `-autoplay` starts the first book at launch, for testing without tapping.
                    if ProcessInfo.processInfo.arguments.contains("-autoplay"), let book = Library.shared.books.first {
                        PlayerEngine.shared.play(bookID: book.id)
                    }
                }
                #endif
        }
    }
}
