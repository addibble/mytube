import Foundation
import YouTubeKit

struct ResolvedURL {
    let url: URL
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
    static func resolve(videoID: String) async throws -> ResolvedURL {
        let streams = try await YouTube(videoID: videoID, methods: [.local, .remote]).streams
        guard let stream = streams.filterAudioOnly().filter({ $0.isNativelyPlayable }).highestAudioBitrateStream() else {
            throw StreamError.noAudioStream
        }
        let url = stream.url

        let expireValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "expire" }?.value
        let expires = expireValue.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0 - 300) }
            ?? Date().addingTimeInterval(4 * 3600)
        return ResolvedURL(url: url, expires: expires)
    }

    /// Reads the fragment layout from the file's `sidx` segment index.
    ///
    /// YouTube's audio-only files are fragmented MP4s. AVPlayer can't start or seek a
    /// many-hour one over HTTP in reasonable time, so the fragments are described to it
    /// as HLS (and cached on disk) instead.
    static func segmentIndex(for url: URL) async throws -> (index: SegmentIndex, initData: Data) {
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
                let index = segmentIndex(data: data, sidxOffset: offset, sidxSize: size)
                return (index, data.subdata(in: data.startIndex..<(data.startIndex + offset)))
            }
            offset += size
        }
        throw StreamError.noAudioStream
    }

    private static func segmentIndex(data: Data, sidxOffset: Int, sidxSize: Int) -> SegmentIndex {
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

        var segmentOffset = sidxOffset + sidxSize + firstOffset
        var segments: [SegmentIndex.Segment] = []
        for _ in 0..<count {
            let size = data.uint32(at: cursor) & 0x7FFF_FFFF
            let duration = Double(data.uint32(at: cursor + 4)) / timescale
            cursor += 12
            segments.append(.init(offset: segmentOffset, size: size, duration: duration))
            segmentOffset += size
        }
        return SegmentIndex(initLength: sidxOffset, segments: segments)
    }

    static func fetch(_ url: URL, bytes: ClosedRange<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(bytes.lowerBound)-\(bytes.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 206 else { throw URLError(.badServerResponse) }
        return data
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
