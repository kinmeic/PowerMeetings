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

                Picker("", selection: $selectedTab) {
                    Text("Live").tag("Live")
                    Text("Summary").tag("Summary")
                    Text("People").tag("People")
                }
                .pickerStyle(.segmented)

                if selectedTab == "Live" {
                    TranscriptTimelineView(
                        segments: meetingStore.selectedMeetingSegments,
                        modelConfiguration: modelSettings.configuration
                    )
                } else if selectedTab == "Summary" {
                    SummaryView(meeting: meeting)
                } else {
                    ParticipantsView(meeting: meeting)
                }
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "calendar.badge.clock")
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
        let settings = AudioCaptureSettings(inputDeviceID: audioDeviceManager.selectedDeviceID)
        audioEngine.start(settings: settings, meetingID: meeting.id)
        meetingStore.updateMeeting(id: meeting.id) { $0.status = .inProgress }
        session.startLiveTranscription(for: meeting.id, configuration: modelSettings.configuration) { segment in
            meetingStore.appendSegment(segment)
        }
    }

    private func pauseMeeting(meeting: Meeting) {
        audioEngine.pause()
        session.pauseLiveTranscription()
        meetingStore.updateMeeting(id: meeting.id) {
            $0.status = .paused
        }
    }

    private func resumeMeeting(meeting: Meeting) {
        audioEngine.resume()
        session.resumeLiveTranscription()
        meetingStore.updateMeeting(id: meeting.id) {
            $0.status = .inProgress
        }
    }

    private func endMeeting(meeting: Meeting) {
        audioEngine.end()
        session.stopDemoTranscript()
        let recordingPath = audioEngine.recordingURL?.path
        let duration = audioEngine.elapsed
        selectedTab = "Summary"
        meetingStore.updateMeeting(id: meeting.id) {
            $0.status = .completed
            if $0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.summary == "No summary yet." {
                $0.summary = "No summary yet. Click Generate Summary when you are ready."
            }
            $0.recordingFilePath = recordingPath
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
}

private struct MeetingHeaderView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    let meeting: Meeting
    @State private var isEditingName = false
    @State private var draftTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Text(meeting.scheduledAt.formatted(date: .abbreviated, time: .shortened))
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
                    .help("Edit meeting name")
                    .popover(isPresented: $isEditingName, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Edit Meeting Name")
                                .font(.headline)
                            TextField("Meeting name", text: $draftTitle)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 280)
                                .onSubmit(saveTitle)
                            HStack {
                                Spacer()
                                Button("Cancel") {
                                    isEditingName = false
                                }
                                Button("Save", action: saveTitle)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(16)
                    }
                }
                Spacer()
                Label(meeting.status.rawValue, systemImage: statusIcon)
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
            primaryButton("Start Meeting", systemImage: "record.circle", color: AppTheme.ink, action: onStartMeeting)
                .disabled(canStartMeeting == false)
                .opacity(canStartMeeting ? 1 : 0.45)
                .help(canStartMeeting ? "Start meeting" : "End the current active meeting before starting another.")
        case .inProgress:
            secondaryButton("Pause", systemImage: "pause.fill", action: onPause)
        case .paused:
            primaryButton("Resume", systemImage: "play.fill", color: AppTheme.ink, action: onResume)
        case .processing:
            Label("Generating...", systemImage: "hourglass")
                .font(.headline)
                .foregroundStyle(AppTheme.muted)
        case .completed:
            primaryButton(audioEngine.isPlaying ? "Stop" : "Play", systemImage: audioEngine.isPlaying ? "stop.fill" : "play.fill", color: audioEngine.isPlaying ? .red : AppTheme.ink) {
                if audioEngine.isPlaying {
                    onStopPlayback()
                } else {
                    onPlay()
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
            primaryButton("End Meeting", systemImage: "stop.fill", color: AppTheme.moss, action: onEndMeeting)
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
        .help("Export recording")
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
    let segments: [TranscriptSegment]
    let modelConfiguration: ModelConfiguration

    private var isModelConfigured: Bool {
        modelConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || modelConfiguration.provider == ModelProvider.ollama.rawValue
            || modelConfiguration.provider == ModelProvider.lmStudio.rawValue
    }

    var body: some View {
        VStack(spacing: 12) {
            if isModelConfigured == false {
                ProviderStatusBanner(
                    realtimeModel: modelConfiguration.realtimeModel,
                    translationModel: modelConfiguration.translationModel
                )
            }

            ScrollView {
                LazyVStack(spacing: 14) {
                    if segments.isEmpty {
                        ContentUnavailableView(
                            "Ready for live transcription",
                            systemImage: "waveform.and.mic",
                            description: Text("Start the meeting and transcript segments will appear here.")
                        )
                        .padding(.top, 80)
                    }

                    ForEach(segments) { segment in
                        TranscriptSegmentView(segment: segment, isModelConfigured: isModelConfigured)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct ProviderStatusBanner: View {
    let realtimeModel: String
    let translationModel: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.amber)

            VStack(alignment: .leading, spacing: 4) {
                Text("Realtime translation provider is not connected")
                    .font(.callout.bold())
                Text("ASR: \(realtimeModel) · Translation: \(translationModel)")
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
                Text(segment.kind.rawValue)
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
                    Text("Translation")
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

private struct SummaryView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    let meeting: Meeting
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Meeting Summary")
                    .font(.title2.bold())
                Spacer()
                Button {
                    generateSummary()
                } label: {
                    Label(isGenerating ? "Generating..." : "Generate Summary", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.moss)
                .disabled(isGenerating || canGenerateSummary == false)
                .help(canGenerateSummary ? "Generate and save meeting summary" : "Configure API Key and Summary Model in Settings first.")
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
        normalizeMarkdown(meeting.summary)
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
                    generationError = "Summary generation failed. Please check the Summary Model, API Base URL, and API Key."
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
    let meeting: Meeting
    @State private var participantsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Participants")
                .font(.title2.bold())
            Text("One person per line")
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
