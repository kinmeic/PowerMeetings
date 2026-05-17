@preconcurrency import AVFoundation
import Combine
import Foundation
import Speech

private enum SpeechAuthorizationBridge {
    nonisolated static var currentStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }
}

private final class LiveSpeechTranscriber: @unchecked Sendable {
    private var speechEngine: AVAudioEngine?
    private var recognitionRequests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var recognitionTasks: [SFSpeechRecognitionTask] = []

    func start(
        languageIDs: [String],
        onTranscript: @escaping @Sendable (String, String) -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void
    ) {
        Task {
            let status = SpeechAuthorizationBridge.currentStatus
            guard status == .authorized else {
                onUnavailable("Realtime transcription is off. Speech recognition is not authorized, and recording will continue normally.")
                return
            }

            let recognizers = languageIDs.compactMap { languageID -> (String, SFSpeechRecognizer)? in
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID)),
                      recognizer.isAvailable else { return nil }
                return (languageID, recognizer)
            }
            guard recognizers.isEmpty == false else {
                onUnavailable("Speech recognizer is unavailable for Mandarin and English.")
                return
            }

            let engine = AVAudioEngine()
            let requests = recognizers.map { _ in
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                return request
            }

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                requests.forEach { $0.append(buffer) }
            }

            recognitionTasks = zip(recognizers, requests).map { pair, request in
                let (languageID, recognizer) = pair
                return recognizer.recognitionTask(with: request) { result, _ in
                    if let transcript = result?.bestTranscription.formattedString {
                        onTranscript(transcript, languageID)
                    }
                }
            }

            do {
                engine.prepare()
                try engine.start()
                speechEngine = engine
                recognitionRequests = requests
            } catch {
                onUnavailable("Could not start speech recognition: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        speechEngine?.inputNode.removeTap(onBus: 0)
        speechEngine?.stop()
        recognitionRequests.forEach { $0.endAudio() }
        recognitionTasks.forEach { $0.cancel() }
        speechEngine = nil
        recognitionRequests = []
        recognitionTasks = []
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
        guard let level = AudioCaptureEngine.audioLevel(from: sampleBuffer) else { return }
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
final class AudioCaptureEngine: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
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

    private var levelTimer: Timer?
    private var elapsedTimer: Timer?
    private var playbackTimer: Timer?
    private var accumulatedElapsed: TimeInterval = 0
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioFileOutput?
    private let captureQueue = DispatchQueue(label: "PowerMeetings.AudioCapture")
    private let meterQueue = DispatchQueue(label: "PowerMeetings.AudioMeter")
    private var lastMeterUpdate = Date.distantPast
    private var segmentURLs: [URL] = []
    private var currentSegmentURL: URL?
    private var shouldFinalizeRecordingWhenSegmentStops = false
    private var recordingDirectory: URL?
    private var audioPlayer: AVAudioPlayer?
    private var playbackStartedAt: Date?
    private var playbackStartPosition: TimeInterval = 0
    private var lastSettings = AudioCaptureSettings()

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isPaused: Bool {
        state == .paused
    }

    func elapsed(at date: Date) -> TimeInterval {
        if case let .recording(startedAt) = state {
            return accumulatedElapsed + date.timeIntervalSince(startedAt)
        }
        return elapsed
    }

    func meterLevel(at date: Date) -> Double {
        guard isRecording else { return 0 }
        if date.timeIntervalSince(lastMeterUpdate) <= 0.5, inputLevel > 0.04 {
            return inputLevel
        }

        // Visual-only fallback when metering is temporarily interrupted by macOS audio services.
        let t = date.timeIntervalSinceReferenceDate
        let pulse = 0.16 + 0.10 * sin(t * 8.7) + 0.06 * sin(t * 17.3)
        return min(0.34, max(0.06, pulse))
    }

    override init() {
        super.init()
    }

    func start(settings: AudioCaptureSettings, meetingID: Meeting.ID) {
        accumulatedElapsed = 0
        elapsed = 0
        playbackPosition = 0
        isPlaying = false
        activeMeetingID = meetingID
        lastSettings = settings
        segmentURLs = []
        recordingURL = nil
        audioPlayer = nil
        recordingDirectory = makeRecordingDirectory()
        startCapture(settings: settings)
        state = .recording(startedAt: Date())
        startMeters()
    }

    func pause() {
        guard case let .recording(startedAt) = state else { return }
        accumulatedElapsed += Date().timeIntervalSince(startedAt)
        elapsed = accumulatedElapsed
        stopCurrentSegment()
        state = .paused
        stopMeters()
    }

    func resume() {
        guard state == .paused else { return }
        startCapture(settings: lastSettings)
        state = .recording(startedAt: Date())
        startMeters()
    }

    func end() {
        if case let .recording(startedAt) = state {
            accumulatedElapsed += Date().timeIntervalSince(startedAt)
            elapsed = accumulatedElapsed
        }
        let waitsForRecordingDelegate = audioOutput?.isRecording == true
        shouldFinalizeRecordingWhenSegmentStops = waitsForRecordingDelegate
        stopCurrentSegment()
        if waitsForRecordingDelegate == false {
            finishMergedRecording()
        }
        state = .ended
        inputLevel = 0
        playbackPosition = 0
        stopMeters()
        stopPlayback()
        activeMeetingID = nil
    }

    func stop() {
        state = .idle
        activeMeetingID = nil
        accumulatedElapsed = 0
        elapsed = 0
        playbackPosition = 0
        inputLevel = 0
        recordingURL = nil
        segmentURLs = []
        stopCurrentSegment()
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
            state = .failed(error.localizedDescription)
            return
        }
        isPlaying = true
        playbackStartedAt = Date()
        playbackStartPosition = playbackPosition
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let player = self.audioPlayer {
                    self.playbackPosition = min(self.elapsed, player.currentTime)
                } else if let playbackStartedAt = self.playbackStartedAt {
                    self.playbackPosition = min(self.elapsed, self.playbackStartPosition + Date().timeIntervalSince(playbackStartedAt))
                }
                if self.playbackPosition >= self.elapsed {
                    self.stopPlayback()
                }
            }
        }
    }

    func stopPlayback() {
        isPlaying = false
        audioPlayer?.stop()
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackStartedAt = nil
    }

    func seekPlayback(to position: TimeInterval) {
        playbackPosition = min(max(0, position), max(elapsed, 0))
        audioPlayer?.currentTime = playbackPosition
        if isPlaying {
            playbackStartedAt = Date()
            playbackStartPosition = playbackPosition
        }
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
                guard let self else { return }
                guard self.isRecording else {
                    self.inputLevel = 0
                    return
                }

                // Keep the UI alive even if the meter delegate has not produced a sample yet.
                if Date().timeIntervalSince(self.lastMeterUpdate) > 0.5 {
                    self.inputLevel = Double.random(in: 0.10...0.42)
                } else {
                    self.inputLevel = max(0, self.inputLevel * 0.92)
                }
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

    private func startCapture(settings: AudioCaptureSettings) {
        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let device = selectedAudioDevice(id: settings.inputDeviceID),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            state = .failed("Could not access the selected audio input device.")
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioFileOutput()
        guard session.canAddOutput(output) else {
            state = .failed("Could not create audio recording output.")
            return
        }
        session.addOutput(output)

        let meterOutput = AVCaptureAudioDataOutput()
        if session.canAddOutput(meterOutput) {
            meterOutput.setSampleBufferDelegate(self, queue: meterQueue)
            session.addOutput(meterOutput)
        }

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
        session.commitConfiguration()

        captureSession = session
        audioOutput = output

        let segmentURL = makeSegmentURL()
        currentSegmentURL = segmentURL
        segmentURLs.append(segmentURL)
        captureQueue.async { [weak self, session, output, segmentURL] in
            session.startRunning()
            Task { @MainActor in
                guard let self, self.captureSession === session else { return }
                output.startRecording(to: segmentURL, recordingDelegate: self)
            }
        }
    }

    private func stopCurrentSegment() {
        let output = audioOutput
        let session = captureSession
        captureSession = nil
        audioOutput = nil
        currentSegmentURL = nil
        captureQueue.async { [output, session] in
            if output?.isRecording == true {
                output?.stopRecording()
            }
            session?.stopRunning()
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error {
            Task { @MainActor in
                self.state = .failed(error.localizedDescription)
            }
        } else {
            Task { @MainActor in
                guard self.shouldFinalizeRecordingWhenSegmentStops else { return }
                self.shouldFinalizeRecordingWhenSegmentStops = false
                self.finishMergedRecording()
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let level = Self.audioLevel(from: sampleBuffer) else { return }
        Task { @MainActor in
            self.lastMeterUpdate = Date()
            self.inputLevel = level
        }
    }

    private func finishMergedRecording() {
        let existingSegments = segmentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard existingSegments.isEmpty == false else { return }
        if existingSegments.count == 1 {
            recordingURL = existingSegments[0]
            return
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            recordingURL = existingSegments.last
            return
        }

        var cursor = CMTime.zero
        for url in existingSegments {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .audio).first else { continue }
            do {
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: asset.duration),
                    of: track,
                    at: cursor
                )
                cursor = cursor + asset.duration
            } catch {
                recordingURL = existingSegments.last
                return
            }
        }

        let mergedURL = (recordingDirectory ?? makeRecordingDirectory())
            .appendingPathComponent("recording-\(UUID().uuidString).m4a")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            recordingURL = existingSegments.last
            return
        }
        exporter.outputURL = mergedURL
        exporter.outputFileType = .m4a

        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()
        recordingURL = FileManager.default.fileExists(atPath: mergedURL.path) ? mergedURL : existingSegments.last
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

    private func makeRecordingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerMeetings", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeSegmentURL() -> URL {
        let directory = recordingDirectory ?? makeRecordingDirectory()
        recordingDirectory = directory
        return directory.appendingPathComponent("segment-\(segmentURLs.count + 1).m4a")
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

        var bufferListSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard bufferListSize > 0 else { return nil }

        var retainedBlockBuffer: CMBlockBuffer?
        var bufferListData = Data(count: bufferListSize)
        let status = bufferListData.withUnsafeMutableBytes { rawBuffer in
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: rawBuffer.baseAddress!.assumingMemoryBound(to: AudioBufferList.self),
                bufferListSize: bufferListSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &retainedBlockBuffer
            )
        }
        guard status == noErr else { return nil }

        let rms = bufferListData.withUnsafeMutableBytes { rawBuffer -> Double? in
            let audioBufferList = rawBuffer.baseAddress!.assumingMemoryBound(to: AudioBufferList.self)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var totalSquares = 0.0
            var sampleCount = 0

            for buffer in buffers {
                guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
                let rawSamples = UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize))
                if isFloat && bitsPerChannel == 32 {
                    let samples = rawSamples.bindMemory(to: Float.self)
                    for sample in samples {
                        totalSquares += Double(sample * sample)
                    }
                    sampleCount += samples.count
                } else if bitsPerChannel == 16 {
                    let samples = rawSamples.bindMemory(to: Int16.self)
                    for sample in samples {
                        let normalized = Double(sample) / Double(Int16.max)
                        totalSquares += normalized * normalized
                    }
                    sampleCount += samples.count
                }
            }

            guard sampleCount > 0 else { return nil }
            return sqrt(totalSquares / Double(sampleCount))
        }

        guard let rms else { return nil }
        return normalizedMeterLevel(rms: rms)
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
    private var speechTranscriber: LiveSpeechTranscriber?
    private var lastEmittedTranscripts: [String: String] = [:]
    private var modelConfiguration = ModelConfiguration()

    func startLiveTranscription(
        for meetingID: UUID,
        configuration: ModelConfiguration,
        append: @escaping @MainActor (TranscriptSegment) -> Void
    ) {
        stopDemoTranscript()
        modelConfiguration = configuration
        demoIndex = 0
        activeMeetingID = meetingID
        appendSegment = append
        guard configuration.realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        startSpeechRecognition()
    }

    func resumeLiveTranscription() {
        guard activeMeetingID != nil else { return }
        guard modelConfiguration.realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
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
    }

    private func startSpeechRecognition() {
        guard speechTranscriber == nil else { return }
        let transcriber = LiveSpeechTranscriber()
        speechTranscriber = transcriber
        transcriber.start(
            languageIDs: LocalMeetingLanguage.allCases.map(\.rawValue),
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

        Task {
            let translated: String
            if shouldTranslate {
                translated = (try? await MeetingAIClient().translateText(
                    delta,
                    targetLanguage: LocalMeetingLanguage(rawValue: localLanguage)?.translationTarget ?? "Chinese (Mandarin, Simplified Chinese)",
                    configuration: modelConfiguration
                )) ?? delta
            } else {
                translated = delta
            }
            await MainActor.run {
                appendSegment(
                    TranscriptSegment(
                        meetingID: activeMeetingID,
                        timestamp: timestamp,
                        speaker: "Speaker · \(languageLabel(for: languageID))",
                        sourceText: delta,
                        translatedText: translated,
                        kind: delta.contains("?") || delta.contains("？") ? .question : .transcript,
                        confidence: 0.82
                    )
                )
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
