@preconcurrency import AVFoundation
import Combine
import CoreGraphics
import Foundation
import Speech
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

enum SpeechAuthorizationBridge {
    nonisolated static var currentStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    nonisolated static func requestStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

enum MicrophoneAuthorizationBridge {
    nonisolated static var currentStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    nonisolated static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

enum ScreenCaptureAuthorizationBridge {
    nonisolated static var currentStatus: Bool {
        CGPreflightScreenCaptureAccess()
    }

    nonisolated static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

private final class LiveSpeechTranscriber: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PowerMeetings.LiveSpeechTranscriber")
    private var audioEngine: AVAudioEngine?
    private var recognitionRequests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var recognitionTasks: [SFSpeechRecognitionTask] = []
    private var isStoppingIntentionally = false

    func start(
        languageIDs: [String],
        onTranscript: @escaping @Sendable (String, String) -> Void,
        onSilence: @escaping @Sendable () -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [weak self] in
            self?.startOnQueue(
                languageIDs: languageIDs,
                onTranscript: onTranscript,
                onSilence: onSilence,
                onUnavailable: onUnavailable
            )
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue(
        languageIDs: [String],
        onTranscript: @escaping @Sendable (String, String) -> Void,
        onSilence: @escaping @Sendable () -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        stopOnQueue()

        let status = SpeechAuthorizationBridge.currentStatus
        guard status == .authorized else {
            onUnavailable("Realtime transcription is off. Speech recognition is not authorized, and recording will continue normally.")
            return
        }

        let recognizers = languageIDs.compactMap { languageID -> (String, SFSpeechRecognizer)? in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID)),
                  recognizer.supportsOnDeviceRecognition,
                  recognizer.isAvailable else { return nil }
            return (languageID, recognizer)
        }
        guard recognizers.isEmpty == false else {
            onUnavailable("On-device Speech Recognition is unavailable for the selected meeting languages.")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onUnavailable("Realtime transcription is off. No microphone input format was available.")
            return
        }

        for (languageID, recognizer) in recognizers {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if #available(macOS 13.0, *) {
                request.requiresOnDeviceRecognition = true
            }
            if #available(macOS 14.0, *) {
                request.addsPunctuation = true
            }

            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if transcript.isEmpty == false {
                        onTranscript(transcript, languageID)
                    }
                }

                if let error {
                    if self?.isStoppingIntentionally != true {
                        onUnavailable("Realtime \(languageID) transcription stopped: \(error.localizedDescription)")
                    }
                }
            }
            recognitionRequests.append(request)
            recognitionTasks.append(task)
        }

        var quietDuration: TimeInterval = 0
        let bufferDuration = Double(1_024) / format.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let transcriber = self else { return }
            transcriber.queue.async { [weak transcriber] in
                transcriber?.recognitionRequests.forEach { $0.append(buffer) }
            }
            let level = AudioMeterCalculator.audioLevel(from: buffer)
            if level < 0.075 {
                quietDuration += bufferDuration
                if quietDuration >= 1.5 {
                    quietDuration = 0
                    onSilence()
                }
            } else {
                quietDuration = 0
            }
        }

        do {
            engine.prepare()
            try engine.start()
            audioEngine = engine
            isStoppingIntentionally = false
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionTasks.forEach { $0.cancel() }
            recognitionTasks = []
            recognitionRequests = []
            onUnavailable("Realtime transcription could not start: \(error.localizedDescription)")
        }
    }

    private func stopOnQueue() {
        isStoppingIntentionally = true
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recognitionRequests.forEach { $0.endAudio() }
        recognitionRequests = []
        recognitionTasks.forEach { $0.cancel() }
        recognitionTasks = []
        audioEngine = nil
    }
}

private final class AliyunParaformerTranscriber: @unchecked Sendable {
    private final class ConverterInputState: @unchecked Sendable {
        var didProvideInput = false
    }

    private let queue = DispatchQueue(label: "PowerMeetings.AliyunParaformerTranscriber")
    private let urlSession = URLSession(configuration: .default)
    private var audioEngine: AVAudioEngine?
    private var webSocketTask: URLSessionWebSocketTask?
    private var taskID = UUID().uuidString
    private var isTaskStarted = false
    private var pendingAudioChunks: [Data] = []
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var isStoppingIntentionally = false
    private let fallbackLanguageID = "auto"

    func start(
        configuration: ModelConfiguration,
        onTranscript: @escaping @Sendable (String, String, Bool) -> Void,
        onStatus: @escaping @Sendable (String) -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [weak self] in
            self?.startOnQueue(
                configuration: configuration,
                onTranscript: onTranscript,
                onStatus: onStatus,
                onUnavailable: onUnavailable
            )
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue(
        configuration: ModelConfiguration,
        onTranscript: @escaping @Sendable (String, String, Bool) -> Void,
        onStatus: @escaping @Sendable (String) -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        stopOnQueue()
        let apiKey = configuration.realtimeASRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false else {
            onUnavailable("Aliyun Realtime ASR is not configured. Falling back to macOS Speech.")
            return
        }

        taskID = UUID().uuidString
        isTaskStarted = false
        isStoppingIntentionally = false
        pendingAudioChunks = []
        var request = URLRequest(url: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("PowerMeetings/0.1.0", forHTTPHeaderField: "user-agent")
        onStatus("Aliyun Realtime ASR: connecting to DashScope WebSocket...")
        let socket = urlSession.webSocketTask(with: request)
        webSocketTask = socket
        socket.resume()
        receiveLoop(onTranscript: onTranscript, onStatus: onStatus, onUnavailable: onUnavailable)
        let model = configuration.realtimeASRModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "fun-asr-realtime"
            : configuration.realtimeASRModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let sampleRate = model.contains("8k") ? 8_000 : 16_000
        sendRunTask(model: model, sampleRate: sampleRate)
        startAudioEngine(sampleRate: Double(sampleRate), onUnavailable: onUnavailable)
    }

    private func sendRunTask(model: String, sampleRate: Int) {
        let parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": sampleRate,
            "disfluency_removal_enabled": false,
            "semantic_punctuation_enabled": false,
            "punctuation_prediction_enabled": true,
            "max_sentence_silence": 1500,
            "heartbeat": true
        ]

        let message: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": parameters,
                "input": [:]
            ]
        ]
        sendJSON(message)
    }

    private func startAudioEngine(sampleRate: Double, onUnavailable: @escaping @Sendable (String) -> Void) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            onUnavailable("Aliyun Realtime ASR could not prepare microphone audio format.")
            return
        }

        self.converter = converter
        outputFormat = targetFormat
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.sendAudioBuffer(buffer)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            audioEngine = engine
        } catch {
            inputNode.removeTap(onBus: 0)
            onUnavailable("Aliyun Realtime ASR audio capture failed: \(error.localizedDescription)")
        }
    }

    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = convertToPCM8k(buffer) else { return }
        if isTaskStarted {
            webSocketTask?.send(.data(data)) { _ in }
        } else {
            pendingAudioChunks.append(data)
        }
    }

    private func convertToPCM8k(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter, let outputFormat else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return nil }

        let inputState = ConverterInputState()
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if inputState.didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            inputState.didProvideInput = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil,
              let data = outputBuffer.int16ChannelData,
              outputBuffer.frameLength > 0 else { return nil }
        return Data(bytes: data[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    }

    private func receiveLoop(
        onTranscript: @escaping @Sendable (String, String, Bool) -> Void,
        onStatus: @escaping @Sendable (String) -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case let .success(message):
                    self.handle(message, onTranscript: onTranscript, onStatus: onStatus, onUnavailable: onUnavailable)
                    self.receiveLoop(onTranscript: onTranscript, onStatus: onStatus, onUnavailable: onUnavailable)
                case let .failure(error):
                    if self.isStoppingIntentionally == false {
                        onUnavailable("Aliyun Realtime ASR connection failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func handle(
        _ message: URLSessionWebSocketTask.Message,
        onTranscript: @escaping @Sendable (String, String, Bool) -> Void,
        onStatus: @escaping @Sendable (String) -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        let data: Data?
        switch message {
        case let .string(text):
            data = text.data(using: .utf8)
        case let .data(messageData):
            data = messageData
        @unknown default:
            data = nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String else { return }

        switch event {
        case "task-started":
            isTaskStarted = true
            onStatus("Aliyun Realtime ASR: task started.")
            pendingAudioChunks.forEach { chunk in
                webSocketTask?.send(.data(chunk)) { _ in }
            }
            pendingAudioChunks = []
        case "task-finished":
            onStatus("Aliyun Realtime ASR: task finished.")
        case "result-generated":
            guard let payload = object["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  (sentence["heartbeat"] as? Bool) != true,
                  let text = sentence["text"] as? String else { return }
            let isFinal = sentence["sentence_end"] as? Bool ?? false
            onTranscript(text, languageID(from: sentence, output: output, payload: payload, text: text), isFinal)
        case "task-failed":
            let message = header["error_message"] as? String ?? "Unknown Paraformer task failure."
            isStoppingIntentionally = true
            onUnavailable("Aliyun Realtime ASR failed: \(message)")
        default:
            break
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    private func languageID(
        from sentence: [String: Any],
        output: [String: Any],
        payload: [String: Any],
        text: String
    ) -> String {
        let candidate = firstLanguageValue(in: [sentence, output, payload])
        return normalizedLanguageID(candidate) ?? inferredLanguageID(for: text) ?? fallbackLanguageID
    }

    private func firstLanguageValue(in objects: [[String: Any]]) -> String? {
        let keys = [
            "language",
            "language_code",
            "language_id",
            "languageCode",
            "languageId",
            "language_type",
            "languageType",
            "detected_language",
            "detectedLanguage",
            "lang",
            "locale"
        ]
        for object in objects {
            for key in keys {
                if let value = object[key] as? String,
                   value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return value
                }
            }
            for value in object.values {
                if let nested = value as? [String: Any],
                   let language = firstLanguageValue(in: [nested]) {
                    return language
                }
            }
        }
        return nil
    }

    private func normalizedLanguageID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard normalized.isEmpty == false else { return nil }
        if normalized.hasPrefix("zh") || normalized == "chinese" || normalized == "mandarin" {
            return LocalMeetingLanguage.mandarinChinese.rawValue
        }
        if normalized.hasPrefix("en") || normalized == "english" {
            return LocalMeetingLanguage.english.rawValue
        }
        return normalized
    }

    private func inferredLanguageID(for text: String) -> String? {
        let scalars = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard scalars.isEmpty == false else { return nil }
        let cjkCount = scalars.filter { (0x4E00...0x9FFF).contains(Int($0.value)) }.count
        let latinCount = scalars.filter {
            CharacterSet.alphanumerics.contains($0) && (0x0000...0x024F).contains(Int($0.value))
        }.count
        if latinCount >= max(3, cjkCount * 2) {
            return LocalMeetingLanguage.english.rawValue
        }
        if cjkCount >= max(2, latinCount) {
            return LocalMeetingLanguage.mandarinChinese.rawValue
        }
        return nil
    }

    private func stopOnQueue() {
        isStoppingIntentionally = true
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        sendJSON([
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [:]]
        ])
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        audioEngine = nil
        converter = nil
        outputFormat = nil
        pendingAudioChunks = []
        isTaskStarted = false
    }
}

struct PostMeetingTranscriber {
    enum TranscriptionError: LocalizedError {
        case speechNotAuthorized
        case recognizerUnavailable
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .speechNotAuthorized:
                "Speech Recognition is not authorized."
            case .recognizerUnavailable:
                "Speech recognizer is unavailable for the selected local language."
            case .emptyResult:
                "No speech text was recognized from the recording."
            }
        }
    }

    func transcribe(url: URL, languageID: String) async throws -> String {
        guard SpeechAuthorizationBridge.currentStatus == .authorized else {
            throw TranscriptionError.speechNotAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID)) else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = true
        }

        let text: String = try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            recognizer.recognitionTask(with: request) { result, error in
                if didResume { return }
                if let error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    didResume = true
                    if transcript.isEmpty {
                        continuation.resume(throwing: TranscriptionError.emptyResult)
                    } else {
                        continuation.resume(returning: transcript)
                    }
                }
            }
        }

        return text
    }
}

private final class AudioFileWriter: @unchecked Sendable {
    private let file: AVAudioFile

    init(file: AVAudioFile) {
        self.file = file
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }
}

private final class AudioTapCallbacks: @unchecked Sendable {
    let onLevel: @Sendable (Double) -> Void
    let onError: @Sendable (String) -> Void

    init(
        onLevel: @escaping @Sendable (Double) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.onLevel = onLevel
        self.onError = onError
    }
}

private enum AudioMeterCalculator {
    static func audioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var totalSquares = 0.0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = Double(samples[frame])
                totalSquares += sample * sample
            }
            sampleCount += frameLength
        }

        guard sampleCount > 0 else { return 0 }
        return normalizedMeterLevel(rms: sqrt(totalSquares / Double(sampleCount))) ?? 0
    }

    static func normalizedMeterLevel(rms: Double) -> Double? {
        guard rms.isFinite else { return nil }
        return min(1, max(0.03, pow(rms * 12, 0.65)))
    }
}

private final class NoiseSuppressingMicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let highPass = AVAudioUnitEQ(numberOfBands: 1)
    private let queue = DispatchQueue(label: "PowerMeetings.NoiseSuppressingMicrophoneRecorder")
    private var writer: AudioFileWriter?
    private var outputURL: URL?
    private var isRunning = false
    private let onLevel: @Sendable (Double) -> Void

    init(onLevel: @escaping @Sendable (Double) -> Void) {
        self.onLevel = onLevel
    }

    func start(url: URL) throws {
        outputURL = url
        configureProcessingChain()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "PowerMeetings", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input format was available."
            ])
        }

        engine.attach(highPass)
        engine.connect(inputNode, to: highPass, format: inputFormat)
        engine.connect(highPass, to: engine.mainMixerNode, format: inputFormat)
        engine.mainMixerNode.outputVolume = 0

        let file = try AVAudioFile(forWriting: url, settings: Self.fileSettings(format: inputFormat))
        writer = AudioFileWriter(file: file)

        highPass.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] (buffer: AVAudioPCMBuffer, _: AVAudioTime) in
            guard let self else { return }
            self.applySoftNoiseGate(to: buffer)
            let level = AudioMeterCalculator.audioLevel(from: buffer)
            self.onLevel(level)
            self.queue.async { [weak self] in
                do {
                    try self?.writer?.write(buffer)
                } catch {
                    // Keep the realtime audio callback lightweight; stop is handled by the caller.
                }
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func pause() {
        guard isRunning else { return }
        engine.pause()
        isRunning = false
    }

    func resume() throws {
        guard isRunning == false else { return }
        try engine.start()
        isRunning = true
    }

    func stop() {
        highPass.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        writer = nil
        isRunning = false
    }

    private func configureProcessingChain() {
        if let band = highPass.bands.first {
            band.filterType = .highPass
            band.frequency = 85
            band.bypass = false
        }
    }

    private func applySoftNoiseGate(to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let noiseFloor: Float = 0.012
        let speechFloor: Float = 0.05

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let value = samples[frame]
                let magnitude = abs(value)
                if magnitude < noiseFloor {
                    samples[frame] = value * 0.18
                } else if magnitude < speechFloor {
                    let blend = (magnitude - noiseFloor) / (speechFloor - noiseFloor)
                    samples[frame] = value * (0.18 + 0.82 * blend)
                }
            }
        }
    }

    private static func fileSettings(format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 64_000
        ]
    }
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published var selectedDeviceID: String? {
        didSet {
            UserDefaults.standard.set(selectedDeviceID, forKey: "audio.selectedInputDeviceID")
        }
    }

    init() {
        selectedDeviceID = UserDefaults.standard.string(forKey: "audio.selectedInputDeviceID")
    }

    func refreshDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let defaultDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        devices = session.devices.map { device in
            AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                manufacturer: device.manufacturer,
                isDefault: device.uniqueID == defaultDeviceID,
                sampleRate: nil,
                channelCount: nil
            )
        }

        if selectedDeviceID == nil || devices.contains(where: { $0.id == selectedDeviceID }) == false {
            selectedDeviceID = defaultDeviceID ?? devices.first?.id
        }
    }
}

@MainActor
final class SettingsAudioLevelMonitor: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published private(set) var level: Double = 0

    private let captureQueue = DispatchQueue(label: "PowerMeetings.SettingsAudioLevel")
    private var captureSession: AVCaptureSession?

    func start(deviceID: String?) {
        stop()

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let device = selectedAudioDevice(id: deviceID),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            level = 0
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else {
            level = 0
            return
        }
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

        captureSession = session
        captureQueue.async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        let session = captureSession
        captureSession = nil
        level = 0
        captureQueue.async { [session] in
            session?.stopRunning()
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let level = AudioCaptureEngine.audioLevel(from: connection) ?? AudioCaptureEngine.audioLevel(from: sampleBuffer) else { return }
        Task { @MainActor in
            self.level = level
        }
    }

    private func selectedAudioDevice(id: String?) -> AVCaptureDevice? {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        if let id, let selected = session.devices.first(where: { $0.uniqueID == id }) {
            return selected
        }
        return AVCaptureDevice.default(for: .audio) ?? session.devices.first
    }
}

#if canImport(ScreenCaptureKit)
private final class SystemAudioCaptureEngine: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PowerMeetings.SystemAudioCapture")
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var didStartWriting = false
    private(set) var outputURL: URL?
    var onEvent: (@MainActor (String, String) -> Void)?

    func start(in directory: URL) {
        queue.async { [weak self] in
            Task {
                await self?.startCapture(in: directory)
            }
        }
    }

    func stop(completion: @escaping @Sendable (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            let stream = self.stream
            self.stream = nil
            Task {
                if let stream {
                    try? await stream.stopCapture()
                }
                self.queue.async {
                    self.finishWriter(completion: completion)
                }
            }
        }
    }

    private func startCapture(in directory: URL) async {
        do {
            let url = directory.appendingPathComponent("system-audio-\(UUID().uuidString).m4a")
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
            }

            outputURL = url
            assetWriter = writer
            writerInput = input
            didStartWriting = false

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                await emitEvent("System audio capture could not find an active display.", level: "warning")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            await emitEvent("System audio capture failed: \(error.localizedDescription)", level: "warning")
            finishWriter { _ in }
        }
    }

    private func emitEvent(_ message: String, level: String) async {
        await MainActor.run {
            onEvent?(message, level)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let assetWriter,
              let writerInput else { return }

        if didStartWriting == false {
            guard assetWriter.startWriting() else { return }
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            didStartWriting = true
        }

        if writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
        }
    }

    private func finishWriter(completion: @escaping @Sendable (URL?) -> Void) {
        guard let writer = assetWriter else {
            completion(nil)
            return
        }
        let url = outputURL
        assetWriter = nil
        writerInput?.markAsFinished()
        writerInput = nil

        guard didStartWriting else {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            outputURL = nil
            completion(nil)
            return
        }

        writer.finishWriting {
            if writer.status == .completed, let url {
                completion(url)
            } else {
                if let url {
                    try? FileManager.default.removeItem(at: url)
                }
                completion(nil)
            }
        }
    }
}

extension SystemAudioCaptureEngine: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        queue.async { [weak self] in
            self?.append(sampleBuffer)
        }
    }
}
#endif

@MainActor
final class AudioCaptureEngine: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case paused
        case ended
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var playbackPosition: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var recordingURL: URL?
    @Published private(set) var activeMeetingID: Meeting.ID?
    @Published private(set) var isFinalizingRecording = false

    private var audioRecorder: AVAudioRecorder?
    private var noiseSuppressingRecorder: NoiseSuppressingMicrophoneRecorder?
    private var audioPlayer: AVAudioPlayer?
    #if canImport(ScreenCaptureKit)
    private var systemAudioCapture: SystemAudioCaptureEngine?
    private var completedSystemAudioURLs: [URL] = []
    #endif
    private var levelTimer: Timer?
    private var elapsedTimer: Timer?
    private var playbackTimer: Timer?
    private var accumulatedElapsed: TimeInterval = 0
    private var lastSettings = AudioCaptureSettings()
    var onRecordingReady: (@MainActor (URL, TimeInterval) -> Void)?
    var onEvent: (@MainActor (String, String) -> Void)?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isPaused: Bool {
        state == .paused
    }

    var failureMessage: String? {
        if case let .failed(message) = state {
            return message
        }
        return nil
    }

    func elapsed(at date: Date) -> TimeInterval {
        if case let .recording(startedAt) = state {
            return accumulatedElapsed + date.timeIntervalSince(startedAt)
        }
        return elapsed
    }

    func meterLevel(at date: Date) -> Double {
        isRecording ? inputLevel : 0
    }

    @discardableResult
    func start(settings: AudioCaptureSettings, meetingID: Meeting.ID) -> Bool {
        stop()
        guard MicrophoneAuthorizationBridge.currentStatus == .authorized else {
            state = .failed("Microphone access is not authorized. Grant Microphone access in macOS System Settings.")
            onEvent?("Microphone access is not authorized. Grant Microphone access in macOS System Settings.", "error")
            return false
        }

        accumulatedElapsed = 0
        elapsed = 0
        playbackPosition = 0
        inputLevel = 0
        isPlaying = false
        isFinalizingRecording = false
        activeMeetingID = meetingID
        lastSettings = settings
        onRecordingReady = nil
        #if canImport(ScreenCaptureKit)
        completedSystemAudioURLs = []
        #endif

        let recordingDirectory = makeRecordingDirectory()
        let url = recordingDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        if settings.enableNoiseSuppression, startNoiseSuppressingRecorder(url: url) == false {
            noiseSuppressingRecorder = nil
            onEvent?("Noise suppression could not start. Falling back to standard recording.", "warning")
        }

        if noiseSuppressingRecorder == nil, startStandardRecorder(url: url) == false {
            state = .failed("Could not start recording.")
            onEvent?("Could not start recording.", "error")
            activeMeetingID = nil
            return false
        }

        state = .recording(startedAt: Date())
        startMeters()
        startSystemAudioCaptureIfNeeded(settings: settings, recordingDirectory: recordingDirectory)
        return true
    }

    private func startNoiseSuppressingRecorder(url: URL) -> Bool {
        let recorder = NoiseSuppressingMicrophoneRecorder { [weak self] level in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.inputLevel = level
            }
        }
        do {
            try recorder.start(url: url)
            noiseSuppressingRecorder = recorder
            recordingURL = url
            return true
        } catch {
            return false
        }
    }

    private func startStandardRecorder(url: URL) -> Bool {
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                return false
            }
            audioRecorder = recorder
            recordingURL = url
            return true
        } catch {
            return false
        }
    }

    func pause() {
        guard case let .recording(startedAt) = state else { return }
        accumulatedElapsed += Date().timeIntervalSince(startedAt)
        elapsed = accumulatedElapsed
        audioRecorder?.pause()
        noiseSuppressingRecorder?.pause()
        #if canImport(ScreenCaptureKit)
        systemAudioCapture?.stop { [weak self] url in
            guard let url else { return }
            Task { @MainActor in
                self?.completedSystemAudioURLs.append(url)
            }
        }
        systemAudioCapture = nil
        #endif
        state = .paused
        stopMeters()
        inputLevel = 0
    }

    @discardableResult
    func resume() -> Bool {
        guard state == .paused else { return false }
        if let recorder = audioRecorder {
            guard recorder.record() else {
                state = .failed("Could not resume recording.")
                return false
            }
        } else if let noiseSuppressingRecorder {
            do {
                try noiseSuppressingRecorder.resume()
            } catch {
                state = .failed("Could not resume processed recording: \(error.localizedDescription)")
                return false
            }
        }
        state = .recording(startedAt: Date())
        startMeters()
        if lastSettings.enableSystemAudio, let recordingURL {
            startSystemAudioCaptureIfNeeded(
                settings: lastSettings,
                recordingDirectory: recordingURL.deletingLastPathComponent()
            )
        }
        return true
    }

    func end() {
        if case let .recording(startedAt) = state {
            accumulatedElapsed += Date().timeIntervalSince(startedAt)
            elapsed = accumulatedElapsed
        }
        let microphoneURL = recordingURL
        audioRecorder?.stop()
        audioRecorder = nil
        noiseSuppressingRecorder?.stop()
        noiseSuppressingRecorder = nil
        state = .ended
        inputLevel = 0
        playbackPosition = 0
        stopMeters()
        stopPlayback()
        activeMeetingID = nil
        finishSystemAudioAndNotify(microphoneURL: microphoneURL)
    }

    func stop() {
        audioRecorder?.stop()
        audioRecorder = nil
        noiseSuppressingRecorder?.stop()
        noiseSuppressingRecorder = nil
        #if canImport(ScreenCaptureKit)
        systemAudioCapture?.stop { [weak self] url in
            guard let url else { return }
            Task { @MainActor in
                self?.completedSystemAudioURLs.append(url)
            }
        }
        systemAudioCapture = nil
        #endif
        state = .idle
        activeMeetingID = nil
        accumulatedElapsed = 0
        elapsed = 0
        playbackPosition = 0
        inputLevel = 0
        recordingURL = nil
        isFinalizingRecording = false
        onRecordingReady = nil
        stopMeters()
        stopPlayback()
    }

    func play() {
        guard let recordingURL, elapsed > 0 else { return }
        do {
            if audioPlayer == nil {
                audioPlayer = try AVAudioPlayer(contentsOf: recordingURL)
                audioPlayer?.prepareToPlay()
            }
            audioPlayer?.currentTime = playbackPosition
            audioPlayer?.play()
        } catch {
            state = .failed("Could not play recording: \(error.localizedDescription)")
            onEvent?("Could not play recording: \(error.localizedDescription)", "error")
            return
        }

        isPlaying = true
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let player = self.audioPlayer {
                    self.playbackPosition = min(self.elapsed, player.currentTime)
                    if player.isPlaying == false || self.playbackPosition >= self.elapsed {
                        self.stopPlayback()
                    }
                }
            }
        }
    }

    func stopPlayback() {
        isPlaying = false
        audioPlayer?.stop()
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    func seekPlayback(to position: TimeInterval) {
        playbackPosition = min(max(0, position), max(elapsed, 0))
        audioPlayer?.currentTime = playbackPosition
    }

    func exportRecording(to destination: URL) throws {
        guard let recordingURL else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: recordingURL, to: destination)
    }

    func loadCompletedRecording(path: String?, duration: TimeInterval?) {
        stopPlayback()
        guard let path, FileManager.default.fileExists(atPath: path) else {
            recordingURL = nil
            playbackPosition = 0
            return
        }
        recordingURL = URL(fileURLWithPath: path)
        elapsed = duration ?? audioDuration(url: recordingURL!) ?? elapsed
        playbackPosition = 0
        state = .ended
        audioPlayer = nil
    }

    private func startMeters() {
        levelTimer?.invalidate()
        elapsedTimer?.invalidate()

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, let recorder = self.audioRecorder else { return }
                recorder.updateMeters()
                self.inputLevel = Self.normalizedPower(recorder.averagePower(forChannel: 0))
            }
        }

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case let .recording(startedAt) = self.state else { return }
                self.elapsed = self.accumulatedElapsed + Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopMeters() {
        levelTimer?.invalidate()
        elapsedTimer?.invalidate()
        levelTimer = nil
        elapsedTimer = nil
    }

    private func startSystemAudioCaptureIfNeeded(settings: AudioCaptureSettings, recordingDirectory: URL) {
        guard settings.enableSystemAudio else { return }
        #if canImport(ScreenCaptureKit)
        guard ScreenCaptureAuthorizationBridge.currentStatus else {
            onEvent?("System audio capture is off. Screen Recording permission is required; microphone recording will continue.", "warning")
            return
        }
        let capture = SystemAudioCaptureEngine()
        capture.onEvent = onEvent
        systemAudioCapture = capture
        capture.start(in: recordingDirectory)
        #else
        onEvent?("System audio capture is unavailable on this macOS build; microphone recording will continue.", "warning")
        #endif
    }

    private func finishSystemAudioAndNotify(microphoneURL: URL?) {
        #if canImport(ScreenCaptureKit)
        guard let capture = systemAudioCapture else {
            mixSystemAudioIfNeeded(microphoneURL: microphoneURL, systemAudioURLs: completedSystemAudioURLs)
            return
        }
        isFinalizingRecording = true
        systemAudioCapture = nil
        capture.stop { [weak self] url in
            Task { @MainActor in
                guard let self else { return }
                var urls = self.completedSystemAudioURLs
                if let url {
                    urls.append(url)
                }
                self.mixSystemAudioIfNeeded(microphoneURL: microphoneURL, systemAudioURLs: urls)
            }
        }
        #else
        notifyRecordingReadyIfNeeded()
        #endif
    }

    private func mixSystemAudioIfNeeded(microphoneURL: URL?, systemAudioURLs: [URL]) {
        guard let microphoneURL,
              systemAudioURLs.isEmpty == false else {
            isFinalizingRecording = false
            notifyRecordingReadyIfNeeded()
            return
        }

        isFinalizingRecording = true
        let outputURL = microphoneURL
            .deletingLastPathComponent()
            .appendingPathComponent("mixed-recording-\(UUID().uuidString).m4a")

        Task {
            do {
                try await Self.mixAudioFiles(
                    microphoneURL: microphoneURL,
                    systemAudioURLs: systemAudioURLs,
                    outputURL: outputURL
                )
                await MainActor.run {
                    self.recordingURL = outputURL
                    self.isFinalizingRecording = false
                    self.notifyRecordingReadyIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.onEvent?("System audio could not be mixed into the final recording: \(error.localizedDescription)", "warning")
                    self.isFinalizingRecording = false
                    self.notifyRecordingReadyIfNeeded()
                }
            }
        }
    }

    private func notifyRecordingReadyIfNeeded() {
        guard let recordingURL else { return }
        onRecordingReady?(recordingURL, elapsed)
    }

    nonisolated private static func mixAudioFiles(
        microphoneURL: URL,
        systemAudioURLs: [URL],
        outputURL: URL
    ) async throws {
        let composition = AVMutableComposition()

        let microphoneAsset = AVURLAsset(url: microphoneURL)
        if let microphoneTrack = try await microphoneAsset.loadTracks(withMediaType: .audio).first,
           let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let duration = try await microphoneAsset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: microphoneTrack,
                at: .zero
            )
        }

        for systemAudioURL in systemAudioURLs where FileManager.default.fileExists(atPath: systemAudioURL.path) {
            let systemAsset = AVURLAsset(url: systemAudioURL)
            guard let systemTrack = try await systemAsset.loadTracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            let duration = try await systemAsset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: systemTrack,
                at: .zero
            )
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(domain: "PowerMeetings", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create audio mix export session."
            ])
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exportSession.error ?? NSError(
                        domain: "PowerMeetings",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Audio mix export failed."]
                    ))
                default:
                    continuation.resume(throwing: NSError(
                        domain: "PowerMeetings",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Audio mix export ended unexpectedly."]
                    ))
                }
            }
        }
    }

    private func makeRecordingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerMeetings", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func audioDuration(url: URL) -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite ? seconds : nil
    }

    nonisolated fileprivate static func audioLevel(from sampleBuffer: CMSampleBuffer) -> Double? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let bitsPerChannel = Int(streamDescription.pointee.mBitsPerChannel)
        let formatFlags = streamDescription.pointee.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0

        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let byteLength = CMBlockBufferGetDataLength(blockBuffer)
            if byteLength > 0 {
                var data = Data(count: byteLength)
                let status = data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: byteLength,
                        destination: bytes.baseAddress!
                    )
                }
                if status == kCMBlockBufferNoErr,
                   let rms = rmsLevel(data: data, bitsPerChannel: bitsPerChannel, isFloat: isFloat) {
                    return normalizedMeterLevel(rms: rms)
                }
            }
        }

        return nil
    }

    nonisolated fileprivate static func audioLevel(from connection: AVCaptureConnection) -> Double? {
        let powers = connection.audioChannels
            .map(\.averagePowerLevel)
            .filter { $0.isFinite }
        guard powers.isEmpty == false else { return nil }
        return normalizedPower(powers.reduce(0, +) / Float(powers.count))
    }

    nonisolated private static var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
    }

    nonisolated private static func normalizedPower(_ power: Float) -> Double {
        guard power.isFinite else { return 0 }
        let linear = pow(10, Double(power) / 20)
        return min(1, max(0, pow(linear * 6, 0.7)))
    }

    nonisolated private static func rmsLevel(data: Data, bitsPerChannel: Int, isFloat: Bool) -> Double? {
        if isFloat && bitsPerChannel == 32 {
            return data.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Float.self)
                guard samples.isEmpty == false else { return nil }
                let sum = samples.reduce(0.0) { partial, sample in
                    partial + Double(sample * sample)
                }
                return sqrt(sum / Double(samples.count))
            }
        }

        if bitsPerChannel == 16 {
            return data.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                guard samples.isEmpty == false else { return nil }
                let sum = samples.reduce(0.0) { partial, sample in
                    let normalized = Double(sample) / Double(Int16.max)
                    return partial + normalized * normalized
                }
                return sqrt(sum / Double(samples.count))
            }
        }

        return nil
    }

    nonisolated private static func normalizedMeterLevel(rms: Double) -> Double? {
        guard rms.isFinite else { return nil }
        return min(1, max(0.03, pow(rms * 12, 0.65)))
    }
}

struct LiveTranscriptDraft: Identifiable, Hashable {
    var id: String { "\(meetingID.uuidString)-\(languageID)" }
    var meetingID: UUID
    var languageID: String
    var text: String
}

@MainActor
final class MeetingSessionViewModel: ObservableObject {
    @Published var draftQuestion = ""
    @Published var activeSuggestion = "Start recording and I will surface likely questions, objections, and useful reply angles here."
    @Published private(set) var liveDraft: LiveTranscriptDraft?

    private let demoLines: [(String, String, String, SegmentKind)] = [
        (
            "Customer Lead",
            "Can this capture both my microphone and the system meeting audio?",
            "这个工具可以同时捕获我的麦克风和系统会议音频吗？",
            .question
        ),
        (
            "Host",
            "Yes. The first build will focus on input device capture, then system audio will be added through ScreenCaptureKit.",
            "可以。第一个版本会先聚焦输入设备捕获，之后通过 ScreenCaptureKit 增加系统音频。",
            .transcript
        ),
        (
            "Agent",
            "Suggested answer: confirm microphone support now, explain system audio permission clearly, and offer a fallback recording mode.",
            "回答建议：确认当前支持麦克风，清楚说明系统音频权限，并提供兜底录音模式。",
            .actionItem
        )
    ]

    private var demoIndex = 0
    private var transcriptTimer: Timer?
    private var activeMeetingID: UUID?
    private var appendSegment: (@MainActor (TranscriptSegment) -> Void)?
    private var updateSegmentTranslation: (@MainActor (TranscriptSegment.ID, String) -> Void)?
    private var updateSegment: (@MainActor (TranscriptSegment.ID, String, String, String) -> Void)?
    private var appendLog: (@MainActor (MeetingLogEntry) -> Void)?
    private var speechTranscriber: LiveSpeechTranscriber?
    private var paraformerTranscriber: AliyunParaformerTranscriber?
    private var lastEmittedTranscripts: [String: String] = [:]
    private var pendingLiveTranscripts: [String: String] = [:]
    private var pendingLiveTranscriptTimers: [String: Timer] = [:]
    private var lastFinalizedTranscripts: [String: String] = [:]
    private var activeLiveLanguageID: String?
    private var lastCommittedSegmentID: TranscriptSegment.ID?
    private var lastCommittedTranscript = ""
    private var lastCommittedAt: Date?
    private var modelConfiguration = ModelConfiguration()

    func startLiveTranscription(
        for meetingID: UUID,
        configuration: ModelConfiguration,
        append: @escaping @MainActor (TranscriptSegment) -> Void,
        updateSegment: @escaping @MainActor (TranscriptSegment.ID, String, String, String) -> Void,
        updateTranslation: @escaping @MainActor (TranscriptSegment.ID, String) -> Void,
        appendLog: @escaping @MainActor (MeetingLogEntry) -> Void
    ) {
        stopDemoTranscript()
        modelConfiguration = configuration
        demoIndex = 0
        activeMeetingID = meetingID
        appendSegment = append
        self.updateSegment = updateSegment
        updateSegmentTranslation = updateTranslation
        self.appendLog = appendLog
        startSpeechRecognition()
    }

    func resumeLiveTranscription() {
        guard activeMeetingID != nil else { return }
        startSpeechRecognition()
    }

    func pauseLiveTranscription() {
        stopSpeechRecognition(keepSession: true)
    }

    private func scheduleTranscriptTimer() {
        transcriptTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let activeMeetingID = self.activeMeetingID, let appendSegment = self.appendSegment else { return }
                let line = self.demoLines[self.demoIndex % self.demoLines.count]
                appendSegment(
                    TranscriptSegment(
                        meetingID: activeMeetingID,
                        timestamp: TimeInterval(self.demoIndex * 14 + 3),
                        speaker: line.0,
                        sourceText: line.1,
                        translatedText: line.2,
                        kind: line.3,
                        confidence: Double.random(in: 0.86...0.98)
                    )
                )
                if line.3 == .question {
                    self.activeSuggestion = "Answer suggestion: say yes for microphone input now, then clarify that system audio needs a separate permission flow."
                }
                self.demoIndex += 1
            }
        }
    }

    func stopDemoTranscript() {
        stopSpeechRecognition(keepSession: false)
        transcriptTimer?.invalidate()
        transcriptTimer = nil
        activeMeetingID = nil
        appendSegment = nil
        updateSegment = nil
        updateSegmentTranslation = nil
        appendLog = nil
    }

    private func startSpeechRecognition() {
        guard speechTranscriber == nil, paraformerTranscriber == nil else { return }
        if isAliyunRealtimeASREnabled,
           modelConfiguration.realtimeASRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            startParaformerRecognition()
            return
        }
        startMacOSSpeechRecognition()
    }

    private var isAliyunRealtimeASREnabled: Bool {
        modelConfiguration.realtimeASRProvider == RealtimeASRProvider.aliyunRealtimeASR.rawValue
            || modelConfiguration.realtimeASRProvider == "Aliyun Paraformer"
    }

    private func startParaformerRecognition() {
        let transcriber = AliyunParaformerTranscriber()
        paraformerTranscriber = transcriber
        transcriber.start(
            configuration: modelConfiguration,
            onTranscript: { [weak self] transcript, languageID, isFinal in
                Task { @MainActor in
                    self?.emitTranscriptIfNeeded(transcript, languageID: languageID, isFinal: isFinal)
                }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in
                    self?.appendMeetingLog(status)
                }
            },
            onUnavailable: { [weak self] reason in
                Task { @MainActor in
                    guard let self else { return }
                    self.paraformerTranscriber?.stop()
                    self.paraformerTranscriber = nil
                    self.appendMeetingLog(reason, level: "warning")
                    if SpeechAuthorizationBridge.currentStatus == .authorized {
                        self.startMacOSSpeechRecognition()
                    }
                }
            }
        )
    }

    private func startMacOSSpeechRecognition() {
        guard speechTranscriber == nil else { return }
        let transcriber = LiveSpeechTranscriber()
        speechTranscriber = transcriber
        let languageIDs = liveRecognitionLanguageIDs(localLanguage: modelConfiguration.localLanguage)
        transcriber.start(
            languageIDs: languageIDs,
            onTranscript: { [weak self] transcript, languageID in
                Task { @MainActor in
                    self?.emitTranscriptIfNeeded(transcript, languageID: languageID, isFinal: false)
                }
            },
            onSilence: { [weak self] in
                Task { @MainActor in
                    self?.flushAllPendingTranscripts()
                }
            },
            onUnavailable: { [weak self] reason in
                Task { @MainActor in
                    self?.appendMeetingLog(reason, level: "warning")
                }
            }
        )
    }

    private func emitTranscriptIfNeeded(_ transcript: String, languageID: String, isFinal: Bool) {
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastEmittedTranscript = lastEmittedTranscripts[languageID] ?? ""
        guard cleanTranscript != lastEmittedTranscript,
              cleanTranscript != lastFinalizedTranscripts[languageID],
              appendSegment != nil else { return }
        guard cleanTranscript.count >= 2 else { return }
        lastEmittedTranscripts[languageID] = cleanTranscript

        updatePendingTranscript(cleanTranscript, languageID: languageID)
        if isFinal || shouldFlushTranscript(text: cleanTranscript, languageID: languageID) {
            flushPendingTranscript(languageID: languageID)
        } else {
            schedulePendingTranscriptFlush(languageID: languageID)
        }
    }

    private func updatePendingTranscript(_ transcript: String, languageID: String) {
        if activeLiveLanguageID != languageID {
            clearPendingTranscripts(except: languageID)
            activeLiveLanguageID = languageID
        }
        pendingLiveTranscripts[languageID] = transcript
        updateLiveDraft(languageID: languageID)
    }

    private func schedulePendingTranscriptFlush(languageID: String) {
        pendingLiveTranscriptTimers[languageID]?.invalidate()
        pendingLiveTranscriptTimers[languageID] = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushPendingTranscript(languageID: languageID)
            }
        }
    }

    private func shouldFlushTranscript(text: String, languageID: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "。！？?!.;；".contains(last)
    }

    private func flushPendingTranscript(languageID: String) {
        pendingLiveTranscriptTimers[languageID]?.invalidate()
        pendingLiveTranscriptTimers[languageID] = nil

        let delta = (pendingLiveTranscripts[languageID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pendingLiveTranscripts[languageID] = nil
        clearLiveDraft(languageID: languageID)
        if activeLiveLanguageID == languageID {
            activeLiveLanguageID = nil
        }
        guard delta.isEmpty == false,
              delta != lastFinalizedTranscripts[languageID],
              let activeMeetingID,
              let appendSegment else { return }
        lastFinalizedTranscripts[languageID] = delta

        let timestamp = TimeInterval(demoIndex * 8)
        demoIndex += 1
        let localLanguage = modelConfiguration.localLanguage
        let shouldTranslate = shouldTranslateFinalTranscript(languageID: languageID, localLanguage: localLanguage)

        if shouldReviseLastCommittedTranscript(with: delta),
           let lastCommittedSegmentID,
           let updateSegment {
            let speaker = "Speaker · \(languageLabel(for: languageID))"
            updateSegment(lastCommittedSegmentID, delta, delta, speaker)
            lastCommittedTranscript = delta
            lastCommittedAt = Date()
            translateCommittedSegmentIfNeeded(
                segmentID: lastCommittedSegmentID,
                text: delta,
                languageID: languageID,
                shouldTranslate: shouldTranslate,
                localLanguage: localLanguage
            )
            return
        }

        let segment = TranscriptSegment(
            meetingID: activeMeetingID,
            timestamp: timestamp,
            speaker: "Speaker · \(languageLabel(for: languageID))",
            sourceText: delta,
            translatedText: delta,
            kind: .transcript,
            confidence: 0.82
        )
        appendSegment(segment)
        lastCommittedSegmentID = segment.id
        lastCommittedTranscript = delta
        lastCommittedAt = Date()

        translateCommittedSegmentIfNeeded(
            segmentID: segment.id,
            text: delta,
            languageID: languageID,
            shouldTranslate: shouldTranslate,
            localLanguage: localLanguage
        )
    }

    private func translateCommittedSegmentIfNeeded(
        segmentID: TranscriptSegment.ID,
        text: String,
        languageID: String,
        shouldTranslate: Bool,
        localLanguage: String
    ) {
        guard shouldTranslate, let updateSegmentTranslation else { return }
        Task {
            do {
                guard let translated = try await MeetingAIClient().translateText(
                    text,
                    targetLanguage: LocalMeetingLanguage(rawValue: localLanguage)?.translationTarget ?? "Chinese (Mandarin, Simplified Chinese)",
                    configuration: modelConfiguration
                ),
                      translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      translated != text else { return }

                await MainActor.run {
                    updateSegmentTranslation(segmentID, translated)
                }
            } catch {
                await MainActor.run {
                    appendMeetingLog("Translation failed: \(error.localizedDescription)", level: "warning")
                }
            }
        }
    }

    private func shouldTranslateFinalTranscript(languageID: String, localLanguage: String) -> Bool {
        guard isTranslationModelConfigured else { return false }
        return languageFamily(for: languageID) != languageFamily(for: localLanguage)
    }

    private var isTranslationModelConfigured: Bool {
        let translationModel = modelConfiguration.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard translationModel.isEmpty == false else { return false }
        if modelConfiguration.provider == ModelProvider.ollama.rawValue ||
            modelConfiguration.provider == ModelProvider.lmStudio.rawValue {
            return true
        }
        return modelConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func languageFamily(for languageID: String) -> String {
        let normalized = languageID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalized == "auto" || normalized == "unknown" {
            return "auto"
        }
        if normalized.hasPrefix("zh") || normalized == "chinese" || normalized == "mandarin" {
            return "zh"
        }
        if normalized.hasPrefix("en") || normalized == "english" {
            return "en"
        }
        return normalized
    }

    private func shouldReviseLastCommittedTranscript(with transcript: String) -> Bool {
        guard let lastCommittedAt,
              Date().timeIntervalSince(lastCommittedAt) < 12,
              lastCommittedTranscript.isEmpty == false else { return false }
        let normalizedNew = normalizedTranscriptForOverlap(transcript)
        let normalizedLast = normalizedTranscriptForOverlap(lastCommittedTranscript)
        guard normalizedNew != normalizedLast else { return true }
        return normalizedNew.contains(normalizedLast)
            || normalizedLast.contains(normalizedNew)
            || overlapRatio(normalizedNew, normalizedLast) >= 0.62
            || longestCommonSubsequenceRatio(normalizedNew, normalizedLast) >= 0.72
            || tokenOverlapRatio(transcript, lastCommittedTranscript) >= 0.58
    }

    private func normalizedTranscriptForOverlap(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func overlapRatio(_ lhs: String, _ rhs: String) -> Double {
        guard lhs.isEmpty == false, rhs.isEmpty == false else { return 0 }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count > rhs.count ? lhs : rhs
        var best = 0
        let shorterChars = Array(shorter)
        let longerChars = Array(longer)
        for start in longerChars.indices {
            var length = 0
            while length < shorterChars.count,
                  start + length < longerChars.count,
                  shorterChars[length] == longerChars[start + length] {
                length += 1
            }
            best = max(best, length)
        }
        return Double(best) / Double(shorter.count)
    }

    private func longestCommonSubsequenceRatio(_ lhs: String, _ rhs: String) -> Double {
        guard lhs.isEmpty == false, rhs.isEmpty == false else { return 0 }
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        var previous = Array(repeating: 0, count: rhsChars.count + 1)
        var current = previous

        for lhsIndex in lhsChars.indices {
            current[0] = 0
            for rhsIndex in rhsChars.indices {
                if lhsChars[lhsIndex] == rhsChars[rhsIndex] {
                    current[rhsIndex + 1] = previous[rhsIndex] + 1
                } else {
                    current[rhsIndex + 1] = max(previous[rhsIndex + 1], current[rhsIndex])
                }
            }
            swap(&previous, &current)
        }

        let shorterLength = min(lhsChars.count, rhsChars.count)
        guard shorterLength > 0 else { return 0 }
        return Double(previous[rhsChars.count]) / Double(shorterLength)
    }

    private func tokenOverlapRatio(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(transcriptTokens(lhs))
        let rhsTokens = Set(transcriptTokens(rhs))
        guard lhsTokens.isEmpty == false, rhsTokens.isEmpty == false else { return 0 }
        let shared = lhsTokens.intersection(rhsTokens).count
        return Double(shared) / Double(min(lhsTokens.count, rhsTokens.count))
    }

    private func transcriptTokens(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private func flushAllPendingTranscripts() {
        for languageID in Array(pendingLiveTranscripts.keys) {
            flushPendingTranscript(languageID: languageID)
        }
    }

    private func updateLiveDraft(languageID: String) {
        let text = (pendingLiveTranscripts[languageID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false, let activeMeetingID else {
            clearLiveDraft(languageID: languageID)
            return
        }
        liveDraft = LiveTranscriptDraft(
            meetingID: activeMeetingID,
            languageID: languageID,
            text: text
        )
    }

    private func clearLiveDraft(languageID: String? = nil) {
        guard let languageID else {
            liveDraft = nil
            return
        }
        if liveDraft?.languageID == languageID {
            liveDraft = nil
        }
    }

    private func clearPendingTranscripts(except languageID: String) {
        for key in Array(pendingLiveTranscripts.keys) where key != languageID {
            pendingLiveTranscripts[key] = nil
            pendingLiveTranscriptTimers[key]?.invalidate()
            pendingLiveTranscriptTimers[key] = nil
        }
        if liveDraft?.languageID != languageID {
            liveDraft = nil
        }
    }

    private func liveRecognitionLanguageIDs(localLanguage: String) -> [String] {
        let alternatives = LocalMeetingLanguage.allCases
            .map(\.rawValue)
            .filter { $0 != localLanguage }
        return [localLanguage] + alternatives
    }

    private func appendMeetingLog(_ message: String, level: String = "info") {
        guard let activeMeetingID, let appendLog else { return }
        appendLog(MeetingLogEntry(meetingID: activeMeetingID, message: message, level: level))
    }

    private func stopSpeechRecognition(keepSession: Bool) {
        flushAllPendingTranscripts()
        pendingLiveTranscriptTimers.values.forEach { $0.invalidate() }
        pendingLiveTranscriptTimers = [:]
        speechTranscriber?.stop()
        speechTranscriber = nil
        paraformerTranscriber?.stop()
        paraformerTranscriber = nil
        if keepSession == false {
            lastEmittedTranscripts = [:]
            pendingLiveTranscripts = [:]
            lastFinalizedTranscripts = [:]
            activeLiveLanguageID = nil
            lastCommittedSegmentID = nil
            lastCommittedTranscript = ""
            lastCommittedAt = nil
            clearLiveDraft()
        }
    }

    private func languageLabel(for languageID: String) -> String {
        if languageID == "auto" {
            return "Auto"
        }
        return LocalMeetingLanguage(rawValue: languageID)?.label ?? languageID
    }
}

struct MeetingAIClient {
    private struct ChatCompletionRequest: Codable {
        struct Message: Codable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ChatCompletionResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
    }

    func summarizeMeeting(
        meeting: Meeting,
        participants: [Participant],
        segments: [TranscriptSegment],
        configuration: ModelConfiguration
    ) async throws -> String? {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryModel = configuration.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false, summaryModel.isEmpty == false else { return nil }

        let transcript = segments
            .map { segment in
                let source = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                return "[\(segment.timestamp.clockString)] \(segment.speaker): \(source)"
            }
            .joined(separator: "\n\n")
        let participantList = participants.map(\.name).joined(separator: ", ")
        let localLanguage = LocalMeetingLanguage(rawValue: configuration.localLanguage) ?? .mandarinChinese
        let prompt = """
        Generate concise meeting minutes in Markdown.
        Output language: \(localLanguage.translationTarget). You must write every section in \(localLanguage.translationTarget).
        Use only the original transcript text as source context. Do not use translated transcript text even if it exists in the UI.
        Return raw Markdown only. Do not wrap the result in triple backticks or a code block.

        Meeting: \(meeting.title)
        Time: \(meeting.scheduledAt.formatted(date: .complete, time: .shortened))
        Participants: \(participantList.isEmpty ? "Unknown" : participantList)

        Transcript:
        \(transcript.isEmpty ? "No transcript captured." : transcript)

        Include:
        - Executive summary
        - Decisions
        - Action items with owners if inferable
        - Open questions
        """

        let request = ChatCompletionRequest(
            model: summaryModel,
            messages: [
                .init(role: "system", content: "You are a precise meeting minutes assistant. Use only original transcript text as source context. Always write the final minutes entirely in \(localLanguage.translationTarget). Return raw Markdown only, never fenced code blocks."),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.2
        )

        let endpoint = configuration.apiBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .appending("/chat/completions")
        guard let url = URL(string: endpoint) else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) == false {
            return nil
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return decoded.choices.first?.message.content
    }

    func translateText(_ text: String, targetLanguage: String, configuration: ModelConfiguration) async throws -> String? {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let translationModel = configuration.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard translationModel.isEmpty == false else { return nil }
        if apiKey.isEmpty,
           configuration.provider != ModelProvider.ollama.rawValue,
           configuration.provider != ModelProvider.lmStudio.rawValue {
            return nil
        }

        let messages: [ChatCompletionRequest.Message]
        if translationModel.lowercased().hasPrefix("qwen-mt") {
            messages = [
                .init(role: "user", content: """
                Translate the following meeting transcript into \(targetLanguage).
                If the source text is already in \(targetLanguage), return exactly __NO_TRANSLATION__.
                Return only the translation or that sentinel.

                \(text)
                """)
            ]
        } else {
            messages = [
                .init(role: "system", content: "Translate the user's meeting transcript into \(targetLanguage). If the source text is already in \(targetLanguage), return exactly __NO_TRANSLATION__. Return only the translation or that sentinel."),
                .init(role: "user", content: text)
            ]
        }

        let request = ChatCompletionRequest(
            model: translationModel,
            messages: messages,
            temperature: 0.1
        )

        let endpoint = configuration.apiBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .appending("/chat/completions")
        guard let url = URL(string: endpoint) else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if apiKey.isEmpty == false {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) == false {
            return nil
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let translated = decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if translated == "__NO_TRANSLATION__" {
            return nil
        }
        return translated
    }
}
