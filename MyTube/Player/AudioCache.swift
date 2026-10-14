import Foundation
import Network

/// The fragment layout of a YouTube audio-only file, read from its `sidx` box.
struct SegmentIndex: Codable {
    struct Segment: Codable {
        let offset: Int
        let size: Int
        let duration: Double
    }

    /// Bytes at the start of the file (ftyp + moov) that every fragment needs.
    let initLength: Int
    let segments: [Segment]
}

/// On-disk copy of the audio around the playhead for one video, so playback can start
/// without the network and ride out dead spots.
///
/// The cache holds the segment index, the init segment and whichever fragments have been
/// downloaded. It is kept across launches and only ever holds one video.
final class VideoCache: @unchecked Sendable {
    /// Seconds on each side of the playhead the prefetcher keeps downloaded.
    static let window: TimeInterval = 600
    /// Fragments further than this from the playhead are deleted.
    static let keepWindow: TimeInterval = 900

    let videoID: String
    let index: SegmentIndex

    private let directory: URL
    private let starts: [Double]
    private let lock = NSLock()
    private var cached: Set<Int>
    private var transcribed: Set<Int>

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioCache", isDirectory: true)
    }

    private init(videoID: String, index: SegmentIndex, directory: URL) {
        self.videoID = videoID
        self.index = index
        self.directory = directory
        var total = 0.0
        starts = index.segments.map { segment in
            defer { total += segment.duration }
            return total
        }
        var names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // Transcripts from before every recognition result was collected were cut short.
        for name in names where name.hasSuffix(".txt.json") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        names.removeAll { $0.hasSuffix(".txt.json") }
        cached = Set(names.compactMap { $0.hasSuffix(".m4s") ? Int($0.dropLast(4)) : nil })
        transcribed = Set(names.compactMap { $0.hasSuffix(".words.json") ? Int($0.dropLast(11)) : nil })
    }

    /// The cache left by an earlier run for this video, if it has everything needed to start from it.
    static func open(videoID: String) -> VideoCache? {
        let directory = root.appendingPathComponent(videoID, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode(SegmentIndex.self, from: data),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("init.mp4").path) else { return nil }
        removeAll(except: videoID)
        return VideoCache(videoID: videoID, index: index, directory: directory)
    }

    static func create(videoID: String, index: SegmentIndex, initData: Data) -> VideoCache? {
        removeAll(except: videoID)
        let directory = root.appendingPathComponent(videoID, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try initData.write(to: directory.appendingPathComponent("init.mp4"), options: .atomic)
            try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            return nil
        }
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
        return VideoCache(videoID: videoID, index: index, directory: directory)
    }

    private static func removeAll(except videoID: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name != videoID {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    // MARK: - Storage

    var initData: Data? {
        try? Data(contentsOf: directory.appendingPathComponent("init.mp4"))
    }

    func segmentData(_ segment: Int) -> Data? {
        guard lockedContains(segment) else { return nil }
        return try? Data(contentsOf: file(segment))
    }

    func store(_ data: Data, segment: Int) {
        guard (try? data.write(to: file(segment), options: .atomic)) != nil else { return }
        lock.lock()
        cached.insert(segment)
        lock.unlock()
    }

    private func file(_ segment: Int) -> URL {
        directory.appendingPathComponent("\(segment).m4s")
    }

    private func lockedContains(_ segment: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cached.contains(segment)
    }

    // MARK: - Windowing

    /// The fragment that contains `time`.
    func segment(at time: TimeInterval) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= time { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    /// The next stretch of contiguous, not yet downloaded fragments to fetch: ahead of the
    /// playhead first, then behind it.
    func nextMissing(around time: TimeInterval, maxRun: Int) -> ClosedRange<Int>? {
        guard !index.segments.isEmpty else { return nil }
        let current = segment(at: time)
        let last = segment(at: time + Self.window)
        let first = segment(at: time - Self.window)
        lock.lock()
        defer { lock.unlock() }

        if let start = (current...last).first(where: { !cached.contains($0) }) {
            var end = start
            while end < last, end - start + 1 < maxRun, !cached.contains(end + 1) { end += 1 }
            return start...end
        }
        if current > first, let end = (first..<current).last(where: { !cached.contains($0) }) {
            var start = end
            while start > first, end - start + 1 < maxRun, !cached.contains(start - 1) { start -= 1 }
            return start...end
        }
        return nil
    }

    /// Deletes fragments too far from the playhead to be worth their disk space.
    func trim(around time: TimeInterval) {
        let low = segment(at: time - Self.keepWindow)
        let high = segment(at: time + Self.keepWindow)
        lock.lock()
        let stale = cached.filter { $0 < low || $0 > high }
        cached.subtract(stale)
        lock.unlock()
        for segment in stale { try? FileManager.default.removeItem(at: file(segment)) }

        lock.lock()
        let staleChunks = transcribed.filter { chunk in
            let range = segments(inChunk: chunk)
            return range.upperBound < low || range.lowerBound > high
        }
        transcribed.subtract(staleChunks)
        lock.unlock()
        for chunk in staleChunks { try? FileManager.default.removeItem(at: transcriptFile(chunk)) }
    }

    // MARK: - Transcripts

    /// Speech is transcribed in groups of this many fragments, which keeps words from being cut mid-sentence.
    static let chunkSize = 6

    func chunk(at time: TimeInterval) -> Int {
        segment(at: time) / Self.chunkSize
    }

    func segments(inChunk chunk: Int) -> ClosedRange<Int> {
        (chunk * Self.chunkSize)...min((chunk + 1) * Self.chunkSize - 1, max(0, index.segments.count - 1))
    }

    func startTime(ofSegment segment: Int) -> TimeInterval {
        starts[segment]
    }

    func isCached(_ segments: ClosedRange<Int>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return segments.allSatisfy { cached.contains($0) }
    }

    /// The init segment followed by the given fragments: a playable file.
    func clipData(_ segments: ClosedRange<Int>) -> Data? {
        guard var data = initData else { return nil }
        for number in segments {
            guard let segment = segmentData(number) else { return nil }
            data.append(segment)
        }
        return data
    }

    func transcript(chunk: Int) -> [TimedWord]? {
        lock.lock()
        let has = transcribed.contains(chunk)
        lock.unlock()
        guard has, let data = try? Data(contentsOf: transcriptFile(chunk)) else { return nil }
        return try? JSONDecoder().decode([TimedWord].self, from: data)
    }

    func store(transcript: [TimedWord], chunk: Int) {
        guard let data = try? JSONEncoder().encode(transcript),
              (try? data.write(to: transcriptFile(chunk), options: .atomic)) != nil else { return }
        lock.lock()
        transcribed.insert(chunk)
        lock.unlock()
    }

    private func transcriptFile(_ chunk: Int) -> URL {
        directory.appendingPathComponent("\(chunk).words.json")
    }

    /// The first fully downloaded chunk near the playhead that has not been transcribed yet.
    func nextUntranscribedChunk(around time: TimeInterval, behind: TimeInterval, ahead: TimeInterval) -> Int? {
        guard !index.segments.isEmpty else { return nil }
        let last = chunk(at: time + ahead)
        return (chunk(at: time - behind)...last).first { chunk in
            lock.lock()
            let done = transcribed.contains(chunk)
            lock.unlock()
            return !done && isCached(segments(inChunk: chunk))
        }
    }

    /// Byte range in the source file covering consecutive fragments.
    func byteRange(of segments: ClosedRange<Int>) -> ClosedRange<Int> {
        let first = index.segments[segments.lowerBound]
        let last = index.segments[segments.upperBound]
        return first.offset...(last.offset + last.size - 1)
    }

    /// Downloads fragments from the live stream and stores them.
    func download(_ segments: ClosedRange<Int>, from url: URL) async throws {
        let range = byteRange(of: segments)
        let data = try await StreamResolver.fetch(url, bytes: range)
        guard data.count == range.count else { throw URLError(.badServerResponse) }
        for number in segments {
            let segment = index.segments[number]
            let start = data.startIndex + segment.offset - range.lowerBound
            store(data[start..<(start + segment.size)], segment: number)
        }
    }
}

/// Keeps the cache topped up around the playhead while the app has the stream's URL.
final class SegmentPrefetcher: @unchecked Sendable {
    private static let maxRun = 12

    private let cache: VideoCache
    private let remote: Task<ResolvedURL, Error>
    private let lock = NSLock()
    private var position: TimeInterval
    private var task: Task<Void, Never>?

    init(cache: VideoCache, remote: Task<ResolvedURL, Error>, position: TimeInterval) {
        self.cache = cache
        self.remote = remote
        self.position = position
    }

    /// Tells the prefetcher where playback is; starts a download pass if none is running.
    func update(position: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.position = position
        guard task == nil else { return }
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

    private func currentPosition() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return position
    }

    private func run() async {
        guard let url = try? await remote.value.url else { return }
        while !Task.isCancelled {
            let time = currentPosition()
            cache.trim(around: time)
            guard let segments = cache.nextMissing(around: time, maxRun: Self.maxRun) else { return }
            do {
                try await cache.download(segments, from: url)
            } catch {
                return
            }
        }
    }
}

/// Serves the playlist, init segment and fragments to AVPlayer from a loopback HTTP server
/// (AVPlayer won't take HLS media segments from a custom URL scheme), from disk when cached
/// and from the network (storing the result) otherwise.
final class SegmentServer: @unchecked Sendable {
    private let cache: VideoCache
    private let remote: Task<ResolvedURL, Error>
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SegmentServer")
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(cache: VideoCache, remote: Task<ResolvedURL, Error>) throws {
        self.cache = cache
        self.remote = remote
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening and returns the playlist's URL.
    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let port = listener.port?.rawValue, let url = URL(string: "http://127.0.0.1:\(port)/playlist.m3u8") {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        let running = lock.withLock { () -> [Task<Void, Never>] in
            defer { tasks = [:] }
            return Array(tasks.values)
        }
        running.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.lock.withLock { self?.tasks.removeValue(forKey: id)?.cancel() } }
        }
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                handle(request: String(decoding: buffer, as: UTF8.self), on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                receive(on: connection, buffered: buffer)
            }
        }
    }

    private func handle(request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(on: connection, status: "405 Method Not Allowed", type: "text/plain", body: Data())
            return
        }
        let name = String(parts[1].dropFirst())
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.flatMap(Self.parseRange)

        let id = ObjectIdentifier(connection)
        let task = Task { [self] in
            do {
                let (body, type) = try await resource(named: name)
                guard !Task.isCancelled else { return }
                if let range {
                    let start = min(range.start, body.count)
                    let end = min(range.end.map { $0 + 1 } ?? body.count, body.count)
                    let slice = body.subdata(in: (body.startIndex + start)..<(body.startIndex + max(start, end)))
                    respond(
                        on: connection, status: "206 Partial Content", type: type, body: slice,
                        extra: "Content-Range: bytes \(start)-\(max(start, end) - 1)/\(body.count)\r\n"
                    )
                } else {
                    respond(on: connection, status: "200 OK", type: type, body: body)
                }
            } catch {
                if !Task.isCancelled { respond(on: connection, status: "502 Bad Gateway", type: "text/plain", body: Data()) }
            }
        }
        lock.withLock { tasks[id] = task }
    }

    /// `Range: bytes=start-end` (end optional).
    private static func parseRange(_ header: String) -> (start: Int, end: Int?)? {
        guard let spec = header.split(separator: "=").last else { return nil }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, Int(bounds[1].trimmingCharacters(in: .whitespaces)))
    }

    private func respond(on connection: NWConnection, status: String, type: String, body: Data, extra: String = "") {
        var response = Data(
            ("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                + "Accept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n").utf8
        )
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func resource(named name: String) async throws -> (Data, type: String) {
        if name == "playlist.m3u8" {
            return (playlist(), "application/vnd.apple.mpegurl")
        }
        if name == "init.mp4" {
            if let data = cache.initData { return (data, "audio/mp4") }
            let url = try await remote.value.url
            return (try await StreamResolver.fetch(url, bytes: 0...(cache.index.initLength - 1)), "audio/mp4")
        }
        guard let number = Int(name.replacingOccurrences(of: ".m4s", with: "")),
              cache.index.segments.indices.contains(number) else { throw URLError(.badURL) }
        if let data = cache.segmentData(number) { return (data, "audio/mp4") }
        try await cache.download(number...number, from: try await remote.value.url)
        guard let data = cache.segmentData(number) else { throw URLError(.cannotCreateFile) }
        return (data, "audio/mp4")
    }

    /// An HLS media playlist whose fragments all come back through this server.
    private func playlist() -> Data {
        let segments = cache.index.segments
        let longest = segments.map(\.duration).max() ?? 1
        var text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init.mp4"

        """
        for (number, segment) in segments.enumerated() {
            text += "#EXTINF:\(String(format: "%.5f", segment.duration)),\n\(number).m4s\n"
        }
        return Data((text + "#EXT-X-ENDLIST\n").utf8)
    }
}
