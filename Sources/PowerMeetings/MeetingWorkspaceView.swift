import MarkdownUI
import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

struct MeetingWorkspaceView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @StateObject private var audioEngine = AudioCaptureEngine()
    @StateObject private var session = MeetingSessionViewModel()
    @State private var selectedTab = "Live"
    @State private var summaryTask: Task<Void, Never>?
    @State private var isTranscribingRecording = false

    var body: some View {
        VStack(spacing: 18) {
            if let meeting = meetingStore.selectedMeeting {
                MeetingHeaderView(meeting: meeting)
                AudioControlBar(
                    meetingStatus: meeting.status,
                    canStartMeeting: meetingStore.canStartMeeting(id: meeting.id),
                    audioEngine: audioEngine,
                    displayedElapsed: displayedElapsed(for: meeting),
                    isUsingLiveAudioEngine: audioEngine.activeMeetingID == meeting.id,
                    onStartMeeting: { startMeeting(meeting: meeting) },
                    onPause: { pauseMeeting(meeting: meeting) },
                    onResume: { resumeMeeting(meeting: meeting) },
                    onEndMeeting: { endMeeting(meeting: meeting) },
                    onPlay: { audioEngine.play() },
                    onStopPlayback: { audioEngine.stopPlayback() },
                    onSeekPlayback: { audioEngine.seekPlayback(to: $0) },
                    onExport: { exportRecording() }
                )

                if let issue = currentStatusIssue(for: meeting) {
                    MeetingStatusBanner(
                        issue: issue,
                        onOpenSettings: openSettings,
                        onViewLogs: { selectedTab = "Log" }
                    )
                }

                Picker("", selection: $selectedTab) {
                    Text(AppText.t("live", language: modelSettings.localLanguage)).tag("Live")
                    Text(AppText.t("people", language: modelSettings.localLanguage)).tag("People")
                    Text(AppText.t("summary", language: modelSettings.localLanguage)).tag("Summary")
                    Text(AppText.t("log", language: modelSettings.localLanguage)).tag("Log")
                }
                .pickerStyle(.segmented)

                if selectedTab == "Live" {
                    TranscriptTimelineView(
                        meeting: meeting,
                        segments: meetingStore.selectedMeetingSegments,
                        liveDraft: session.liveDraft,
                        modelConfiguration: modelSettings.configuration,
                        isTranscribingRecording: isTranscribingRecording,
                        onTranscribeRecording: { transcribeRecording(meeting: meeting) }
                    )
                } else if selectedTab == "Summary" {
                    SummaryView(meeting: meeting)
                } else if selectedTab == "People" {
                    ParticipantsView(meeting: meeting)
                } else {
                    MeetingLogView(logs: meetingStore.selectedMeetingLogs)
                }
            } else {
                ContentUnavailableView(AppText.t("noMeetingSelected", language: modelSettings.localLanguage), systemImage: "calendar.badge.clock")
            }
        }
        .padding(22)
        .background(AppTheme.background)
        .onAppear {
            syncSelectedRecording()
        }
        .onChange(of: meetingStore.selectedMeetingID) { _, _ in
            syncSelectedRecording()
        }
    }

    private func startMeeting(meeting: Meeting) {
        guard meetingStore.canStartMeeting(id: meeting.id) else { return }
        audioEngine.onEvent = { message, level in
            meetingStore.appendLog(MeetingLogEntry(meetingID: meeting.id, message: message, level: level))
        }
        let settings = AudioCaptureSettings(
            inputDeviceID: audioDeviceManager.selectedDeviceID,
            enableSystemAudio: modelSettings.systemAudioCaptureEnabled,
            enableNoiseSuppression: modelSettings.noiseSuppressionEnabled
        )
        guard audioEngine.start(settings: settings, meetingID: meeting.id) else {
            meetingStore.appendLog(
                MeetingLogEntry(
                    meetingID: meeting.id,
                    message: audioEngine.failureMessage ?? "Recording could not start.",
                    level: "error"
                )
            )
            return
        }
        session.startLiveTranscription(
            for: meeting.id,
            configuration: modelSettings.configuration,
            append: { segment in
                meetingStore.appendSegment(segment)
            },
            updateSegment: { id, sourceText, translatedText, speaker in
                meetingStore.updateSegment(id: id) {
                    $0.sourceText = sourceText
                    $0.translatedText = translatedText
                    $0.speaker = speaker
                }
            },
            updateTranslation: { id, translatedText in
                meetingStore.updateSegmentTranslation(id: id, translatedText: translatedText)
            },
            appendLog: { entry in
                meetingStore.appendLog(entry)
            }
        )
        meetingStore.updateMeeting(id: meeting.id) { $0.status = .inProgress }
    }

    private func pauseMeeting(meeting: Meeting) {
        audioEngine.pause()
        session.pauseLiveTranscription()
        meetingStore.updateMeeting(id: meeting.id) {
            $0.status = .paused
        }
    }

    private func resumeMeeting(meeting: Meeting) {
        guard audioEngine.resume() else { return }
        session.resumeLiveTranscription()
        meetingStore.updateMeeting(id: meeting.id) {
            $0.status = .inProgress
        }
    }

    private func endMeeting(meeting: Meeting) {
        audioEngine.onRecordingReady = { url, duration in
            meetingStore.updateMeeting(id: meeting.id) {
                $0.recordingFilePath = url.path
                $0.duration = duration
            }
        }
        audioEngine.end()
        session.stopDemoTranscript()
        let duration = audioEngine.elapsed
        selectedTab = "Summary"
        meetingStore.updateMeeting(id: meeting.id) {
            $0.status = .completed
            let trimmedSummary = $0.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSummary.isEmpty || trimmedSummary == "No summary yet." || trimmedSummary == "暂无总结。" {
                $0.summary = AppText.t("noSummaryAction", language: modelSettings.localLanguage)
            }
            $0.duration = duration
        }
        summaryTask?.cancel()
    }

    private func exportRecording() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = "\(meetingStore.selectedMeeting?.title ?? "Meeting Recording").m4a"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try audioEngine.exportRecording(to: url)
                } catch {
                    meetingStore.updateSelectedMeeting {
                        $0.summary += "\n\nExport failed: \(error.localizedDescription)"
                    }
                }
            }
        }
        #endif
    }

    private func syncSelectedRecording() {
        guard let meeting = meetingStore.selectedMeeting else { return }
        if meeting.status == .completed {
            audioEngine.loadCompletedRecording(path: meeting.recordingFilePath, duration: meeting.duration)
        } else if audioEngine.activeMeetingID != meeting.id {
            audioEngine.stopPlayback()
        }
    }

    private func displayedElapsed(for meeting: Meeting) -> TimeInterval {
        if audioEngine.activeMeetingID == meeting.id {
            return audioEngine.elapsed
        }
        return meeting.duration ?? 0
    }

    private func transcribeRecording(meeting: Meeting) {
        guard isTranscribingRecording == false,
              let path = meeting.recordingFilePath,
              FileManager.default.fileExists(atPath: path) else { return }

        isTranscribingRecording = true
        Task {
            do {
                let text = try await PostMeetingTranscriber().transcribe(
                    url: URL(fileURLWithPath: path),
                    languageID: modelSettings.localLanguage
                )
                await MainActor.run {
                    meetingStore.appendSegment(
                        TranscriptSegment(
                            meetingID: meeting.id,
                            timestamp: 0,
                            speaker: "Recording",
                            sourceText: text,
                            translatedText: text,
                            kind: .transcript,
                            confidence: 0.8
                        )
                    )
                    isTranscribingRecording = false
                }
            } catch {
                await MainActor.run {
                    meetingStore.appendSegment(
                        TranscriptSegment(
                            meetingID: meeting.id,
                            timestamp: 0,
                            speaker: "System",
                            sourceText: "Recording transcription failed: \(error.localizedDescription)",
                            translatedText: "Recording transcription failed: \(error.localizedDescription)",
                            kind: .transcript,
                            confidence: 1
                        )
                    )
                    isTranscribingRecording = false
                }
            }
        }
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .powerMeetingsOpenSettings, object: nil)
    }

    private func currentStatusIssue(for meeting: Meeting) -> MeetingStatusIssue? {
        if let failureMessage = audioEngine.failureMessage {
            return MeetingStatusIssue(
                severity: .critical,
                title: AppText.t("statusNeedsAttention", language: modelSettings.localLanguage),
                message: "\(AppText.t("microphoneIssue", language: modelSettings.localLanguage)) \(failureMessage)",
                showSettingsAction: true,
                showLogAction: true
            )
        }

        let warningLogs = meetingStore.selectedMeetingLogs
            .filter(\.isWarningOrError)
            .sorted { $0.createdAt > $1.createdAt }
        if let systemAudioWarning = warningLogs.first(where: { $0.message.localizedCaseInsensitiveContains("system audio") }) {
            return MeetingStatusIssue(
                severity: .warning,
                title: AppText.t("statusDegraded", language: modelSettings.localLanguage),
                message: "\(AppText.t("systemAudioIssue", language: modelSettings.localLanguage)) \(systemAudioWarning.message)",
                showSettingsAction: false,
                showLogAction: true
            )
        }

        if meeting.status == .inProgress || meeting.status == .paused {
            if realtimeASRNeedsConfiguration {
                return MeetingStatusIssue(
                    severity: .warning,
                    title: AppText.t("statusDegraded", language: modelSettings.localLanguage),
                    message: "\(AppText.t("asrConfigIssue", language: modelSettings.localLanguage)) \(AppText.t("recordingSafe", language: modelSettings.localLanguage))",
                    showSettingsAction: true,
                    showLogAction: false
                )
            }

            if macOSSpeechNeedsAuthorization {
                return MeetingStatusIssue(
                    severity: .warning,
                    title: AppText.t("statusDegraded", language: modelSettings.localLanguage),
                    message: "\(AppText.t("speechPermissionIssue", language: modelSettings.localLanguage)) \(AppText.t("recordingSafe", language: modelSettings.localLanguage))",
                    showSettingsAction: true,
                    showLogAction: true
                )
            }

            if translationNeedsConfiguration {
                return MeetingStatusIssue(
                    severity: .info,
                    title: AppText.t("statusInfo", language: modelSettings.localLanguage),
                    message: AppText.t("translationConfigIssue", language: modelSettings.localLanguage),
                    showSettingsAction: true,
                    showLogAction: false
                )
            }
        }

        if let latestWarning = warningLogs.first {
            return MeetingStatusIssue(
                severity: latestWarning.level.lowercased() == "error" ? .critical : .warning,
                title: latestWarning.level.lowercased() == "error"
                    ? AppText.t("statusNeedsAttention", language: modelSettings.localLanguage)
                    : AppText.t("statusDegraded", language: modelSettings.localLanguage),
                message: latestWarning.message,
                showSettingsAction: false,
                showLogAction: true
            )
        }

        return nil
    }

    private var realtimeASRNeedsConfiguration: Bool {
        let provider = modelSettings.realtimeASRProvider
        guard provider == RealtimeASRProvider.aliyunRealtimeASR.rawValue || provider == "Aliyun Paraformer" else {
            return false
        }
        return modelSettings.realtimeASRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var macOSSpeechNeedsAuthorization: Bool {
        modelSettings.realtimeASRProvider == RealtimeASRProvider.macOSSpeech.rawValue
            && SpeechAuthorizationBridge.currentStatus != .authorized
    }

    private var translationNeedsConfiguration: Bool {
        let translationModel = modelSettings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard translationModel.isEmpty == false else { return true }
        if modelSettings.provider == ModelProvider.ollama.rawValue || modelSettings.provider == ModelProvider.lmStudio.rawValue {
            return false
        }
        return modelSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct MeetingStatusIssue: Equatable {
    enum Severity {
        case critical
        case warning
        case info
    }

    var severity: Severity
    var title: String
    var message: String
    var showSettingsAction: Bool
    var showLogAction: Bool

    var icon: String {
        switch severity {
        case .critical:
            "exclamationmark.octagon.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .info:
            "info.circle.fill"
        }
    }

    var color: Color {
        switch severity {
        case .critical:
            .red
        case .warning:
            AppTheme.amber
        case .info:
            AppTheme.moss
        }
    }
}

private struct MeetingStatusBanner: View {
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let issue: MeetingStatusIssue
    let onOpenSettings: () -> Void
    let onViewLogs: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.icon)
                .font(.title3)
                .foregroundStyle(issue.color)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.callout.bold())
                    .foregroundStyle(AppTheme.ink)
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if issue.showSettingsAction {
                    Button(AppText.t("openSettings", language: modelSettings.localLanguage), action: onOpenSettings)
                        .buttonStyle(.borderless)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(issue.color.opacity(0.14), in: Capsule())
                        .foregroundStyle(issue.color)
                }

                if issue.showLogAction {
                    Button(AppText.t("viewLogs", language: modelSettings.localLanguage), action: onViewLogs)
                        .buttonStyle(.borderless)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.72), in: Capsule())
                        .foregroundStyle(AppTheme.ink)
                }
            }
        }
        .padding(14)
        .background(issue.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(issue.color.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct MeetingHeaderView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let meeting: Meeting
    @State private var isEditingName = false
    @State private var draftTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Text(AppText.meetingDateTime(meeting.scheduledAt, language: modelSettings.localLanguage))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.muted)
                    Button {
                        draftTitle = meeting.title
                        isEditingName = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.callout.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .background(.white.opacity(0.62), in: Circle())
                    .foregroundStyle(AppTheme.ink)
                    .help(AppText.t("editMeetingName", language: modelSettings.localLanguage))
                    .popover(isPresented: $isEditingName, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(AppText.t("editMeetingNameTitle", language: modelSettings.localLanguage))
                                .font(.headline)
                            TextField(AppText.t("meetingName", language: modelSettings.localLanguage), text: $draftTitle)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 280)
                                .onSubmit(saveTitle)
                            HStack {
                                Spacer()
                                Button(AppText.t("cancel", language: modelSettings.localLanguage)) {
                                    isEditingName = false
                                }
                                Button(AppText.t("save", language: modelSettings.localLanguage), action: saveTitle)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(16)
                    }
                }
                Spacer()
                Label(meeting.status.localizedTitle(language: modelSettings.localLanguage), systemImage: statusIcon)
                    .font(.callout.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.76), in: Capsule())
            }
        }
        .onChange(of: meeting.id) { _, _ in
            isEditingName = false
            draftTitle = meeting.title
        }
    }

    private func saveTitle() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        meetingStore.renameMeeting(id: meeting.id, title: title)
        isEditingName = false
    }

    private var statusIcon: String {
        switch meeting.status {
        case .scheduled:
            "calendar"
        case .inProgress:
            "waveform"
        case .paused:
            "pause.circle"
        case .processing:
            "hourglass"
        case .completed:
            "checkmark.seal"
        }
    }
}

private struct AudioControlBar: View {
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let meetingStatus: MeetingStatus
    let canStartMeeting: Bool
    @ObservedObject var audioEngine: AudioCaptureEngine
    let displayedElapsed: TimeInterval
    let isUsingLiveAudioEngine: Bool
    let onStartMeeting: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onEndMeeting: () -> Void
    let onPlay: () -> Void
    let onStopPlayback: () -> Void
    let onSeekPlayback: (TimeInterval) -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                controls
                    .fixedSize(horizontal: true, vertical: false)

                if meetingStatus == .completed {
                    playbackTimeline
                } else {
                    recordingTimeline
                }

                Spacer()
            }

            if let failureMessage = audioEngine.failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    @ViewBuilder
    private var controls: some View {
        if meetingStatus == .completed {
            HStack(spacing: 8) {
                leftAction
                rightAction
            }
        } else {
            HStack(spacing: 8) {
                leftAction
                    .frame(width: 148, alignment: .leading)
                rightAction
                    .frame(width: 126, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var leftAction: some View {
        switch meetingStatus {
        case .scheduled:
            primaryButton(AppText.t("startMeeting", language: modelSettings.localLanguage), systemImage: "record.circle", color: AppTheme.ink, action: onStartMeeting)
                .disabled(canStartMeeting == false)
                .opacity(canStartMeeting ? 1 : 0.45)
                .help(canStartMeeting ? AppText.t("startMeetingHelp", language: modelSettings.localLanguage) : AppText.t("activeMeetingHelp", language: modelSettings.localLanguage))
        case .inProgress:
            secondaryButton(AppText.t("pause", language: modelSettings.localLanguage), systemImage: "pause.fill", action: onPause)
        case .paused:
            primaryButton(AppText.t("resume", language: modelSettings.localLanguage), systemImage: "play.fill", color: AppTheme.ink, action: onResume)
        case .processing:
            Label(AppText.t("generating", language: modelSettings.localLanguage), systemImage: "hourglass")
                .font(.headline)
                .foregroundStyle(AppTheme.muted)
        case .completed:
            if audioEngine.isFinalizingRecording {
                Label(AppText.t("saving", language: modelSettings.localLanguage), systemImage: "hourglass")
                    .font(.headline)
                    .foregroundStyle(AppTheme.muted)
            } else {
                primaryButton(audioEngine.isPlaying ? AppText.t("stop", language: modelSettings.localLanguage) : AppText.t("play", language: modelSettings.localLanguage), systemImage: audioEngine.isPlaying ? "stop.fill" : "play.fill", color: audioEngine.isPlaying ? .red : AppTheme.ink) {
                    if audioEngine.isPlaying {
                        onStopPlayback()
                    } else {
                        onPlay()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rightAction: some View {
        switch meetingStatus {
        case .scheduled, .processing:
            Color.clear.frame(width: 1, height: 1)
        case .inProgress, .paused:
            primaryButton(AppText.t("endMeeting", language: modelSettings.localLanguage), systemImage: "stop.fill", color: AppTheme.moss, action: onEndMeeting)
        case .completed:
            iconButton(systemImage: "square.and.arrow.up", action: onExport)
        }
    }

    private var recordingTimeline: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text((isUsingLiveAudioEngine ? audioEngine.elapsed(at: context.date) : displayedElapsed).clockString)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                LevelMeter(level: isUsingLiveAudioEngine ? audioEngine.meterLevel(at: context.date) : 0)
                    .frame(width: 132, height: 8)
            }
        }
    }

    private var playbackTimeline: some View {
        HStack(spacing: 10) {
            Text(audioEngine.playbackPosition.clockString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.muted)
                .frame(width: 44, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { audioEngine.playbackPosition },
                    set: { onSeekPlayback($0) }
                ),
                in: 0...max(displayedElapsed, 1)
            )
                .frame(minWidth: 80, maxWidth: 180)
                .layoutPriority(-1)
            Text(displayedElapsed.clockString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.muted)
                .frame(width: 44, alignment: .leading)
        }
    }

    private func primaryButton(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderless)
        .background(color, in: Capsule())
        .foregroundStyle(.white)
    }

    private func secondaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderless)
        .background(.white.opacity(0.74), in: Capsule())
        .foregroundStyle(AppTheme.ink)
    }

    private func iconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.borderless)
        .background(.white.opacity(0.74), in: Circle())
        .foregroundStyle(AppTheme.ink)
        .help(AppText.t("exportRecording", language: modelSettings.localLanguage))
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [AppTheme.moss, AppTheme.amber], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, proxy.size.width * level))
            }
        }
    }
}

private struct TranscriptTimelineView: View {
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let meeting: Meeting
    let segments: [TranscriptSegment]
    let liveDraft: LiveTranscriptDraft?
    let modelConfiguration: ModelConfiguration
    let isTranscribingRecording: Bool
    let onTranscribeRecording: () -> Void
    private let bottomAnchorID = "transcript-timeline-bottom"

    private var isModelConfigured: Bool {
        modelConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || modelConfiguration.provider == ModelProvider.ollama.rawValue
            || modelConfiguration.provider == ModelProvider.lmStudio.rawValue
    }

    var body: some View {
        VStack(spacing: 12) {
            if shouldShowTranscribeRecordingButton {
                HStack {
                    Button {
                        onTranscribeRecording()
                    } label: {
                        Label(
                            isTranscribingRecording
                                ? AppText.t("transcribing", language: modelSettings.localLanguage)
                                : AppText.t("transcribeRecording", language: modelSettings.localLanguage),
                            systemImage: "text.bubble"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.moss)
                    .disabled(isTranscribingRecording)
                    Spacer()
                }
            }

            if isModelConfigured == false {
                ProviderStatusBanner(
                    translationModel: modelConfiguration.translationModel
                )
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if segments.isEmpty && visibleLiveDraft == nil {
                            ContentUnavailableView(
                                AppText.t("readyLiveTitle", language: modelSettings.localLanguage),
                                systemImage: "waveform.and.mic",
                                description: Text(AppText.t("readyLiveDescription", language: modelSettings.localLanguage))
                            )
                            .padding(.top, 80)
                        }

                        ForEach(segments) { segment in
                            TranscriptSegmentView(segment: segment, isModelConfigured: isModelConfigured)
                        }

                        if let visibleLiveDraft {
                            LiveDraftTranscriptView(draft: visibleLiveDraft)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: segments) { _, _ in
                    scrollToLatest(proxy: proxy)
                }
                .onChange(of: liveDraft?.text) { _, _ in
                    scrollToLatest(proxy: proxy)
                }
                .onChange(of: meeting.id) { _, _ in
                    scrollToLatest(proxy: proxy)
                }
            }
        }
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private var visibleLiveDraft: LiveTranscriptDraft? {
        guard liveDraft?.meetingID == meeting.id else { return nil }
        return liveDraft
    }

    private var shouldShowTranscribeRecordingButton: Bool {
        meeting.status == .completed &&
            meeting.recordingFilePath?.isEmpty == false &&
            segments.filter { $0.kind == .transcript && $0.speaker != "System" }.isEmpty
    }
}

private struct ProviderStatusBanner: View {
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let translationModel: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.amber)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppText.t("providerNotConnected", language: modelSettings.localLanguage))
                    .font(.callout.bold())
                Text(String(format: AppText.t("providerStatus", language: modelSettings.localLanguage), translationModel))
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }
}

private struct TranscriptSegmentView: View {
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let segment: TranscriptSegment
    let isModelConfigured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(segment.timestamp.clockString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.muted)
                Text(segment.speaker)
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text(segment.kind.localizedTitle(language: modelSettings.localLanguage))
                    .font(.caption2.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(kindColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(kindColor)
            }

            Text(segment.sourceText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .textSelection(.enabled)

            if shouldShowTranslation {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppText.t("translation", language: modelSettings.localLanguage))
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.amber)
                    Text(segment.translatedText)
                        .font(.callout)
                        .foregroundStyle(AppTheme.muted)
                        .textSelection(.enabled)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(AppTheme.amber.opacity(0.7))
                                .frame(width: 3)
                        }
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 18)
    }

    private var shouldShowTranslation: Bool {
        let source = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty == false && translated != source
    }

    private var kindColor: Color {
        switch segment.kind {
        case .transcript: AppTheme.moss
        case .question: .blue
        case .decision: AppTheme.amber
        case .actionItem: .red
        }
    }
}

private struct LiveDraftTranscriptView: View {
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let draft: LiveTranscriptDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(AppText.t("live", language: modelSettings.localLanguage))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.muted)
                Text(AppText.t("capturing", language: modelSettings.localLanguage))
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.ink)
                ListeningDots()
                Spacer()
                Text(AppText.t("temporary", language: modelSettings.localLanguage))
                    .font(.caption2.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppTheme.amber.opacity(0.16), in: Capsule())
                    .foregroundStyle(AppTheme.amber)
            }

            Text(draft.text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .textSelection(.enabled)
                .animation(.easeOut(duration: 0.16), value: draft.text)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.74))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AppTheme.amber.opacity(0.28), lineWidth: 1)
                )
                .shadow(color: AppTheme.amber.opacity(0.12), radius: 16, x: 0, y: 8)
        )
    }
}

private struct ListeningDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppTheme.amber)
                    .frame(width: 4, height: 4)
                    .opacity(phase == index ? 1 : 0.34)
                    .scaleEffect(phase == index ? 1.25 : 0.86)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: false)) {
                phase = 2
            }
        }
        .onReceive(Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()) { _ in
            phase = (phase + 1) % 3
        }
    }
}

private struct SummaryView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let meeting: Meeting
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppText.t("meetingSummary", language: modelSettings.localLanguage))
                    .font(.title2.bold())
                Spacer()
                Button {
                    generateSummary()
                } label: {
                    Label(
                        isGenerating
                            ? AppText.t("generating", language: modelSettings.localLanguage)
                            : AppText.t("generateSummary", language: modelSettings.localLanguage),
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.moss)
                .disabled(isGenerating || canGenerateSummary == false)
                .help(canGenerateSummary ? AppText.t("generateSummaryHelp", language: modelSettings.localLanguage) : AppText.t("configureSummaryHelp", language: modelSettings.localLanguage))
            }

            if let generationError {
                Text(generationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            ScrollView {
                Markdown(normalizedMarkdownSummary)
                    .markdownTheme(summaryMarkdownTheme)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard()
    }

    private var summaryMarkdownTheme: Theme {
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
                FontSize(15)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(26)
                    }
                    .markdownMargin(top: 0, bottom: 14)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(20)
                    }
                    .markdownMargin(top: 18, bottom: 8)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.9))
                        }
                        .padding(12)
                }
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .markdownMargin(top: 0, bottom: 14)
            }
    }

    private var normalizedMarkdownSummary: String {
        normalizeMarkdown(AppText.localizedDefaultSummary(meeting.summary, language: modelSettings.localLanguage))
    }

    private func normalizeMarkdown(_ markdown: String) -> String {
        var trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = stripMarkdownFence(trimmed)
        let lines = trimmed.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        let commonIndent = nonEmptyLines
            .map { line in
                line.prefix { $0 == " " || $0 == "\t" }.count
            }
            .min() ?? 0

        guard commonIndent > 0 else { return trimmed }

        return lines
            .map { line in
                guard line.count >= commonIndent else { return line.trimmingCharacters(in: .whitespaces) }
                let start = line.index(line.startIndex, offsetBy: commonIndent)
                return String(line[start...])
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripMarkdownFence(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.count >= 2,
              let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              first.hasPrefix("```") || first.hasPrefix("~~~") else {
            return markdown
        }

        let fencePrefix = String(first.prefix(3))
        guard let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              last.hasPrefix(fencePrefix) else {
            return markdown
        }

        return lines.dropFirst().dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canGenerateSummary: Bool {
        modelSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && modelSettings.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func generateSummary() {
        guard canGenerateSummary else { return }
        isGenerating = true
        generationError = nil

        Task {
            let configuration = modelSettings.configuration
            let segments = await MainActor.run {
                meetingStore.segments.filter { $0.meetingID == meeting.id }
            }
            let summary = try? await MeetingAIClient().summarizeMeeting(
                meeting: meeting,
                participants: meeting.participants,
                segments: segments,
                configuration: configuration
            )

            await MainActor.run {
                isGenerating = false
                let trimmedSummary = normalizeMarkdown(summary ?? "")
                if trimmedSummary.isEmpty {
                    generationError = AppText.t("summaryFailed", language: modelSettings.localLanguage)
                    return
                }
                meetingStore.updateMeeting(id: meeting.id) {
                    $0.summary = trimmedSummary
                }
            }
        }
    }
}

private struct ParticipantsView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let meeting: Meeting
    @State private var participantsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppText.t("participants", language: modelSettings.localLanguage))
                .font(.title2.bold())
            Text(AppText.t("onePersonPerLine", language: modelSettings.localLanguage))
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            TextEditor(text: $participantsText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 16))
                .onChange(of: participantsText) { _, value in
                    meetingStore.updateParticipants(meetingID: meeting.id, namesText: value)
                }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard()
        .onAppear {
            participantsText = meeting.participants.map(\.name).joined(separator: "\n")
        }
        .onChange(of: meeting.id) { _, _ in
            participantsText = meeting.participants.map(\.name).joined(separator: "\n")
        }
    }
}

private struct MeetingLogView: View {
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let logs: [MeetingLogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppText.t("meetingLog", language: modelSettings.localLanguage))
                .font(.title2.bold())

            if logs.isEmpty {
                ContentUnavailableView(
                    AppText.t("noLogsYet", language: modelSettings.localLanguage),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(AppText.t("logsDescription", language: modelSettings.localLanguage))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(logs.sorted(by: { $0.createdAt < $1.createdAt })) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.createdAt.formatted(date: .omitted, time: .standard))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(AppTheme.muted)
                                    Text(entry.level.uppercased())
                                        .font(.caption2.bold())
                                        .foregroundStyle(logColor(for: entry.level))
                                    Spacer()
                                }
                                Text(entry.message)
                                    .font(.callout)
                                    .foregroundStyle(AppTheme.ink)
                                    .textSelection(.enabled)
                            }
                            .padding(12)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard()
    }

    private func logColor(for level: String) -> Color {
        switch level.lowercased() {
        case "warning":
            AppTheme.amber
        case "error":
            .red
        default:
            AppTheme.moss
        }
    }
}
