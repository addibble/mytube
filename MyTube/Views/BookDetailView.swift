import SwiftUI

struct BookDetailView: View {
    let bookID: UUID

    @Environment(Library.self) private var library
    @Environment(PlayerEngine.self) private var player

    @State private var showingAddPart = false
    @State private var newPartLink = ""
    @State private var addPartError: String?

    var body: some View {
        if let book = library.book(bookID) {
            List {
                Section {
                    header(book)
                }
                .listRowSeparator(.hidden)

                Section("Parts") {
                    ForEach(book.parts) { part in
                        Button {
                            player.play(bookID: book.id, partID: part.id)
                        } label: {
                            PartRow(part: part, isCurrent: isCurrent(part, in: book))
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { book.parts[$0].id }
                        if player.bookID == book.id, let playing = player.partID, removed.contains(playing) {
                            player.stop()
                        }
                        editParts { $0.remove(atOffsets: offsets) }
                    }
                    .onMove { source, destination in
                        editParts { $0.move(fromOffsets: source, toOffset: destination) }
                    }
                }
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Add Part", systemImage: "plus") {
                        newPartLink = ""
                        showingAddPart = true
                    }
                    EditButton()
                }
            }
            .alert("Add Part", isPresented: $showingAddPart) {
                TextField("YouTube link", text: $newPartLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") { addPart() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't Add Part", isPresented: Binding(
                get: { addPartError != nil },
                set: { if !$0 { addPartError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(addPartError ?? "")
            }
        } else {
            ContentUnavailableView("Audiobook Removed", systemImage: "book.closed")
        }
    }

    private func header(_ book: Audiobook) -> some View {
        VStack(spacing: 12) {
            ArtworkView(videoID: book.currentPart?.videoID, cornerRadius: 12)
                .frame(width: 180, height: 180)
            Text(book.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if !book.author.isEmpty {
                Text(book.author)
                    .foregroundStyle(.secondary)
            }
            Button {
                isPlayingThisBook ? player.pause() : player.play(bookID: book.id)
            } label: {
                Label(playButtonTitle(book), systemImage: isPlayingThisBook ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(book.parts.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }

    private var isPlayingThisBook: Bool {
        player.bookID == bookID && player.isPlaying
    }

    private func playButtonTitle(_ book: Audiobook) -> String {
        if isPlayingThisBook { return "Pause" }
        guard let part = book.currentPart, book.lastPlayed != nil else { return "Play" }
        return "Resume at \(part.position.clockString)"
    }

    /// The part the book's bookmark points at.
    private func isCurrent(_ part: Part, in book: Audiobook) -> Bool {
        book.currentPart?.id == part.id
    }

    /// Edits the part list while keeping the bookmark on the same part.
    private func editParts(_ edit: (inout [Part]) -> Void) {
        library.update(bookID) { book in
            let currentID = book.currentPart?.id
            edit(&book.parts)
            book.currentPartIndex = book.parts.firstIndex { $0.id == currentID } ?? 0
        }
    }

    private func addPart() {
        guard let videoID = YouTubeURL.videoID(from: newPartLink) else {
            addPartError = "That doesn't look like a YouTube video link."
            return
        }
        Task {
            let count = library.book(bookID)?.parts.count ?? 0
            let title = (try? await VideoInfo.fetch(videoID: videoID))?.title ?? "Part \(count + 1)"
            editParts { $0.append(Part(videoID: videoID, title: title)) }
        }
    }
}

private struct PartRow: View {
    let part: Part
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(videoID: part.videoID, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(part.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(2)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if part.duration > 0 {
                    ProgressView(value: part.progress)
                }
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Current part")
            }
        }
        .contentShape(Rectangle())
    }

    private var status: String {
        if part.isFinished { return "Finished · \(part.duration.clockString)" }
        if part.duration > 0 { return "\(part.position.clockString) of \(part.duration.clockString)" }
        return "Not started"
    }
}
