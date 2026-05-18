@preconcurrency import AVFoundation
import Combine
import Foundation
import Speech

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

private final class LiveSpeechTranscriber: @unchecked Sendable {
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(
        languageIDs: [String],
        onTranscript: @escaping @Sendable (String, String) -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        let status = SpeechAuthorizationBridge.currentStatus
        guard status == .authorized else {
            onUnavailable("Realtime transcription is off. Speech recognition is not authorized, and recording will continue normally.")
            return
        }

        guard let languageID = languageIDs.first,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID)) else {
            onUnavailable("Speech recognizer is unavailable for the selected local language.")
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            onUnavailable("On-device Speech Recognition is not available for \(languageID) on this Mac. Recording will continue normally.")
            return
        }

        guard recognizer.isAvailable else {
            onUnavailable("On-device Speech Recognition is unavailable right now. Recording will continue normally.")
            return
        }

        // On-device live transcription will be wired through SpeechAnalyzer; keep recording independent.
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
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
    private var audioPlayer: AVAudioPlayer?
    private var levelTimer: Timer?
    private var elapsedTimer: Timer?
    private var playbackTimer: Timer?
    private var accumulatedElapsed: TimeInterval = 0
    private var lastSettings = AudioCaptureSettings()
    var onRecordingReady: (@MainActor (URL, TimeInterval) -> Void)?

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

        let url = makeRecordingDirectory().appendingPathComponent("recording-\(UUID().uuidString).m4a")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                state = .failed("Could not start the audio recorder.")
                activeMeetingID = nil
                return false
            }
            audioRecorder = recorder
            recordingURL = url
        } catch {
            state = .failed("Could not start recording: \(error.localizedDescription)")
            activeMeetingID = nil
            return false
        }

        state = .recording(startedAt: Date())
        startMeters()
        return true
    }

    func pause() {
        guard case let .recording(startedAt) = state else { return }
        accumulatedElapsed += Date().timeIntervalSince(startedAt)
        elapsed = accumulatedElapsed
        audioRecorder?.pause()
        state = .paused
        stopMeters()
        inputLevel = 0
    }

    @discardableResult
    func resume() -> Bool {
        guard state == .paused, let recorder = audioRecorder else { return false }
        guard recorder.record() else {
            state = .failed("Could not resume recording.")
            return false
        }
        state = .recording(startedAt: Date())
        startMeters()
        return true
    }

    func end() {
        if case let .recording(startedAt) = state {
            accumulatedElapsed += Date().timeIntervalSince(startedAt)
            elapsed = accumulatedElapsed
        }
        audioRecorder?.stop()
        audioRecorder = nil
        state = .ended
        inputLevel = 0
        playbackPosition = 0
        stopMeters()
        stopPlayback()
        activeMeetingID = nil
        notifyRecordingReadyIfNeeded()
    }

    func stop() {
        audioRecorder?.stop()
        audioRecorder = nil
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

    private func notifyRecordingReadyIfNeeded() {
        guard let recordingURL else { return }
        onRecordingReady?(recordingURL, elapsed)
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

@MainActor
final class MeetingSessionViewModel: ObservableObject {
    @Published var draftQuestion = ""
    @Published var activeSuggestion = "Start recording and I will surface likely questions, objections, and useful reply angles here."

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
    private var speechTranscriber: LiveSpeechTranscriber?
    private var lastEmittedTranscripts: [String: String] = [:]
    private var modelConfiguration = ModelConfiguration()

    func startLiveTranscription(
        for meetingID: UUID,
        configuration: ModelConfiguration,
        append: @escaping @MainActor (TranscriptSegment) -> Void,
        updateTranslation: @escaping @MainActor (TranscriptSegment.ID, String) -> Void
    ) {
        stopDemoTranscript()
        modelConfiguration = configuration
        demoIndex = 0
        activeMeetingID = meetingID
        appendSegment = append
        updateSegmentTranslation = updateTranslation
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
        updateSegmentTranslation = nil
    }

    private func startSpeechRecognition() {
        guard speechTranscriber == nil else { return }
        let transcriber = LiveSpeechTranscriber()
        speechTranscriber = transcriber
        transcriber.start(
            languageIDs: [modelConfiguration.localLanguage],
            onTranscript: { [weak self] transcript, languageID in
                Task { @MainActor in
                    self?.emitTranscriptIfNeeded(transcript, languageID: languageID)
                }
            },
            onUnavailable: { [weak self] reason in
                Task { @MainActor in
                    self?.appendSpeechUnavailableSegment(reason: reason)
                }
            }
        )
    }

    private func emitTranscriptIfNeeded(_ transcript: String, languageID: String) {
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastEmittedTranscript = lastEmittedTranscripts[languageID] ?? ""
        guard cleanTranscript.count > lastEmittedTranscript.count + 12,
              let activeMeetingID,
              let appendSegment else { return }

        let delta: String
        if cleanTranscript.hasPrefix(lastEmittedTranscript) {
            delta = String(cleanTranscript.dropFirst(lastEmittedTranscript.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            delta = cleanTranscript
        }
        guard delta.isEmpty == false else { return }
        lastEmittedTranscripts[languageID] = cleanTranscript

        let timestamp = TimeInterval(demoIndex * 8)
        demoIndex += 1
        let localLanguage = modelConfiguration.localLanguage
        let hasTranslationConfiguration = modelConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && modelConfiguration.translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let shouldTranslate = languageID != localLanguage && hasTranslationConfiguration

        let segment = TranscriptSegment(
            meetingID: activeMeetingID,
            timestamp: timestamp,
            speaker: "Speaker · \(languageLabel(for: languageID))",
            sourceText: delta,
            translatedText: delta,
            kind: delta.contains("?") || delta.contains("？") ? .question : .transcript,
            confidence: 0.82
        )
        appendSegment(segment)

        guard shouldTranslate, let updateSegmentTranslation else { return }
        Task {
            guard let translated = try? await MeetingAIClient().translateText(
                delta,
                targetLanguage: LocalMeetingLanguage(rawValue: localLanguage)?.translationTarget ?? "Chinese (Mandarin, Simplified Chinese)",
                configuration: modelConfiguration
            ),
                  translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  translated != delta else { return }

            await MainActor.run {
                updateSegmentTranslation(segment.id, translated)
            }
        }
    }

    private func appendSpeechUnavailableSegment(reason: String) {
        guard let activeMeetingID, let appendSegment else { return }
        appendSegment(
            TranscriptSegment(
                meetingID: activeMeetingID,
                timestamp: 0,
                speaker: "System",
                sourceText: reason,
                translatedText: reason,
                kind: .transcript,
                confidence: 1
            )
        )
    }

    private func stopSpeechRecognition(keepSession: Bool) {
        speechTranscriber?.stop()
        speechTranscriber = nil
        if keepSession == false {
            lastEmittedTranscripts = [:]
        }
    }

    private func languageLabel(for languageID: String) -> String {
        LocalMeetingLanguage(rawValue: languageID)?.label ?? languageID
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
                let translated = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if translated.isEmpty || translated == source {
                    return "[\(segment.timestamp.clockString)] \(segment.speaker): \(source)"
                }
                return "[\(segment.timestamp.clockString)] \(segment.speaker): \(source)\nTranslation: \(translated)"
            }
            .joined(separator: "\n\n")
        let participantList = participants.map(\.name).joined(separator: ", ")
        let localLanguage = LocalMeetingLanguage(rawValue: configuration.localLanguage) ?? .mandarinChinese
        let prompt = """
        Generate concise meeting minutes in Markdown.
        Output language: \(localLanguage.translationTarget).
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
                .init(role: "system", content: "You are a precise meeting minutes assistant. Always write the final minutes in \(localLanguage.translationTarget). Return raw Markdown only, never fenced code blocks."),
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
        guard apiKey.isEmpty == false else { return nil }

        let request = ChatCompletionRequest(
            model: configuration.translationModel,
            messages: [
                .init(role: "system", content: "Translate the user's meeting transcript into \(targetLanguage). Return only the translation."),
                .init(role: "user", content: text)
            ],
            temperature: 0.1
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
}
