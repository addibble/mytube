import AVFoundation
import Foundation
import YouTubeKit

struct ResolvedStream {
    enum Source {
        /// A synthesized HLS media playlist, served to AVPlayer through `PlaylistLoader`.
        case hls(Data)
        case direct(URL)
    }

    let source: Source
    /// YouTube stream URLs are signed and stop working after a few hours.
    let expires: Date
}

enum StreamError: LocalizedError {
    case noAudioStream

    var errorDescription: String? {
        "No playable audio stream was found for this video."
    }
}

enum StreamResolver {
    static func resolve(videoID: String) async throws -> ResolvedStream {
        let streams = try await YouTube(videoID: videoID, methods: [.local, .remote]).streams
        guard let stream = streams.filterAudioOnly().filter({ $0.isNativelyPlayable }).highestAudioBitrateStream() else {
            throw StreamError.noAudioStream
        }
        let url = stream.url

        let expireValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "expire" }?.value
        let expires = expireValue.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0 - 300) }
            ?? Date().addingTimeInterval(4 * 3600)

        // YouTube's audio-only files are fragmented MP4s. AVPlayer can't start or seek a
        // many-hour one over HTTP in reasonable time, so describe the fragments to it as HLS.
        if let playlist = try? await hlsPlaylist(for: url) {
            return ResolvedStream(source: .hls(playlist), expires: expires)
        }
        return ResolvedStream(source: .direct(url), expires: expires)
    }

    /// Builds an HLS byte-range playlist from the file's `sidx` segment index.
    private static func hlsPlaylist(for url: URL) async throws -> Data {
        var data = try await fetch(url, bytes: 0...131_071)
        var offset = 0
        while offset + 32 <= data.count {
            var size = data.uint32(at: offset)
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if size == 1 { size = data.uint64(at: offset + 8) }
            guard size >= 8 else { break }

            if type == "sidx" {
                if offset + size > data.count {
                    data.append(try await fetch(url, bytes: data.count...(offset + size - 1)))
                }
                guard offset + size <= data.count else { break }
                return playlist(url: url, data: data, sidxOffset: offset, sidxSize: size)
            }
            offset += size
        }
        throw StreamError.noAudioStream
    }

    private static func playlist(url: URL, data: Data, sidxOffset: Int, sidxSize: Int) -> Data {
        let version = data[sidxOffset + 8]
        let timescale = Double(max(1, data.uint32(at: sidxOffset + 16)))
        var cursor = sidxOffset + 20
        let firstOffset: Int
        if version == 0 {
            firstOffset = data.uint32(at: cursor + 4)
            cursor += 8
        } else {
            firstOffset = data.uint64(at: cursor + 8)
            cursor += 16
        }
        let count = data.uint32(at: cursor) & 0xFFFF
        cursor += 4

        let link = url.absoluteString
        var segmentOffset = sidxOffset + sidxSize + firstOffset
        var longest = 0.0
        var segments = ""
        for _ in 0..<count {
            let size = data.uint32(at: cursor) & 0x7FFF_FFFF
            let duration = Double(data.uint32(at: cursor + 4)) / timescale
            cursor += 12
            longest = max(longest, duration)
            segments += "#EXTINF:\(String(format: "%.5f", duration)),\n#EXT-X-BYTERANGE:\(size)@\(segmentOffset)\n\(link)\n"
            segmentOffset += size
        }

        let header = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="\(link)",BYTERANGE="\(sidxOffset)@0"

        """
        return Data((header + segments + "#EXT-X-ENDLIST\n").utf8)
    }

    private static func fetch(_ url: URL, bytes: ClosedRange<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(bytes.lowerBound)-\(bytes.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 206 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Hands a synthesized playlist to AVPlayer under a custom URL scheme.
final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let url = URL(string: "mytube-hls://playlist/audio.m3u8")!

    private let playlist: Data

    init(playlist: Data) {
        self.playlist = playlist
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        loadingRequest.contentInformationRequest?.contentType = "public.m3u-playlist"
        loadingRequest.contentInformationRequest?.contentLength = Int64(playlist.count)
        loadingRequest.dataRequest?.respond(with: playlist)
        loadingRequest.finishLoading()
        return true
    }
}

private extension Data {
    func uint32(at offset: Int) -> Int {
        let i = startIndex + offset
        return Int(self[i]) << 24 | Int(self[i + 1]) << 16 | Int(self[i + 2]) << 8 | Int(self[i + 3])
    }

    func uint64(at offset: Int) -> Int {
        uint32(at: offset) << 32 | uint32(at: offset + 4)
    }
}
