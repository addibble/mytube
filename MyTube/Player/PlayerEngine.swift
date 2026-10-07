import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays audiobook parts and keeps their bookmarks, the lock screen and CarPlay in sync.
@MainActor @Observable
final class PlayerEngine {
    static let shared = PlayerEngine()

    static let rates: [Float] = [0.8, 1, 1.25, 1.5, 1.75, 2]
    static let skipChoices = [15, 30]

    private(set) var bookID: UUID?
    private(set) var partID: UUID?
    /// Whether the listener wants audio playing; stays true while a stream loads or buffers.
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private(set) var rate: Float = 1
    /// Seconds skipped by the lock screen and CarPlay transport buttons.
    private(set) var skipBackInterval = 15
    private(set) var skipForwardInterval = 30

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let library = Library.shared
    @ObservationIgnored private var playlistLoader: PlaylistLoader?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var streamExpiry = Date.distantFuture
    @ObservationIgnored private var lastPersist = Date.distantPast
    @ObservationIgnored private var pendingSeeks = 0
    @ObservationIgnored private var recentFailures: [Date] = []
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var artwork: (videoID: String, item: MPMediaItemArtwork)?

    private enum Keys {
        static let rate = "playbackRate"
        static let skipBack = "skipBackInterval"
        static let skipForward = "skipForwardInterval"
    }

    private init() {
        let defaults = UserDefaults.standard
        rate = defaults.object(forKey: Keys.rate) as? Float ?? 1
        skipBackInterval = defaults.object(forKey: Keys.skipBack) as? Int ?? 15
        skipForwardInterval = defaults.object(forKey: Keys.skipForward) as? Int ?? 30

        // Pick up the most recent book so Play on the lock screen or in CarPlay resumes it.
        let lastBook = library.books
            .filter { $0.lastPlayed != nil }
            .max { $0.lastPlayed! < $1.lastPlayed! }
        if let lastBook, let part = lastBook.currentPart {
            bookID = lastBook.id
            partID = part.id
            currentTime = part.position
            duration = part.duration
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        observePlayer()
        observeSystem()
        configureRemoteCommands()
    }

    var currentBook: Audiobook? {
        bookID.flatMap { library.book($0) }
    }

    var currentPart: Part? {
        currentBook?.parts.first { $0.id == partID }
    }

    // MARK: - Transport

    /// Plays a book from its bookmark, or a specific part from that part's bookmark.
    func play(bookID: UUID, partID: UUID? = nil) {
        guard let book = library.book(bookID),
              let part = book.parts.first(where: { $0.id == partID }) ?? book.currentPart else { return }
        if self.bookID == bookID, self.partID == part.id {
            resume()
        } else {
            load(bookID: bookID, part: part, at: part.isFinished ? 0 : part.position, autoplay: true)
        }
    }

    func resume() {
        guard bookID != nil else { return }
        isPlaying = true
        if isLoading { return }
        guard let item = player.currentItem, item.status == .readyToPlay, Date() < streamExpiry else {
            reload()
            return
        }
        if duration > 0, currentTime >= duration - 1 { seek(to: 0) }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.rate = rate
        updateNowPlaying()
    }

    func pause() {
        isPlaying = false
        player.pause()
        persist()
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func skip(_ seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func seek(to time: TimeInterval) {
        guard bookID != nil else { return }
        let end = duration > 0 ? max(0, duration - 1) : .greatestFiniteMagnitude
        let target = min(max(0, time), end)
        currentTime = target
        persist()

        // Without a loaded stream the new position is simply where the next load starts.
        guard !isLoading, let item = player.currentItem, item.status == .readyToPlay else {
            updateNowPlaying()
            return
        }
        pendingSeeks += 1
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSeeks -= 1
                self.updateNowPlaying()
            }
        }
    }

    /// Moves to the next (+1) or previous (-1) part of the current book.
    func changePart(by offset: Int) {
        guard let book = currentBook, let index = book.parts.firstIndex(where: { $0.id == partID }),
              book.parts.indices.contains(index + offset) else { return }
        let part = book.parts[index + offset]
        load(bookID: book.id, part: part, at: part.isFinished ? 0 : part.position, autoplay: isPlaying)
    }

    func stop() {
        persist()
        loadTask?.cancel()
        removeItem()
        isPlaying = false
        isLoading = false
        bookID = nil
        partID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        UserDefaults.standard.set(newRate, forKey: Keys.rate)
        if player.rate != 0 { player.rate = newRate }
        updateNowPlaying()
    }

    func setSkipIntervals(back: Int, forward: Int) {
        skipBackInterval = back
        skipForwardInterval = forward
        UserDefaults.standard.set(back, forKey: Keys.skipBack)
        UserDefaults.standard.set(forward, forKey: Keys.skipForward)
        applySkipIntervals()
    }

    // MARK: - Loading

    private func load(bookID: UUID, part: Part, at position: TimeInterval, autoplay: Bool) {
        persist()
        loadTask?.cancel()
        removeItem()

        self.bookID = bookID
        partID = part.id
        currentTime = position
        duration = part.duration
        isPlaying = autoplay
        isLoading = true
        errorMessage = nil
        persist()

        if autoplay { try? AVAudioSession.sharedInstance().setActive(true) }
        updateNowPlaying()
        loadArtwork(for: part.videoID)

        let videoID = part.videoID
        loadTask = Task { [weak self] in
            do {
                let stream = try await StreamResolver.resolve(videoID: videoID)
                guard !Task.isCancelled else { return }
                self?.install(stream)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    /// Fetches a fresh stream for the current part and carries on from the current position.
    private func reload() {
        guard let bookID, let part = currentPart else { return }
        load(bookID: bookID, part: part, at: currentTime, autoplay: isPlaying)
    }

    private func install(_ stream: ResolvedStream) {
        let asset: AVURLAsset
        switch stream.source {
        case .hls(let playlist):
            let loader = PlaylistLoader(playlist: playlist)
            playlistLoader = loader
            asset = AVURLAsset(url: PlaylistLoader.url)
            asset.resourceLoader.setDelegate(loader, queue: .main)
        case .direct(let url):
            asset = AVURLAsset(url: url)
        }
        streamExpiry = stream.expires

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in self?.statusChanged(of: item) }
        }
        player.replaceCurrentItem(with: item)
    }

    private func statusChanged(of item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay where isLoading:
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
            if duration > 0, currentTime >= duration - 1 { currentTime = 0 }

            let start = currentTime
            let cmTime = CMTime(seconds: start, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, item === self.player.currentItem else { return }
                    self.isLoading = false
                    // The listener may have skipped while the stream was loading.
                    if abs(self.currentTime - start) > 1 { self.seek(to: self.currentTime) }
                    if self.isPlaying { self.player.rate = self.rate }
                    self.persist()
                    self.updateNowPlaying()
                }
            }
        case .failed:
            recover(from: item.error)
        default:
            break
        }
    }

    private func removeItem() {
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        playlistLoader = nil
    }

    /// Stream URLs expire and connections drop; retry with a fresh stream before giving up.
    private func recover(from error: Error?) {
        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentFailures.count <= 2 {
            reload()
        } else {
            fail(error ?? URLError(.unknown))
        }
    }

    private func fail(_ error: Error) {
        removeItem()
        isLoading = false
        isPlaying = false
        errorMessage = error.localizedDescription
        updateNowPlaying()
    }

    private func partDidEnd() {
        guard let book = currentBook, let index = book.parts.firstIndex(where: { $0.id == partID }) else { return }
        currentTime = duration
        persist()
        if book.parts.indices.contains(index + 1) {
            let next = book.parts[index + 1]
            load(bookID: book.id, part: next, at: next.isFinished ? 0 : next.position, autoplay: true)
        } else {
            isPlaying = false
            updateNowPlaying()
        }
    }

    // MARK: - Bookmarking

    private func tick(_ time: TimeInterval) {
        guard !isLoading, pendingSeeks == 0, time.isFinite, player.currentItem?.status == .readyToPlay else { return }
        currentTime = time
        guard isPlaying else { return }
        if Date().timeIntervalSince(lastPersist) >= 5 { persist() }
        if Date() >= streamExpiry { reload() }
    }

    private func persist() {
        guard let bookID, let partID else { return }
        lastPersist = Date()
        let (position, duration) = (currentTime, duration)
        library.update(bookID) { book in
            guard let index = book.parts.firstIndex(where: { $0.id == partID }) else { return }
            book.parts[index].position = position
            if duration > 0 { book.parts[index].duration = duration }
            book.currentPartIndex = index
            book.lastPlayed = Date()
        }
    }

    // MARK: - Observation

    private func observePlayer() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        timeControlObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem != nil else { return }
                self.updateNowPlaying()
            }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.partDidEnd()
            }
        }
        center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.recover(from: error)
            }
        }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.resumeAfterInterruption = self.isPlaying
                    if self.isPlaying { self.pause() }
                case .ended:
                    if self.resumeAfterInterruption, options.contains(.shouldResume) { self.resume() }
                    self.resumeAfterInterruption = false
                default:
                    break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones unplugged or the car disconnected.
                if reason == .oldDeviceUnavailable, self?.isPlaying == true { self?.pause() }
            }
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persist() }
            }
        }
    }

    // MARK: - Lock screen & CarPlay

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        commands.skipBackwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            self.skip(-((event as? MPSkipIntervalCommandEvent)?.interval ?? TimeInterval(self.skipBackInterval)))
            return .success
        }
        commands.skipForwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            self.skip((event as? MPSkipIntervalCommandEvent)?.interval ?? TimeInterval(self.skipForwardInterval))
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
        commands.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        commands.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self?.setRate(event.playbackRate)
            return .success
        }
        // Skip buttons replace track buttons on the lock screen and in CarPlay.
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        applySkipIntervals()
    }

    private func applySkipIntervals() {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackInterval)]
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
    }

    private func updateNowPlaying() {
        guard let book = currentBook, let part = currentPart else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: part.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author.isEmpty ? book.title : "\(book.title) · \(book.author)",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artwork.videoID == part.videoID { info[MPMediaItemPropertyArtwork] = artwork.item }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for videoID: String) {
        guard artwork?.videoID != videoID else { return }
        Task {
            guard let image = await ArtworkCache.shared.image(for: videoID) else { return }
            artwork = (videoID, Self.makeArtwork(image))
            if currentPart?.videoID == videoID { updateNowPlaying() }
        }
    }

    /// MediaPlayer calls the artwork handler off the main thread, so it must not be main-actor isolated.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
