import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerEngine.self) private var player

    @State private var showingAddBook = false
    @State private var showingPlayer = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.books) { book in
                    NavigationLink(value: book.id) {
                        BookRow(book: book)
                    }
                }
                .onDelete { offsets in
                    for id in offsets.map({ library.books[$0].id }) {
                        if player.bookID == id { player.stop() }
                        library.remove(id)
                    }
                }
            }
            .overlay {
                if library.books.isEmpty {
                    ContentUnavailableView(
                        "No Audiobooks",
                        systemImage: "books.vertical",
                        description: Text("Tap + to make one from YouTube links.")
                    )
                }
            }
            .navigationTitle("Audiobooks")
            .navigationDestination(for: UUID.self) { BookDetailView(bookID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { skipSettingsMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Audiobook", systemImage: "plus") { showingAddBook = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentPart != nil {
                MiniPlayerView { showingPlayer = true }
            }
        }
        .sheet(isPresented: $showingAddBook) { AddBookView() }
        .sheet(isPresented: $showingPlayer) { PlayerView() }
    }

    private var skipSettingsMenu: some View {
        Menu("Settings", systemImage: "gearshape") {
            Section("Lock Screen & CarPlay Buttons") {
                Picker("Skip Back", systemImage: "gobackward", selection: Binding(
                    get: { player.skipBackInterval },
                    set: { player.setSkipIntervals(back: $0, forward: player.skipForwardInterval) }
                )) {
                    ForEach(PlayerEngine.skipChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Skip Forward", systemImage: "goforward", selection: Binding(
                    get: { player.skipForwardInterval },
                    set: { player.setSkipIntervals(back: player.skipBackInterval, forward: $0) }
                )) {
                    ForEach(PlayerEngine.skipChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }
}

private struct BookRow: View {
    let book: Audiobook

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(videoID: book.currentPart?.videoID)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: book.progress)
            }
        }
        .padding(.vertical, 4)
    }
}
