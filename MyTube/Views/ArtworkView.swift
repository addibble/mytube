import SwiftUI

/// Square cover art for a video, loaded through the shared artwork cache.
struct ArtworkView: View {
    let videoID: String?
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: videoID) {
            image = nil
            if let videoID { image = await ArtworkCache.shared.image(for: videoID) }
        }
    }
}
