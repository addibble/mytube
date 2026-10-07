import UIKit

/// Square cover images made from YouTube thumbnails, shared by the app UI, lock screen and CarPlay.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private var images: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func cached(_ videoID: String) -> UIImage? {
        images[videoID]
    }

    func image(for videoID: String) async -> UIImage? {
        if let image = images[videoID] { return image }
        if let task = inFlight[videoID] { return await task.value }

        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: YouTubeURL.thumbnail(for: videoID)),
                  let image = UIImage(data: data) else { return nil }
            return Self.squareCrop(image)
        }
        inFlight[videoID] = task
        let image = await task.value
        inFlight[videoID] = nil
        images[videoID] = image
        return image
    }

    /// The thumbnail is a 16:9 frame letterboxed into 4:3; crop the centre square of the frame.
    private nonisolated static func squareCrop(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let side = min(CGFloat(cgImage.width) * 9 / 16, CGFloat(cgImage.height))
        let rect = CGRect(
            x: (CGFloat(cgImage.width) - side) / 2,
            y: (CGFloat(cgImage.height) - side) / 2,
            width: side,
            height: side
        ).integral
        return cgImage.cropping(to: rect).map { UIImage(cgImage: $0) } ?? image
    }
}
