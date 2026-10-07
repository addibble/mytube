import SwiftUI

struct PlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .presentationDragIndicator(.hidden)
        .onChange(of: player.bookID) { _, bookID in
            if bookID == nil { dismiss() }
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
