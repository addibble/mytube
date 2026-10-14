import SwiftUI

struct PlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(ExplainModel.self) private var explain

    /// Position under the finger while the scrubber is being dragged.
    @State private var scrubTime: TimeInterval?

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            ArtworkView(videoID: player.currentPart?.videoID, cornerRadius: 16)
                .padding(.horizontal, 24)
                .shadow(radius: 12, y: 6)

            VStack(spacing: 4) {
                Text(player.currentPart?.title ?? "")
                    .font(.title3.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(player.currentBook?.title ?? "")
                    .foregroundStyle(.secondary)
            }

            scrubber

            if let error = player.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            transport

            HStack {
                Button("Previous Part", systemImage: "backward.end.fill") { player.changePart(by: -1) }
                    .disabled(!canChangePart(by: -1))
                Spacer()
                rateMenu
                Spacer()
                Button("Next Part", systemImage: "forward.end.fill") { player.changePart(by: 1) }
                    .disabled(!canChangePart(by: 1))
            }
            .labelStyle(.iconOnly)
            .font(.title3)

            explainSection

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .sheet(isPresented: Binding(
            get: { explain.showsConversation },
            set: { if !$0 { explain.dismiss() } }
        )) { ExplainConversationView() }
        .presentationDragIndicator(.hidden)
        .onChange(of: player.bookID) { _, bookID in
            if bookID == nil { dismiss() }
        }
    }

    private var explainSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Explain by Voice", systemImage: "speaker.wave.2.bubble") { explain.explain(.audio) }
                Button("Explain in Text", systemImage: "text.bubble") { explain.explain(.text) }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
            .disabled(explain.isBusy || player.currentPart == nil)

            switch explain.state {
            case .working(let status):
                HStack {
                    ProgressView()
                    Text(status).foregroundStyle(.secondary)
                    Button("Cancel") { explain.cancel() }
                }
                .font(.footnote)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            default:
                EmptyView()
            }
        }
    }

    private var scrubber: some View {
        let shown = scrubTime ?? player.currentTime
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { shown }, set: { scrubTime = $0 }),
                in: 0...max(player.duration, 1)
            ) { editing in
                if !editing, let scrubTime {
                    player.seek(to: scrubTime)
                    self.scrubTime = nil
                }
            }
            .disabled(player.duration <= 0)
            .accessibilityLabel("Position")
            .accessibilityValue(shown.clockString)

            HStack {
                Text(shown.clockString)
                Spacer()
                Text(player.duration > 0 ? "-" + (player.duration - shown).clockString : "--:--")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack {
            skipButton(-30)
            Spacer()
            skipButton(-15)
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72))
                        .opacity(player.isLoading ? 0.3 : 1)
                    if player.isLoading { ProgressView().controlSize(.large) }
                }
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            skipButton(15)
            Spacer()
            skipButton(30)
        }
    }

    private func skipButton(_ seconds: Int) -> some View {
        Button {
            player.skip(TimeInterval(seconds))
        } label: {
            Image(systemName: "\(seconds < 0 ? "gobackward" : "goforward").\(abs(seconds))")
                .font(.system(size: 32))
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Skip \(seconds < 0 ? "back" : "forward") \(abs(seconds)) seconds")
    }

    private var rateMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(PlayerEngine.rates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text(Self.rateLabel(player.rate))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .accessibilityLabel("Playback speed")
    }

    private static func rateLabel(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func canChangePart(by offset: Int) -> Bool {
        guard let book = player.currentBook,
              let index = book.parts.firstIndex(where: { $0.id == player.partID }) else { return false }
        return book.parts.indices.contains(index + offset)
    }
}

/// Compact now-playing bar pinned above the bottom of the library.
struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onExpand) {
                HStack(spacing: 12) {
                    ArtworkView(videoID: player.currentPart?.videoID, cornerRadius: 6)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentBook?.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player")

            Button {
                player.skip(-TimeInterval(player.skipBackInterval))
            } label: {
                Image(systemName: "gobackward.\(player.skipBackInterval)")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Skip back \(player.skipBackInterval) seconds")

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var subtitle: String {
        if let error = player.errorMessage { return error }
        let part = player.currentPart?.title ?? ""
        return "\(part) · \(player.currentTime.clockString)"
    }
}

/// The written explanation and follow-up questions, with a way back into the book.
struct ExplainConversationView: View {
    @Environment(ExplainModel.self) private var explain
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(explain.messages.filter { !$0.isContext }) { message in
                            bubble(message).id(message.id)
                        }
                        status
                            .id("status")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: explain.messages) { scrollToEnd(proxy) }
                .onChange(of: explain.state) { scrollToEnd(proxy) }
            }
            .navigationTitle("Explanation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Resume", systemImage: "play.fill") {
                        player.resume()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .assistant:
            Text(message.text)
                .textSelection(.enabled)
        case .user:
            Text(message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch explain.state {
        case .working(let text):
            HStack {
                ProgressView()
                Text(text).foregroundStyle(.secondary)
                Button("Stop") { explain.cancel() }
            }
            .font(.footnote)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask a follow-up", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(send)
            Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .font(.title)
                .disabled(explain.isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        guard !explain.isBusy else { return }
        explain.followUp(draft)
        draft = ""
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("status", anchor: .bottom) }
    }
}
