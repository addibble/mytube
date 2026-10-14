import AVFoundation
import Observation
import Speech

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
    /// The opening prompt with the transcribed passage, which isn't shown in the thread.
    var isContext = false
}

/// "Explain this": transcribes the last minute of the book, asks the chosen model about it, then
/// shows or speaks the answer and takes follow-up questions: typed after a text explanation,
/// spoken after a voice one. Works from the phone and from CarPlay.
@MainActor @Observable
final class ExplainModel {
    static let shared = ExplainModel()

    enum Mode { case text, audio }

    enum State: Equatable {
        case idle
        case working(String)
        case answer(String, id: Int)
        case failed(String)
    }

    static let clipSeconds: TimeInterval = 60

    private(set) var state = State.idle
    private(set) var messages: [ChatMessage] = []
    /// Whether the written conversation is on screen.
    var showsConversation = false

    @ObservationIgnored private var mode = Mode.text
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var answerCount = 0
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private let mic = MicListener()

    var isBusy: Bool {
        if case .working = state { return true }
        return false
    }

    func explain(_ mode: Mode) {
        guard !isBusy else { return }
        let player = PlayerEngine.shared
        guard let book = player.currentBook, player.currentPart != nil else { return }
        let wasPlaying = player.isPlaying
        let time = player.currentTime
        player.pause()

        self.mode = mode
        messages = []
        showsConversation = false
        state = .working("Listening back…")
        if mode == .audio { speaker.say("One moment.") }
        task = Task {
            var finished = false
            do {
                let transcript = try await player.recentTranscript(seconds: Self.clipSeconds)
                messages = [ChatMessage(role: .user, text: Self.prompt(book: book, time: time, transcript: transcript), isContext: true)]
                try await respond(extraSpeech: mode == .audio ? " Ask a follow-up if you like." : "")
                if mode == .audio {
                    try await voiceFollowUps()
                    state = .idle
                }
                finished = true
            } catch is CancellationError {
                rollBackPendingQuestion()
                state = .idle
            } catch {
                speaker.stop()
                rollBackPendingQuestion()
                state = .failed(error.localizedDescription)
                if mode == .audio {
                    await speaker.speak("Sorry, I couldn't explain that. \(error.localizedDescription)")
                    finished = true
                }
            }
            if mode == .audio {
                messages = []
                player.restorePlaybackSession()
                if finished, wasPlaying { player.resume() }
            }
        }
    }

    /// Asks a typed follow-up after a text explanation.
    func followUp(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .text, !isBusy, !question.isEmpty, !messages.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: question))
        task = Task {
            do {
                try await respond()
            } catch is CancellationError {
                rollBackPendingQuestion()
                state = .idle
            } catch {
                rollBackPendingQuestion()
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops whatever is in flight or being spoken; a written conversation stays open.
    func cancel() {
        task?.cancel()
        speaker.stop()
        if mode == .text { state = .idle }
    }

    /// Ends the conversation.
    func dismiss() {
        task?.cancel()
        speaker.stop()
        messages = []
        showsConversation = false
        state = .idle
    }

    /// Sends the conversation to the model and shows or speaks the reply.
    private func respond(extraSpeech: String = "") async throws {
        state = .working("Thinking…")
        let settings = LLMSettings.shared
        let reply = try await OpenRouter.complete(
            system: Self.systemPrompt(spoken: mode == .audio),
            messages: messages.map { ($0.role.rawValue, $0.text) },
            model: settings.model,
            apiKey: settings.apiKey
        )
        try Task.checkCancellation()
        messages.append(ChatMessage(role: .assistant, text: reply))

        switch mode {
        case .text:
            answerCount += 1
            showsConversation = true
            state = .answer(reply, id: answerCount)
        case .audio:
            state = .working("Speaking…")
            await speaker.speak(reply + extraSpeech)
            try Task.checkCancellation()
        }
    }

    /// Listens for questions until the listener goes quiet or says they're done.
    private func voiceFollowUps() async throws {
        while true {
            state = .working("Listening…")
            guard let question = try await mic.listen(), !Self.isFarewell(question) else { return }
            messages.append(ChatMessage(role: .user, text: question))
            try await respond()
        }
    }

    private func rollBackPendingQuestion() {
        if let last = messages.last, last.role == .user, !last.isContext { messages.removeLast() }
    }

    private static func isFarewell(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard words.count <= 4, let first = words.first else { return false }
        return ["thanks", "thank", "no", "nope", "done", "stop", "okay", "ok", "nevermind", "bye", "cancel"].contains(first)
            || text.lowercased().contains("that's all") || text.lowercased().contains("never mind")
    }

    private static func prompt(book: Audiobook, time: TimeInterval, transcript: String) -> String {
        let author = book.author.isEmpty ? "" : " by \(book.author)"
        return """
        I'm listening to the audiobook \(book.title)\(author) and at \(time.clockString) there's this passage \
        that I don't understand, please explain it to me.

        The last minute of audio, transcribed automatically (it may contain recognition errors):

        \(transcript)
        """
    }

    private static func systemPrompt(spoken: Bool) -> String {
        var text = "You help someone who is listening to an audiobook understand a passage they just heard, "
            + "and answer their follow-up questions about it. Explain what is going on and any context needed "
            + "(who is speaking, references, terms), without spoilers beyond the passage. Be concise."
        if spoken {
            text += " Your answers will be read aloud while they drive: use short plain sentences, "
                + "no lists, markdown or symbols, and keep each under about 150 words."
        }
        return text
    }
}

/// Reads answers aloud over the app's audio session.
@MainActor
private final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        await withCheckedContinuation { continuation in
            finished[ObjectIdentifier(utterance)] = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(utterance) }
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        finished.removeValue(forKey: ObjectIdentifier(utterance))?.resume()
    }
}

enum ExplainError: LocalizedError {
    case noAudio
    case noSpeech
    case speechUnavailable
    case micDenied

    var errorDescription: String? {
        switch self {
        case .noAudio: "The last minute of audio isn't available yet."
        case .noSpeech: "I couldn't make out any speech in the last minute."
        case .speechUnavailable: "Allow Speech Recognition for MyTube in Settings."
        case .micDenied: "Allow Microphone access for MyTube in Settings."
        }
    }
}

/// A recognized word and when it is spoken, in seconds from the start of the part.
struct TimedWord: Codable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

enum ClipTranscriber {
    /// Speech Recognition permission, asking the first time.
    static func isAuthorized() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized && SFSpeechRecognizer()?.isAvailable == true
    }

    static var supportsOnDevice: Bool {
        SFSpeechRecognizer()?.supportsOnDeviceRecognition == true
    }

    /// Words in the audio file, with times relative to its start. Silence gives no words.
    ///
    /// On long audio the recognizer delivers a final result per utterance rather than one for the
    /// whole file, so every result is collected until the task finishes.
    static func words(in url: URL) async throws -> [TimedWord] {
        guard await isAuthorized(), let recognizer = SFSpeechRecognizer() else { throw ExplainError.speechUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let collector = ResultCollector()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.continuation = continuation
                collector.task = recognizer.recognitionTask(with: request, delegate: collector)
            }
        } onCancel: {
            collector.task?.cancel()
        }
    }
}

private final class ResultCollector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<[TimedWord], Error>?
    var task: SFSpeechRecognitionTask?
    private var words: [TimedWord] = []
    private var failure: Error?

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
        words += result.bestTranscription.segments.map {
            TimedWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
        }
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if successfully || words.isEmpty == false {
            // Overlapping results can repeat a word; keep one per start time.
            var seen = Set<Int>()
            let unique = words.sorted { $0.start < $1.start }.filter { seen.insert(Int($0.start * 100)).inserted }
            continuation.resume(returning: unique)
        } else if let error = task.error, (error as NSError).code != 1110 {
            // "No speech detected" (1110) is just a quiet stretch.
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: [])
        }
    }
}
