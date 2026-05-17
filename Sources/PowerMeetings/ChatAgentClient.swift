import Foundation

enum ChatAgentEvent {
    case conversationID(String)
    case chunk(String)
    case status(String)
    case toolCall([String])
    case approvalRequired(AgentApprovalRequest)
    case clarifyRequired(AgentClarifyRequest)
    case done
}

enum ChatAgentError: LocalizedError {
    case invalidURL(String)
    case badStatus(Int, String)
    case agentError(String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            "Invalid Chat Agent URL: \(url)"
        case let .badStatus(status, url):
            "Chat Agent request failed with HTTP \(status): \(url)"
        case let .agentError(message):
            message
        }
    }
}

enum ChatAgentHealthStatus: Equatable {
    case checking
    case online
    case offline(String)
}

struct ChatAgentClient {
    struct HistoryItem: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Codable {
        let message: String
        let conversation_id: String?
        let history: [HistoryItem]
    }

    private struct ApprovalBody: Codable {
        let conversation_id: String
        let command: String
        let description: String
        let pattern_key: String
        let choice: String
    }

    private struct ClarifyBody: Codable {
        let conversation_id: String
        let clarify_id: String
        let response: String
    }

    private struct ApprovalResponse: Codable {
        let ok: Bool
    }

    private struct ClarifyResponse: Codable {
        let resolved: Bool
    }

    func streamMessage(
        _ message: String,
        configuration: ChatAgentConfiguration,
        conversationID: String?,
        history: [HistoryItem],
        onEvent: @escaping @MainActor (ChatAgentEvent) -> Void
    ) async throws {
        let endpoint = endpointURL(configuration: configuration)
        guard let url = URL(string: endpoint) else {
            throw ChatAgentError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let token = configuration.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty == false {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                message: message,
                conversation_id: conversationID,
                history: history
            )
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) == false {
            throw ChatAgentError.badStatus(httpResponse.statusCode, endpoint)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            try await handleEventLine(json, onEvent: onEvent)
        }
    }

    func submitApproval(
        _ approval: AgentApprovalRequest,
        choice: String,
        conversationID: String,
        configuration: ChatAgentConfiguration
    ) async throws -> Bool {
        let body = ApprovalBody(
            conversation_id: conversationID,
            command: approval.command,
            description: approval.description,
            pattern_key: approval.patternKey,
            choice: choice
        )
        let response: ApprovalResponse = try await postJSON(
            path: "\(configuration.apiBasePath)/agent/approve",
            body: body,
            configuration: configuration
        )
        return response.ok
    }

    func submitClarify(
        _ clarify: AgentClarifyRequest,
        response: String,
        conversationID: String,
        configuration: ChatAgentConfiguration
    ) async throws -> Bool {
        let body = ClarifyBody(
            conversation_id: conversationID,
            clarify_id: clarify.clarifyID,
            response: response
        )
        let result: ClarifyResponse = try await postJSON(
            path: "\(configuration.apiBasePath)/agent/clarify",
            body: body,
            configuration: configuration
        )
        return result.resolved
    }

    func checkHealth(configuration: ChatAgentConfiguration) async -> ChatAgentHealthStatus {
        let endpoint = endpointURL(path: "\(configuration.apiBasePath)/health", configuration: configuration)
        guard let url = URL(string: endpoint) else {
            return .offline("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode) {
                return .online
            }
            return .offline("Unavailable")
        } catch {
            return .offline("Offline")
        }
    }

    private func endpointURL(configuration: ChatAgentConfiguration) -> String {
        let base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configuration.chatStreamPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard base.isEmpty == false else { return path }

        if path.hasPrefix("/") {
            return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path
    }

    private func handleEventLine(
        _ json: String,
        onEvent: @escaping @MainActor (ChatAgentEvent) -> Void
    ) async throws {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "conv_id":
            if let conversationID = object["conversation_id"] as? String {
                await onEvent(.conversationID(conversationID))
            }
        case "chunk":
            if let content = object["content"] as? String {
                await onEvent(.chunk(content))
            }
        case "thinking":
            if let phase = object["phase"] as? String, phase == "extraction" {
                await onEvent(.status("Analyzing message..."))
            } else if let phase = object["phase"] as? String, phase == "command" {
                await onEvent(.status("Processing command..."))
            } else {
                await onEvent(.status("Thinking..."))
            }
        case "tool_call":
            let tools = object["tools"] as? [String] ?? []
            await onEvent(.toolCall(tools.isEmpty ? [object["tool_name"] as? String ?? "tool"] : tools))
        case "approval_required":
            let approval = AgentApprovalRequest(
                command: object["command"] as? String ?? "",
                description: object["description"] as? String ?? "Approval required",
                patternKey: object["pattern_key"] as? String ?? ""
            )
            await onEvent(.approvalRequired(approval))
        case "clarify_required":
            let choices = object["choices"] as? [String] ?? []
            let clarify = AgentClarifyRequest(
                clarifyID: object["clarify_id"] as? String ?? "",
                question: object["question"] as? String ?? "Please clarify.",
                choices: choices
            )
            await onEvent(.clarifyRequired(clarify))
        case "tool.started":
            let tool = object["tool"] as? String ?? "tool"
            let preview = object["preview"] as? String
            await onEvent(.status(preview ?? "Running \(tool)..."))
        case "delegate.thinking":
            await onEvent(.status("Delegate is thinking..."))
        case "delegate.tool_call":
            let tools = object["tools"] as? [String] ?? []
            await onEvent(.toolCall(tools.isEmpty ? ["delegate"] : tools))
        case "delegate.tool_result":
            if let summary = object["summary"] as? String {
                await onEvent(.status(summary))
            }
        case "delegate.done":
            await onEvent(.status("Delegate completed."))
        case "progress":
            if let summary = object["summary"] as? String {
                await onEvent(.status(summary))
            }
        case "error":
            throw ChatAgentError.agentError(object["content"] as? String ?? "Unknown Chat Agent error.")
        case "interrupted":
            await onEvent(.chunk("\n\n*Task interrupted.*"))
            await onEvent(.done)
        case "done":
            if let conversationID = object["conversation_id"] as? String {
                await onEvent(.conversationID(conversationID))
            }
            await onEvent(.done)
        default:
            break
        }
    }

    private func postJSON<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody,
        configuration: ChatAgentConfiguration
    ) async throws -> ResponseBody {
        let endpoint = endpointURL(path: path, configuration: configuration)
        guard let url = URL(string: endpoint) else {
            throw ChatAgentError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let token = configuration.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty == false {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) == false {
            throw ChatAgentError.badStatus(httpResponse.statusCode, endpoint)
        }

        return try JSONDecoder().decode(ResponseBody.self, from: data)
    }

    private func endpointURL(path: String, configuration: ChatAgentConfiguration) -> String {
        let base = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasPrefix("/") {
            return base + path
        }
        return base + "/" + path
    }
}
