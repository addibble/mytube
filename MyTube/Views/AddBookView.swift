import SwiftUI

/// Creates an audiobook from a list of YouTube links, one part per link.
struct AddBookView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""
    @State private var links = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Book") {
                    TextField("Title", text: $title)
                    TextField("Author (optional)", text: $author)
                }
                Section {
                    TextEditor(text: $links)
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                } header: {
                    Text("YouTube Links")
                } footer: {
                    Text("One link per line, in listening order.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Audiobook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button("Add") { add() }
                            .disabled(links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func add() {
        let lines = links.split(whereSeparator: \.isWhitespace).map(String.init)
        var videoIDs: [String] = []
        for line in lines {
            guard let id = YouTubeURL.videoID(from: line) else {
                errorMessage = "Not a YouTube video link: \(line)"
                return
            }
            videoIDs.append(id)
        }

        errorMessage = nil
        isAdding = true
        Task {
            // Titles are a nicety; the book is still added if they can't be fetched.
            var infos: [VideoInfo?] = []
            for id in videoIDs {
                infos.append(try? await VideoInfo.fetch(videoID: id))
            }
            let parts = zip(videoIDs, infos).enumerated().map { index, pair in
                Part(videoID: pair.0, title: pair.1?.title ?? "Part \(index + 1)")
            }
            let enteredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            library.add(Audiobook(
                title: enteredTitle.isEmpty ? (infos.first??.title ?? "Untitled Audiobook") : enteredTitle,
                author: author.trimmingCharacters(in: .whitespacesAndNewlines),
                parts: parts
            ))
            dismiss()
        }
    }
}
