import AVFoundation
import AudioToolbox
import Speech

/// Listens on the microphone for one spoken question and returns what was said.
@MainActor
final class MicListener {
    /// Gives up if nothing is said within this long.
    private static let noSpeechTimeout: TimeInterval = 8
    /// A pause this long ends the question.
    private static let endSilence: TimeInterval = 1.8

    private let engine = AVAudioEngine()

    /// The transcribed question, or nil if the listener said nothing.
    func listen() async throws -> String? {
        guard await AVAudioApplication.requestRecordPermission() else { throw ExplainError.micDenied }
        guard await ClipTranscriber.isAuthorized(), let recognizer = SFSpeechRecognizer() else {
            throw ExplainError.speechUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let progress = Progress()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result { progress.update(result.bestTranscription.formattedString) }
            if error != nil || result?.isFinal == true { progress.finish() }
        }

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        defer {
            engine.stop()
            input.removeTap(onBus: 0)
            request.endAudio()
            task.cancel()
        }
        engine.prepare()
        try engine.start()
        AudioServicesPlaySystemSound(1113)  // the "begin recording" tone

        let start = Date()
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(250))
            let (text, lastChange, finished) = progress.snapshot()
            if text.isEmpty {
                if finished || Date().timeIntervalSince(start) > Self.noSpeechTimeout { return nil }
            } else if finished || Date().timeIntervalSince(lastChange) > Self.endSilence {
                return text
            }
        }
        throw CancellationError()
    }
}

/// Recognition progress, written from the recognizer's thread and read by the polling loop.
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var lastChange = Date()
    private var finished = false

    func update(_ newText: String) {
        lock.withLock {
            if newText != text { lastChange = Date() }
            text = newText
        }
    }

    func finish() {
        lock.withLock { finished = true }
    }

    func snapshot() -> (String, Date, Bool) {
        lock.withLock { (text, lastChange, finished) }
    }
}
