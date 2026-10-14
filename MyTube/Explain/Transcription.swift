import Foundation
import Speech

extension VideoCache {
    /// Transcribes one chunk of downloaded audio and stores the result next to it.
    @discardableResult
    func transcribe(chunk: Int) async throws -> [TimedWord] {
        let range = segments(inChunk: chunk)
        guard let data = clipData(range) else { throw ExplainError.noAudio }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(videoID)-\(chunk).mp4")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let offset = startTime(ofSegment: range.lowerBound)
        let words = try await ClipTranscriber.words(in: url).map {
            TimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset)
        }
        store(transcript: words, chunk: chunk)
        return words
    }
}

/// Transcribes the audio around the playhead as it is listened to, so "Explain" already has the text.
/// Only runs while playing, and only with on-device recognition, to spare battery and quota.
final class TranscriptionWorker: @unchecked Sendable {
    /// Seconds before and after the playhead to keep transcribed.
    private static let behind: TimeInterval = 120
    private static let ahead: TimeInterval = 30

    private let cache: VideoCache
    private let lock = NSLock()
    private var position: TimeInterval
    private var task: Task<Void, Never>?

    init(cache: VideoCache, position: TimeInterval) {
        self.cache = cache
        self.position = position
    }

    func update(position: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.position = position
        guard task == nil, ClipTranscriber.supportsOnDevice else { return }
        task = Task { [self] in
            await run()
            lock.withLock { task = nil }
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    private func run() async {
        guard await ClipTranscriber.isAuthorized() else { return }
        while !Task.isCancelled {
            let time = lock.withLock { position }
            guard let chunk = cache.nextUntranscribedChunk(around: time, behind: Self.behind, ahead: Self.ahead) else { return }
            do {
                try await cache.transcribe(chunk: chunk)
            } catch {
                return
            }
        }
    }
}
