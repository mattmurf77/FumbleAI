import Foundation
import Observation
#if canImport(Speech) && canImport(AVFoundation) && os(iOS)
import Speech
import AVFoundation
#endif

/// Live speech-to-text for quick capture. Uses Apple's on-device recognizer when the iPhone supports it (nothing
/// leaves the phone), else Apple's server recognizer. `transcript` holds `prefix` + what has been heard so far.
@MainActor
@Observable
final class SpeechDictation {
    private(set) var transcript = ""
    private(set) var isRecording = false
    var errorText: String?

    #if canImport(Speech) && canImport(AVFoundation) && os(iOS)
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    #endif

    /// Starts listening; the result is appended to `prefix` (the text already in the box).
    func start(prefix: String) async {
        #if canImport(Speech) && canImport(AVFoundation) && os(iOS)
        guard !isRecording else { return }
        errorText = nil
        guard await Self.speechAllowed() else {
            errorText = "Speech recognition is off for Home Blueprint. Turn it on in Settings › Privacy & Security › Speech Recognition."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorText = "The microphone is off for Home Blueprint. Turn it on in Settings › Privacy & Security › Microphone."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            errorText = "Speech recognition isn’t available right now. Try again in a moment, or type your list."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            Self.feed(engine.inputNode, into: request)
            engine.prepare()
            try engine.start()

            let base = prefix.isEmpty || prefix.hasSuffix("\n") ? prefix : prefix + "\n"
            transcript = prefix
            isRecording = true
            task = Self.recognize(recognizer, request) { [weak self] text, done in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = base + text }
                    if done { self.stop() }
                }
            }
        } catch {
            errorText = "Couldn’t start listening: \(error.localizedDescription)"
            stop()
        }
        #else
        errorText = "Dictation needs an iPhone."
        #endif
    }

    func stop() {
        #if canImport(Speech) && canImport(AVFoundation) && os(iOS)
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isRecording = false
    }

    #if canImport(Speech) && canImport(AVFoundation) && os(iOS)
    /// Audio and recognition callbacks run on background queues, so they are built outside the main actor.
    nonisolated private static func feed(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }

    nonisolated private static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
            }
        }
    }
    #endif
}
