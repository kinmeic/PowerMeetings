import Foundation
import SwiftUI

@MainActor
final class MeetingStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedMeetingID: Meeting.ID?
    @Published var segments: [TranscriptSegment] = []
    @Published var logs: [MeetingLogEntry] = []
    @Published private var agentMessagesByMeeting: [Meeting.ID: [AgentMessage]] = [:]
    @Published private var agentConversationIDs: [Meeting.ID: String] = [:]

    private struct StorageState: Codable {
        var meetings: [Meeting]
        var selectedMeetingID: Meeting.ID?
        var segments: [TranscriptSegment]
        var logs: [MeetingLogEntry]
        var agentMessagesByMeeting: [Meeting.ID: [AgentMessage]]
        var agentConversationIDs: [Meeting.ID: String]

        init(
            meetings: [Meeting],
            selectedMeetingID: Meeting.ID?,
            segments: [TranscriptSegment],
            logs: [MeetingLogEntry],
            agentMessagesByMeeting: [Meeting.ID: [AgentMessage]],
            agentConversationIDs: [Meeting.ID: String]
        ) {
            self.meetings = meetings
            self.selectedMeetingID = selectedMeetingID
            self.segments = segments
            self.logs = logs
            self.agentMessagesByMeeting = agentMessagesByMeeting
            self.agentConversationIDs = agentConversationIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meetings = try container.decode([Meeting].self, forKey: .meetings)
            selectedMeetingID = try container.decodeIfPresent(Meeting.ID.self, forKey: .selectedMeetingID)
            segments = try container.decode([TranscriptSegment].self, forKey: .segments)
            logs = try container.decodeIfPresent([MeetingLogEntry].self, forKey: .logs) ?? []
            agentMessagesByMeeting = try container.decode([Meeting.ID: [AgentMessage]].self, forKey: .agentMessagesByMeeting)
            agentConversationIDs = try container.decode([Meeting.ID: String].self, forKey: .agentConversationIDs)
        }
    }

    init() {
        load()
    }

    var selectedMeeting: Meeting? {
        guard let selectedMeetingID else { return meetings.first }
        return meetings.first { $0.id == selectedMeetingID }
    }

    var selectedMeetingSegments: [TranscriptSegment] {
        guard let meetingID = selectedMeeting?.id else { return [] }
        return segments.filter { $0.meetingID == meetingID }
    }

    var selectedMeetingLogs: [MeetingLogEntry] {
        guard let meetingID = selectedMeeting?.id else { return [] }
        return logs.filter { $0.meetingID == meetingID }
    }

    var selectedMeetingAgentMessages: [AgentMessage] {
        guard let meetingID = selectedMeeting?.id else { return [] }
        return agentMessages(for: meetingID)
    }

    func activeMeetingID(excluding meetingID: Meeting.ID? = nil) -> Meeting.ID? {
        meetings.first {
            $0.id != meetingID && ($0.status == .inProgress || $0.status == .paused)
        }?.id
    }

    func canStartMeeting(id: Meeting.ID) -> Bool {
        activeMeetingID(excluding: id) == nil
    }

    func bootstrapSampleData() {
        guard meetings.isEmpty else { return }

        let discovery = Meeting(
            title: "Customer Discovery Call",
            scheduledAt: Date(),
            status: .scheduled,
            participants: [
                Participant(name: "Eugene", role: "Host", organization: "PowerMeetings"),
                Participant(name: "Customer Lead", role: "Buyer", organization: "Acme")
            ],
            summary: "No summary yet. Start recording to build the meeting memory."
        )

        let weekly = Meeting(
            title: "Product Weekly Sync",
            scheduledAt: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date(),
            status: .completed,
            participants: [
                Participant(name: "Design", role: "Design Owner", organization: "Internal"),
                Participant(name: "Engineering", role: "Tech Lead", organization: "Internal")
            ],
            summary: "Discussed real-time transcription, model routing, and the first macOS prototype."
        )

        meetings = [discovery, weekly]
        selectedMeetingID = discovery.id
        agentMessagesByMeeting[discovery.id] = defaultAgentMessages()
        agentMessagesByMeeting[weekly.id] = defaultAgentMessages()
        segments = [
            TranscriptSegment(
                meetingID: weekly.id,
                timestamp: 12,
                speaker: "Design",
                sourceText: "The three-column layout should keep the transcript and agent visible at the same time.",
                translatedText: "三列布局应该同时保持转写内容和 Agent 可见。",
                kind: .decision,
                confidence: 0.94
            )
        ]
        save()
    }

    func createMeeting() {
        let meeting = Meeting(
            title: "Untitled Meeting",
            scheduledAt: Date(),
            status: .scheduled,
            participants: [],
            summary: "No summary yet."
        )
        meetings.insert(meeting, at: 0)
        selectedMeetingID = meeting.id
        agentMessagesByMeeting[meeting.id] = defaultAgentMessages()
        save()
    }

    func deleteMeeting(id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings.remove(at: index)
        segments.removeAll { $0.meetingID == id }
        logs.removeAll { $0.meetingID == id }
        agentMessagesByMeeting.removeValue(forKey: id)
        agentConversationIDs.removeValue(forKey: id)

        if selectedMeetingID == id {
            if meetings.indices.contains(index) {
                selectedMeetingID = meetings[index].id
            } else {
                selectedMeetingID = meetings.last?.id
            }
        }
        save()
    }

    func renameMeeting(id: Meeting.ID, title: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else {
            return
        }
        meetings[index].title = title
        save()
    }

    func updateParticipants(meetingID: Meeting.ID, namesText: String) {
        let participants = namesText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .map { Participant(name: $0, role: "", organization: "") }

        updateMeeting(id: meetingID) {
            $0.participants = participants
        }
    }

    func updateSelectedMeeting(_ update: (inout Meeting) -> Void) {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else {
            return
        }
        update(&meetings[index])
        save()
    }

    func updateMeeting(id: Meeting.ID, _ update: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&meetings[index])
        save()
    }

    func appendSegment(_ segment: TranscriptSegment) {
        segments.append(segment)
        save()
    }

    func appendLog(_ entry: MeetingLogEntry) {
        logs.append(entry)
        save()
    }

    func updateSegmentTranslation(id: TranscriptSegment.ID, translatedText: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].translatedText = translatedText
        save()
    }

    func updateSegment(id: TranscriptSegment.ID, _ update: (inout TranscriptSegment) -> Void) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        update(&segments[index])
        save()
    }

    func agentMessages(for meetingID: Meeting.ID) -> [AgentMessage] {
        agentMessagesByMeeting[meetingID] ?? defaultAgentMessages()
    }

    func conversationID(for meetingID: Meeting.ID) -> String? {
        agentConversationIDs[meetingID]
    }

    func setConversationID(_ conversationID: String, for meetingID: Meeting.ID) {
        agentConversationIDs[meetingID] = conversationID
        save()
    }

    func appendAgentMessage(_ message: AgentMessage, meetingID: Meeting.ID) {
        ensureAgentMessages(for: meetingID)
        agentMessagesByMeeting[meetingID, default: []].append(message)
        save()
    }

    func updateAgentMessage(id: AgentMessage.ID, meetingID: Meeting.ID, content: String) {
        ensureAgentMessages(for: meetingID)
        guard let index = agentMessagesByMeeting[meetingID]?.firstIndex(where: { $0.id == id }) else { return }
        agentMessagesByMeeting[meetingID]?[index].content = content
        save()
    }

    func appendToAgentMessage(id: AgentMessage.ID, meetingID: Meeting.ID, content: String) {
        ensureAgentMessages(for: meetingID)
        guard let index = agentMessagesByMeeting[meetingID]?.firstIndex(where: { $0.id == id }) else { return }
        agentMessagesByMeeting[meetingID]?[index].content += content
        save()
    }

    func setAgentApproval(_ approval: AgentApprovalRequest, messageID: AgentMessage.ID, meetingID: Meeting.ID) {
        updateAgentMessage(id: messageID, meetingID: meetingID) {
            $0.approval = approval
        }
    }

    func resolveAgentApproval(messageID: AgentMessage.ID, meetingID: Meeting.ID, choice: String) {
        updateAgentMessage(id: messageID, meetingID: meetingID) {
            $0.approval?.resolved = true
            $0.approval?.choice = choice
        }
    }

    func setAgentClarify(_ clarify: AgentClarifyRequest, messageID: AgentMessage.ID, meetingID: Meeting.ID) {
        updateAgentMessage(id: messageID, meetingID: meetingID) {
            $0.clarify = clarify
        }
    }

    func resolveAgentClarify(messageID: AgentMessage.ID, meetingID: Meeting.ID, response: String) {
        updateAgentMessage(id: messageID, meetingID: meetingID) {
            $0.clarify?.resolved = true
            $0.clarify?.response = response
        }
    }

    private func ensureAgentMessages(for meetingID: Meeting.ID) {
        if agentMessagesByMeeting[meetingID] == nil {
            agentMessagesByMeeting[meetingID] = defaultAgentMessages()
        }
    }

    private func updateAgentMessage(id: AgentMessage.ID, meetingID: Meeting.ID, update: (inout AgentMessage) -> Void) {
        ensureAgentMessages(for: meetingID)
        guard let index = agentMessagesByMeeting[meetingID]?.firstIndex(where: { $0.id == id }) else { return }
        update(&agentMessagesByMeeting[meetingID]![index])
        save()
    }

    private func defaultAgentMessages() -> [AgentMessage] {
        [
            AgentMessage(sender: .agent, content: "I am ready to help with this meeting's notes, questions, and follow-up work.")
        ]
    }

    private func load() {
        let url = storageURL
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(StorageState.self, from: data) else {
            return
        }
        meetings = state.meetings
        selectedMeetingID = state.selectedMeetingID
        segments = state.segments
        logs = state.logs
        agentMessagesByMeeting = state.agentMessagesByMeeting
        agentConversationIDs = state.agentConversationIDs
    }

    private func save() {
        let state = StorageState(
            meetings: meetings,
            selectedMeetingID: selectedMeetingID,
            segments: segments,
            logs: logs,
            agentMessagesByMeeting: agentMessagesByMeeting,
            agentConversationIDs: agentConversationIDs
        )
        do {
            let url = storageURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save PowerMeetings state: \(error.localizedDescription)")
        }
    }

    private var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerMeetings", isDirectory: true)
            .appendingPathComponent("store.json")
    }
}

@MainActor
final class ModelSettingsStore: ObservableObject {
    @AppStorage("model.provider") var provider = ModelProvider.openAI.rawValue
    @AppStorage("model.apiBaseURL") var apiBaseURL = "https://api.openai.com/v1"
    @AppStorage("model.apiKey") var apiKey = ""
    @AppStorage("realtimeASR.provider") var realtimeASRProvider = RealtimeASRProvider.macOSSpeech.rawValue
    @AppStorage("realtimeASR.apiKey") var realtimeASRAPIKey = ""
    @AppStorage("realtimeASR.model") var realtimeASRModel = "fun-asr-realtime"
    @AppStorage("audio.noiseSuppressionEnabled") var noiseSuppressionEnabled = false
    @AppStorage("audio.systemAudioCaptureEnabled") var systemAudioCaptureEnabled = false
    @AppStorage("model.realtimeModel") var realtimeModel = "gpt-4o-realtime-preview"
    @AppStorage("model.translationModel") var translationModel = "gpt-4.1-mini"
    @AppStorage("model.summaryModel") var summaryModel = "gpt-4.1-mini"
    @AppStorage("model.localLanguage") var localLanguage = LocalMeetingLanguage.mandarinChinese.rawValue
    @AppStorage("chatAgent.enabled") var chatAgentEnabled = true
    @AppStorage("chatAgent.scheme") var chatAgentScheme = "http"
    @AppStorage("chatAgent.host") var chatAgentHost = "127.0.0.1"
    @AppStorage("chatAgent.port") var chatAgentPort = 8000
    @AppStorage("chatAgent.basePath") var chatAgentBasePath = ""
    @AppStorage("chatAgent.authToken") var chatAgentAuthToken = ""

    var configuration: ModelConfiguration {
        ModelConfiguration(
            provider: provider,
            apiBaseURL: apiBaseURL,
            apiKey: apiKey,
            realtimeASRProvider: realtimeASRProvider,
            realtimeASRAPIKey: realtimeASRAPIKey,
            realtimeASRModel: realtimeASRModel,
            realtimeModel: realtimeModel,
            translationModel: translationModel,
            summaryModel: summaryModel,
            localLanguage: localLanguage
        )
    }

    var chatAgentConfiguration: ChatAgentConfiguration {
        ChatAgentConfiguration(
            isEnabled: chatAgentEnabled,
            scheme: chatAgentScheme,
            host: chatAgentHost,
            port: chatAgentPort,
            basePath: chatAgentBasePath,
            authToken: chatAgentAuthToken
        )
    }

    var chatAgentBaseURL: String {
        chatAgentConfiguration.baseURL
    }
}
