import Foundation

enum MeetingStatus: String, CaseIterable, Codable {
    case scheduled = "Scheduled"
    case inProgress = "In Progress"
    case paused = "Paused"
    case processing = "Processing"
    case completed = "Ended"
}

enum SegmentKind: String, Codable {
    case transcript
    case question
    case decision
    case actionItem
}

struct Participant: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var role: String
    var organization: String
}

struct Meeting: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var scheduledAt: Date
    var status: MeetingStatus
    var participants: [Participant]
    var summary: String
    var recordingFilePath: String?
    var duration: TimeInterval?
}

struct TranscriptSegment: Identifiable, Hashable, Codable {
    var id = UUID()
    var meetingID: UUID
    var timestamp: TimeInterval
    var speaker: String
    var sourceText: String
    var translatedText: String
    var kind: SegmentKind
    var confidence: Double
}

struct MeetingLogEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    var meetingID: UUID
    var createdAt = Date()
    var message: String
    var level: String = "info"

    var isWarningOrError: Bool {
        let normalized = level.lowercased()
        return normalized == "warning" || normalized == "error"
    }
}

struct AgentMessage: Identifiable, Hashable, Codable {
    enum Sender: String, Codable {
        case user
        case agent
        case suggestion
    }

    var id = UUID()
    var sender: Sender
    var content: String
    var createdAt = Date()
    var approval: AgentApprovalRequest?
    var clarify: AgentClarifyRequest?
}

struct AgentApprovalRequest: Hashable, Codable {
    var command: String
    var description: String
    var patternKey: String
    var resolved = false
    var choice: String?
}

struct AgentClarifyRequest: Hashable, Codable {
    var clarifyID: String
    var question: String
    var choices: [String]
    var resolved = false
    var response: String?
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String?
    let isDefault: Bool
    let sampleRate: Double?
    let channelCount: Int?
}

struct AudioCaptureSettings: Hashable, Codable {
    var inputDeviceID: String?
    var sampleRate: Double = 16_000
    var channelCount: Int = 1
    var enableSystemAudio = false
    var enableNoiseSuppression = true
}

enum ModelProvider: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case customOpenAICompatible = "OpenAI Compatible"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"

    var id: String { rawValue }
}

enum RealtimeASRProvider: String, CaseIterable, Identifiable, Codable {
    case macOSSpeech = "macOS Speech"
    case aliyunRealtimeASR = "Aliyun Realtime ASR"

    var id: String { rawValue }
}

enum LocalMeetingLanguage: String, CaseIterable, Identifiable, Codable {
    case mandarinChinese = "zh-CN"
    case english = "en-US"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mandarinChinese:
            "中文"
        case .english:
            "英语"
        }
    }

    var translationTarget: String {
        switch self {
        case .mandarinChinese:
            "Chinese (Mandarin, Simplified Chinese)"
        case .english:
            "English"
        }
    }
}

struct ModelConfiguration: Hashable, Codable {
    var provider: String = ModelProvider.openAI.rawValue
    var apiBaseURL = "https://api.openai.com/v1"
    var apiKey = ""
    var realtimeASRProvider = RealtimeASRProvider.macOSSpeech.rawValue
    var realtimeASRAPIKey = ""
    var realtimeASRModel = "fun-asr-realtime"
    var realtimeModel = "gpt-4o-realtime-preview"
    var translationModel = "gpt-4.1-mini"
    var summaryModel = "gpt-4.1-mini"
    var localLanguage = LocalMeetingLanguage.mandarinChinese.rawValue
}

struct ChatAgentConfiguration: Hashable, Codable {
    var isEnabled = true
    var scheme = "http"
    var host = "127.0.0.1"
    var port = 8000
    var basePath = ""
    var authToken = ""

    var baseURL: String {
        "\(scheme)://\(host):\(port)"
    }

    var apiBasePath: String {
        let cleanBasePath = normalizedBasePath
        if cleanBasePath.isEmpty {
            return "/api"
        }
        return "/\(cleanBasePath)/api"
    }

    var chatStreamPath: String {
        "\(apiBasePath)/agent/chat/stream"
    }

    var normalizedBasePath: String {
        var cleanBasePath = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if cleanBasePath.hasSuffix("api/agent/chat/stream") {
            cleanBasePath.removeLast("api/agent/chat/stream".count)
            cleanBasePath = cleanBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if cleanBasePath.hasSuffix("agent/chat/stream") {
            cleanBasePath.removeLast("agent/chat/stream".count)
            cleanBasePath = cleanBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        if cleanBasePath == "api" {
            return ""
        }
        if cleanBasePath.hasSuffix("/api") {
            cleanBasePath.removeLast("/api".count)
        }
        return cleanBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
