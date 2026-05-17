import SwiftUI

struct AgentPanelView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @State private var draft = ""
    @State private var isStreaming = false
    @State private var streamTask: Task<Void, Never>?
    @State private var activityText = ""
    @State private var activeTools: [String] = []

    var body: some View {
        VStack(spacing: 16) {
            header
            chatList
            composer
        }
        .padding(22)
        .background(AppTheme.background)
        .onChange(of: meetingStore.selectedMeetingID) { _, _ in
            streamTask?.cancel()
            isStreaming = false
            activityText = ""
            activeTools = []
            draft = ""
        }
    }

    private var header: some View {
        Text("Meeting Agent")
            .font(.system(.title, design: .serif, weight: .bold))
            .foregroundStyle(AppTheme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(activeMessages) { message in
                        AgentBubbleView(
                            message: message,
                            activityText: isActiveAgentMessage(message) ? activityText : "",
                            activeTools: isActiveAgentMessage(message) ? activeTools : [],
                            isStreaming: isActiveAgentMessage(message),
                            onClarifyResponse: { response in
                                submitClarify(response, message: message)
                            },
                            onApprovalChoice: { choice in
                                submitApproval(choice, message: message)
                            }
                        )
                            .id(message.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: activeMessages) { _, messages in
                scrollToLatest(proxy: proxy, messages: messages)
            }
            .onChange(of: meetingStore.selectedMeetingID) { _, _ in
                scrollToLatest(proxy: proxy, messages: activeMessages)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about this meeting...", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit {
                    guard isStreaming == false else { return }
                    send()
                }
                .padding(12)
                .background(.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 16))

            Button {
                if isStreaming {
                    streamTask?.cancel()
                    isStreaming = false
                } else {
                    send()
                }
            } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.headline)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)
            .background(isStreaming ? .red : AppTheme.ink, in: Circle())
            .foregroundStyle(.white)
            .disabled(isStreaming == false && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .glassCard(cornerRadius: 22)
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false, let meetingID = meetingStore.selectedMeetingID else { return }
        draft = ""
        activityText = ""
        activeTools = []
        meetingStore.appendAgentMessage(AgentMessage(sender: .user, content: prompt), meetingID: meetingID)

        let responseMessage = AgentMessage(sender: .agent, content: "")
        meetingStore.appendAgentMessage(responseMessage, meetingID: meetingID)

        let configuration = modelSettings.chatAgentConfiguration
        let history = chatHistory(meetingID: meetingID)
        let currentConversationID = meetingStore.conversationID(for: meetingID)
        isStreaming = true
        activityText = "Thinking..."

        streamTask = Task {
            do {
                try await ChatAgentClient().streamMessage(
                    prompt,
                    configuration: configuration,
                    conversationID: currentConversationID,
                    history: history
                ) { event in
                    handleAgentEvent(event, meetingID: meetingID, responseMessageID: responseMessage.id)
                }
            } catch is CancellationError {
                await MainActor.run {
                    meetingStore.appendToAgentMessage(id: responseMessage.id, meetingID: meetingID, content: "\n\n*Stopped.*")
                    isStreaming = false
                    activityText = ""
                    activeTools = []
                }
            } catch {
                await MainActor.run {
                    meetingStore.updateAgentMessage(
                        id: responseMessage.id,
                        meetingID: meetingID,
                        content: "Connection failed: \(error.localizedDescription)"
                    )
                    isStreaming = false
                    activityText = ""
                    activeTools = []
                }
            }
        }
    }

    @MainActor
    private func handleAgentEvent(_ event: ChatAgentEvent, meetingID: Meeting.ID, responseMessageID: AgentMessage.ID) {
        switch event {
        case let .conversationID(newConversationID):
            meetingStore.setConversationID(newConversationID, for: meetingID)
        case let .chunk(content):
            activityText = ""
            activeTools = []
            meetingStore.appendToAgentMessage(id: responseMessageID, meetingID: meetingID, content: content)
        case let .status(status):
            activityText = status
        case let .toolCall(tools):
            activeTools = tools
            activityText = "Using tools..."
        case let .approvalRequired(approval):
            activityText = ""
            activeTools = []
            meetingStore.setAgentApproval(approval, messageID: responseMessageID, meetingID: meetingID)
        case let .clarifyRequired(clarify):
            activityText = ""
            activeTools = []
            meetingStore.setAgentClarify(clarify, messageID: responseMessageID, meetingID: meetingID)
        case .done:
            isStreaming = false
            activityText = ""
            activeTools = []
        }
    }

    private func submitApproval(_ choice: String, message: AgentMessage) {
        guard let approval = message.approval,
              let meetingID = meetingStore.selectedMeetingID,
              let conversationID = meetingStore.conversationID(for: meetingID) else { return }

        Task {
            do {
                let ok = try await ChatAgentClient().submitApproval(
                    approval,
                    choice: choice,
                    conversationID: conversationID,
                    configuration: modelSettings.chatAgentConfiguration
                )
                if ok {
                    await MainActor.run {
                        meetingStore.resolveAgentApproval(messageID: message.id, meetingID: meetingID, choice: choice)
                    }
                }
            } catch {
                await MainActor.run {
                    meetingStore.appendToAgentMessage(
                        id: message.id,
                        meetingID: meetingID,
                        content: "\n\nApproval failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func submitClarify(_ response: String, message: AgentMessage) {
        guard let clarify = message.clarify,
              response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let meetingID = meetingStore.selectedMeetingID,
              let conversationID = meetingStore.conversationID(for: meetingID) else { return }

        Task {
            do {
                let resolved = try await ChatAgentClient().submitClarify(
                    clarify,
                    response: response,
                    conversationID: conversationID,
                    configuration: modelSettings.chatAgentConfiguration
                )
                if resolved {
                    await MainActor.run {
                        meetingStore.resolveAgentClarify(messageID: message.id, meetingID: meetingID, response: response)
                    }
                }
            } catch {
                await MainActor.run {
                    meetingStore.appendToAgentMessage(
                        id: message.id,
                        meetingID: meetingID,
                        content: "\n\nClarify failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private var activeMessages: [AgentMessage] {
        guard let meetingID = meetingStore.selectedMeetingID else { return [] }
        return meetingStore.agentMessages(for: meetingID)
    }

    private func isActiveAgentMessage(_ message: AgentMessage) -> Bool {
        isStreaming && message.sender == .agent && message.id == activeMessages.last?.id
    }

    private func chatHistory(meetingID: Meeting.ID) -> [ChatAgentClient.HistoryItem] {
        meetingStore.agentMessages(for: meetingID).suffix(8).compactMap { message in
            switch message.sender {
            case .user:
                ChatAgentClient.HistoryItem(role: "user", content: message.content)
            case .agent, .suggestion:
                ChatAgentClient.HistoryItem(role: "assistant", content: message.content)
            }
        }
    }

    private func scrollToLatest(proxy: ScrollViewProxy, messages: [AgentMessage]) {
        guard let lastID = messages.last?.id else { return }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

private struct AgentBubbleView: View {
    let message: AgentMessage
    let activityText: String
    let activeTools: [String]
    let isStreaming: Bool
    let onClarifyResponse: (String) -> Void
    let onApprovalChoice: (String) -> Void

    var body: some View {
        HStack {
            if message.sender == .user { Spacer(minLength: 42) }

            VStack(alignment: .leading, spacing: 10) {
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if message.content.isEmpty && isStreaming {
                    AgentActivityView(status: activityText.isEmpty ? "Thinking" : activityText, tools: activeTools)
                } else {
                    MarkdownText(content: message.content)
                        .font(.callout)
                        .textSelection(.enabled)

                    if isStreaming && (activityText.isEmpty == false || activeTools.isEmpty == false) {
                        AgentActivityView(status: activityText, tools: activeTools)
                            .padding(.top, 4)
                    }
                }

                if let clarify = message.clarify {
                    AgentClarifyCard(clarify: clarify, onSubmit: onClarifyResponse)
                }

                if let approval = message.approval {
                    AgentApprovalCard(approval: approval, onChoice: onApprovalChoice)
                }
            }
            .padding(13)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(foreground)

            if message.sender != .user { Spacer(minLength: 42) }
        }
    }

    private var label: String {
        switch message.sender {
        case .user: "You"
        case .agent: "Agent"
        case .suggestion: "Suggestion"
        }
    }

    private var background: Color {
        switch message.sender {
        case .user: AppTheme.ink
        case .agent: .white.opacity(0.74)
        case .suggestion: AppTheme.amber.opacity(0.18)
        }
    }

    private var foreground: Color {
        message.sender == .user ? .white : AppTheme.ink
    }
}

private struct MarkdownText: View {
    let content: String

    var body: some View {
        Text(markdown)
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: content)) ?? AttributedString(content)
    }
}

private struct AgentActivityView: View {
    let status: String
    let tools: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PulsingDots()
                Text(status)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AppTheme.muted)
            }

            if tools.isEmpty == false {
                HStack(spacing: 6) {
                    ForEach(tools, id: \.self) { tool in
                        Text(tool)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppTheme.moss.opacity(0.14), in: Capsule())
                            .foregroundStyle(AppTheme.moss)
                    }
                }
            }
        }
    }
}

private struct AgentClarifyCard: View {
    let clarify: AgentClarifyRequest
    let onSubmit: (String) -> Void
    @State private var response = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Clarification needed", systemImage: "questionmark.bubble")
                .font(.caption.bold())
                .foregroundStyle(AppTheme.moss)
            Text(clarify.question)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)

            if clarify.resolved {
                Label(clarify.response ?? "Answered", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.moss)
            } else if clarify.choices.isEmpty == false {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(clarify.choices, id: \.self) { choice in
                        Button {
                            onSubmit(choice)
                        } label: {
                            Text(choice)
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.borderless)
                        .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Reply...", text: $response)
                        .textFieldStyle(.plain)
                        .onSubmit(submit)
                        .padding(9)
                        .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("Reply", action: submit)
                        .buttonStyle(.borderless)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(AppTheme.ink, in: Capsule())
                        .foregroundStyle(.white)
                        .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(11)
        .background(AppTheme.moss.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func submit() {
        let value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return }
        onSubmit(value)
    }
}

private struct AgentApprovalCard: View {
    let approval: AgentApprovalRequest
    let onChoice: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Command approval required", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(AppTheme.amber)
            Text(approval.description)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)

            if approval.command.isEmpty == false {
                Text(approval.command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if approval.resolved {
                Label(resolvedText, systemImage: approval.choice == "deny" ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(approval.choice == "deny" ? .red : AppTheme.moss)
            } else {
                HStack(spacing: 7) {
                    approvalButton("Allow", choice: "allow", color: AppTheme.moss)
                    approvalButton("Deny", choice: "deny", color: .red)
                    approvalButton("Always", choice: "allow_always", color: AppTheme.ink)
                    approvalButton("YOLO", choice: "yolo", color: AppTheme.amber)
                }
            }
        }
        .padding(11)
        .background(AppTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var resolvedText: String {
        switch approval.choice {
        case "deny":
            "Denied"
        case "allow_always":
            "Permanently allowed"
        case "yolo":
            "YOLO mode enabled"
        default:
            "Allowed for this session"
        }
    }

    private func approvalButton(_ title: String, choice: String, color: Color) -> some View {
        Button {
            onChoice(choice)
        } label: {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
        }
        .buttonStyle(.borderless)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }
}

private struct PulsingDots: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppTheme.amber)
                    .frame(width: 6, height: 6)
                    .scaleEffect(isAnimating ? 1.0 : 0.45)
                    .opacity(isAnimating ? 0.95 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.62)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.16),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}
