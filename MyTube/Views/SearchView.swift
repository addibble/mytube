import SwiftUI

/// YouTube search. Tapping a result adds it to the library as a one-part audiobook and plays it.
struct SearchView: View {
    @Environment(Library.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(SearchModel.self) private var search
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(search.results) { result in
                Button {
                    play(result)
                } label: {
                    ResultRow(result: result)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if search.isSearching {
                    ProgressView()
                } else if let error = search.errorMessage {
                    ContentUnavailableView(
                        "Search Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if search.results.isEmpty {
                    if search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView(
                            "Search YouTube",
                            systemImage: "magnifyingglass",
                            description: Text("Or ask Siri: “Search for … on MyTube”")
                        )
                    } else {
                        ContentUnavailableView.search(text: search.query)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: Binding(get: { search.query }, set: { search.query = $0 }),
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search YouTube"
            )
            .onSubmit(of: .search) { search.search() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func play(_ result: SearchResult) {
        player.play(bookID: library.book(for: result).id)
        dismiss()
    }
}

private struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(videoID: result.videoID, cornerRadius: 6)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(2)
                Text([result.channel, result.length].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
