import Foundation

enum AppText {
    static func isChinese(_ language: String) -> Bool {
        language.lowercased().hasPrefix("zh")
    }

    static func t(_ key: String, language: String) -> String {
        guard isChinese(language) else {
            return english[key] ?? key
        }
        return chinese[key] ?? english[key] ?? key
    }

    private static let english: [String: String] = [
        "settings": "Settings",
        "settingsMenu": "Settings...",
        "settingsDescription": "Configure audio capture, ASR, text models, and the external WorkAgent meeting assistant endpoint.",
        "audio": "Audio",
        "general": "General",
        "chatAgent": "Meeting Agent",
        "inputDevice": "Input Device",
        "defaultInput": "Default input",
        "systemDefault": "System Default",
        "refreshDevices": "Refresh Devices",
        "macOSSpeech": "macOS Speech",
        "refresh": "Refresh",
        "inputLevel": "Input Level",
        "captureProcessing": "Capture Processing",
        "noiseSuppression": "Noise suppression",
        "noiseSuppressionHelp": "Uses an AVAudioEngine processing chain with a high-pass filter and dynamics processor before writing the microphone track. If processing cannot start, recording falls back to the standard recorder.",
        "systemAudioCapture": "System audio capture",
        "systemAudioCaptureHelp": "Captures system/app playback with ScreenCaptureKit and mixes it into the meeting recording when the meeting ends. macOS may ask for Screen Recording permission.",
        "screenRecordingPermission": "Screen Recording",
        "screenRecordingAuthorized": "Authorized",
        "screenRecordingNotAuthorized": "Not Authorized",
        "requestScreenRecording": "Request Access",
        "systemAudioPermissionHelp": "System audio capture requires Screen Recording permission. If macOS asks for permission, restart PowerMeetings after granting access.",
        "asrProvider": "ASR Provider",
        "realtimeASR": "Realtime ASR",
        "asrModel": "ASR Model",
        "asrAPIKey": "ASR API Key",
        "asrHelp": "Recommended for meetings: `fun-asr-realtime` with 16 kHz PCM. Use `paraformer-realtime-8k-v2` only for 8 kHz telephone-style Chinese audio.",
        "textModelProvider": "Text Model Provider",
        "llmProvider": "LLM Provider",
        "apiBaseURL": "API Base URL",
        "llmAPIKey": "LLM API Key",
        "localLanguage": "Local Language",
        "translationModel": "Translation Model",
        "summaryModel": "Summary Model",
        "textModelHelp": "Used for realtime translation and meeting summaries. Alibaba Cloud Bailian is OpenAI-compatible; use `https://dashscope.aliyuncs.com/compatible-mode/v1` with models such as `qwen-mt-turbo`.",
        "workAgentService": "WorkAgent Service",
        "enableMeetingAgent": "Enable Meeting Agent",
        "scheme": "Scheme",
        "address": "Address",
        "port": "Port",
        "basePath": "Base Path",
        "token": "Token",
        "chatAgentHelp": "PowerMeetings will call %@ with `Authorization: Bearer <token>`, matching WorkAgent WebUI's `BASE_PATH + /api/agent/chat/stream` contract.",
        "close": "Close",
        "save": "Save",
        "authorized": "Authorized",
        "notAuthorized": "Not Authorized",
        "denied": "Denied",
        "restricted": "Restricted",
        "unknown": "Unknown",
        "requestAccess": "Request Access",
        "openSystemSettings": "Open System Settings",
        "speechRequesting": "Requesting Speech Recognition access. If macOS does not show a prompt, open System Settings and enable PowerMeetings manually.",
        "speechWaiting": "Still waiting for macOS Speech Recognition. If no prompt appeared, use Open System Settings and enable PowerMeetings under Privacy & Security > Speech Recognition.",
        "speechAuthorized": "Speech Recognition is authorized. Live transcription can run locally.",
        "speechNotDetermined": "macOS has not shown the Speech Recognition prompt yet.",
        "speechDenied": "Speech Recognition was denied. Enable it in System Settings to use live transcription.",
        "speechRestricted": "Speech Recognition is restricted on this Mac.",
        "speechUnknown": "Speech Recognition status is unknown.",
        "live": "Live",
        "people": "People",
        "summary": "Summary",
        "log": "Log",
        "noMeetingSelected": "No meeting selected",
        "editMeetingName": "Edit meeting name",
        "editMeetingNameTitle": "Edit Meeting Name",
        "meetingName": "Meeting name",
        "cancel": "Cancel",
        "startMeeting": "Start Meeting",
        "startMeetingHelp": "Start meeting",
        "activeMeetingHelp": "End the current active meeting before starting another.",
        "pause": "Pause",
        "resume": "Resume",
        "generating": "Generating...",
        "saving": "Saving...",
        "stop": "Stop",
        "play": "Play",
        "endMeeting": "End Meeting",
        "exportRecording": "Export recording",
        "transcribing": "Transcribing...",
        "transcribeRecording": "Transcribe Recording",
        "readyLiveTitle": "Ready for live transcription",
        "readyLiveDescription": "Start the meeting and transcript segments will appear here.",
        "providerNotConnected": "Realtime translation provider is not connected",
        "providerStatus": "ASR: macOS Speech · Translation: %@",
        "translation": "Translation",
        "capturing": "Capturing",
        "temporary": "temporary",
        "meetingSummary": "Meeting Summary",
        "generateSummary": "Generate Summary",
        "generateSummaryHelp": "Generate and save meeting summary",
        "configureSummaryHelp": "Configure API Key and Summary Model in Settings first.",
        "summaryFailed": "Summary generation failed. Please check the Summary Model, API Base URL, and API Key.",
        "noSummaryYet": "No summary yet.",
        "noSummaryAction": "No summary yet. Click Generate Summary when you are ready.",
        "participants": "Participants",
        "onePersonPerLine": "One person per line",
        "meetingLog": "Meeting Log",
        "noLogsYet": "No logs yet",
        "logsDescription": "Realtime ASR and capture status messages will appear here.",
        "renameMeeting": "Rename Meeting",
        "deleteMeeting": "Delete Meeting",
        "clearSearch": "Clear search",
        "searchMeetings": "Search meetings",
        "tagline": "Live memory for serious meetings",
        "scheduled": "Scheduled",
        "inProgress": "In Progress",
        "paused": "Paused",
        "processing": "Processing",
        "ended": "Ended",
        "transcript": "transcript",
        "question": "question",
        "decision": "decision",
        "actionItem": "action item",
        "meetingAgent": "Meeting Agent",
        "askMeeting": "Ask about this meeting...",
        "thinking": "Thinking...",
        "usingTools": "Using tools...",
        "copied": "Copied",
        "copyMessage": "Copy message",
        "checking": "Checking",
        "online": "Online",
        "offline": "Offline",
        "you": "You",
        "agent": "Agent",
        "suggestion": "Suggestion",
        "clarificationNeeded": "Clarification needed",
        "answered": "Answered",
        "reply": "Reply",
        "replyPlaceholder": "Reply...",
        "approvalRequired": "Command approval required",
        "allow": "Allow",
        "deny": "Deny",
        "always": "Always",
        "agentReady": "I am ready to help with this meeting's notes, questions, and follow-up work.",
        "healthCheckingHelp": "Checking Meeting Agent health.",
        "healthOnlineHelp": "Meeting Agent health check is passing.",
        "healthOfflineHelp": "Meeting Agent health check failed: %@",
        "statusNeedsAttention": "Needs attention",
        "statusDegraded": "Degraded",
        "statusInfo": "Info",
        "openSettings": "Open Settings",
        "viewLogs": "View Logs",
        "microphoneIssue": "Microphone access or recording startup failed. Recording could not begin.",
        "speechPermissionIssue": "Realtime transcription is unavailable because Speech Recognition is not authorized. Recording can continue normally.",
        "asrConfigIssue": "Realtime ASR is selected but its API key is missing. Recording can continue, but live transcription may be unavailable.",
        "translationConfigIssue": "Translation model is not fully configured. Transcripts will still appear; translation will be skipped.",
        "systemAudioIssue": "System audio capture reported a warning. Microphone recording can continue; check logs for details.",
        "recordingSafe": "Recording continues safely unless this message says recording could not begin."
    ]

    private static let chinese: [String: String] = [
        "settings": "设置",
        "settingsMenu": "设置...",
        "settingsDescription": "配置音频采集、ASR、文本模型以及外部 WorkAgent 会议助手端点。",
        "audio": "音频",
        "general": "通用",
        "chatAgent": "会议助手",
        "inputDevice": "输入设备",
        "defaultInput": "默认输入",
        "systemDefault": "系统默认",
        "refreshDevices": "刷新设备",
        "macOSSpeech": "macOS 语音识别",
        "refresh": "刷新",
        "inputLevel": "输入电平",
        "captureProcessing": "采集处理",
        "noiseSuppression": "降噪",
        "noiseSuppressionHelp": "录音前会通过 AVAudioEngine 加入高通滤波和动态处理；如果处理链路无法启动，会自动回退到标准录音。",
        "systemAudioCapture": "系统音频采集",
        "systemAudioCaptureHelp": "使用 ScreenCaptureKit 捕捉系统或 App 播放声音，并在会议结束时混入录音。macOS 可能会请求屏幕录制权限。",
        "screenRecordingPermission": "屏幕录制",
        "screenRecordingAuthorized": "已授权",
        "screenRecordingNotAuthorized": "未授权",
        "requestScreenRecording": "请求授权",
        "systemAudioPermissionHelp": "系统音频采集需要屏幕录制权限。macOS 授权后，请重新启动 PowerMeetings 再开始录音。",
        "asrProvider": "ASR 提供方",
        "realtimeASR": "实时 ASR",
        "asrModel": "ASR 模型",
        "asrAPIKey": "ASR API Key",
        "asrHelp": "会议场景推荐 `fun-asr-realtime` 和 16 kHz PCM；`paraformer-realtime-8k-v2` 更适合 8 kHz 电话中文音频。",
        "textModelProvider": "文本模型提供方",
        "llmProvider": "大模型提供方",
        "apiBaseURL": "API Base URL",
        "llmAPIKey": "大模型 API Key",
        "localLanguage": "本地语言",
        "translationModel": "翻译模型",
        "summaryModel": "总结模型",
        "textModelHelp": "用于实时翻译和会议总结。阿里云百炼兼容 OpenAI 接口，可使用 `https://dashscope.aliyuncs.com/compatible-mode/v1` 和 `qwen-mt-turbo` 等模型。",
        "workAgentService": "WorkAgent 服务",
        "enableMeetingAgent": "启用会议助手",
        "scheme": "协议",
        "address": "地址",
        "port": "端口",
        "basePath": "Base Path",
        "token": "Token",
        "chatAgentHelp": "PowerMeetings 会调用 %@，并带上 `Authorization: Bearer <token>`，与 WorkAgent WebUI 的 `BASE_PATH + /api/agent/chat/stream` 约定保持一致。",
        "close": "关闭",
        "save": "保存",
        "authorized": "已授权",
        "notAuthorized": "未授权",
        "denied": "已拒绝",
        "restricted": "受限制",
        "unknown": "未知",
        "requestAccess": "请求授权",
        "openSystemSettings": "打开系统设置",
        "speechRequesting": "正在请求语音识别权限。如果 macOS 没有弹窗，请打开系统设置手动允许 PowerMeetings。",
        "speechWaiting": "仍在等待 macOS 语音识别权限。如果没有弹窗，请打开系统设置，在“隐私与安全性 > 语音识别”中允许 PowerMeetings。",
        "speechAuthorized": "语音识别已授权，可以使用本地实时转写。",
        "speechNotDetermined": "macOS 还没有显示语音识别授权弹窗。",
        "speechDenied": "语音识别权限已被拒绝。请在系统设置中开启后再使用实时转写。",
        "speechRestricted": "这台 Mac 上语音识别权限受限制。",
        "speechUnknown": "语音识别授权状态未知。",
        "live": "实时",
        "people": "人员",
        "summary": "总结",
        "log": "日志",
        "noMeetingSelected": "未选择会议",
        "editMeetingName": "编辑会议名称",
        "editMeetingNameTitle": "编辑会议名称",
        "meetingName": "会议名称",
        "cancel": "取消",
        "startMeeting": "开始会议",
        "startMeetingHelp": "开始会议",
        "activeMeetingHelp": "请先结束当前进行中的会议。",
        "pause": "暂停",
        "resume": "恢复",
        "generating": "生成中...",
        "saving": "保存中...",
        "stop": "停止",
        "play": "播放",
        "endMeeting": "结束会议",
        "exportRecording": "导出录音",
        "transcribing": "转写中...",
        "transcribeRecording": "转写录音",
        "readyLiveTitle": "准备实时转写",
        "readyLiveDescription": "开始会议后，转写内容会显示在这里。",
        "providerNotConnected": "实时翻译提供方尚未连接",
        "providerStatus": "ASR：macOS 语音识别 · 翻译：%@",
        "translation": "翻译",
        "capturing": "捕捉中",
        "temporary": "临时",
        "meetingSummary": "会议总结",
        "generateSummary": "生成总结",
        "generateSummaryHelp": "生成并保存会议总结",
        "configureSummaryHelp": "请先在设置中配置 API Key 和总结模型。",
        "summaryFailed": "会议总结生成失败，请检查总结模型、API Base URL 和 API Key。",
        "noSummaryYet": "暂无总结。",
        "noSummaryAction": "暂无总结。准备好后点击生成总结。",
        "participants": "参会人员",
        "onePersonPerLine": "每行一个人",
        "meetingLog": "会议日志",
        "noLogsYet": "暂无日志",
        "logsDescription": "实时 ASR 和采集状态会显示在这里。",
        "renameMeeting": "重命名会议",
        "deleteMeeting": "删除会议",
        "clearSearch": "清除搜索",
        "searchMeetings": "搜索会议",
        "tagline": "严肃会议的实时记忆",
        "scheduled": "未开始",
        "inProgress": "进行中",
        "paused": "已暂停",
        "processing": "处理中",
        "ended": "已结束",
        "transcript": "转写",
        "question": "问题",
        "decision": "决策",
        "actionItem": "待办",
        "meetingAgent": "会议助手",
        "askMeeting": "询问这场会议...",
        "thinking": "思考中...",
        "usingTools": "正在调用工具...",
        "copied": "已复制",
        "copyMessage": "复制消息",
        "checking": "检查中",
        "online": "在线",
        "offline": "离线",
        "you": "你",
        "agent": "会议助手",
        "suggestion": "建议",
        "clarificationNeeded": "需要补充信息",
        "answered": "已回答",
        "reply": "回复",
        "replyPlaceholder": "回复...",
        "approvalRequired": "需要命令审批",
        "allow": "允许",
        "deny": "拒绝",
        "always": "始终允许",
        "agentReady": "我已经准备好协助处理这场会议的笔记、问题和后续事项。",
        "healthCheckingHelp": "正在检查会议助手状态。",
        "healthOnlineHelp": "会议助手健康检查正常。",
        "healthOfflineHelp": "会议助手健康检查失败：%@",
        "statusNeedsAttention": "需要处理",
        "statusDegraded": "功能降级",
        "statusInfo": "提示",
        "openSettings": "打开设置",
        "viewLogs": "查看日志",
        "microphoneIssue": "麦克风权限或录音启动失败，录音没有成功开始。",
        "speechPermissionIssue": "语音识别未授权，实时转写不可用；录音仍可正常继续。",
        "asrConfigIssue": "已选择实时 ASR，但缺少 API Key。录音会继续，但实时转写可能不可用。",
        "translationConfigIssue": "翻译模型未完整配置。转写仍会正常显示，翻译会被跳过。",
        "systemAudioIssue": "系统音频采集出现警告。麦克风录音仍可继续，请查看日志了解详情。",
        "recordingSafe": "除非提示录音未能开始，否则录音主链路会继续运行。"
    ]
}

extension AppText {
    static func meetingDateTime(_ date: Date, language: String) -> String {
        guard isChinese(language) else {
            return date.formatted(date: .abbreviated, time: .shortened)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func localizedDefaultSummary(_ summary: String, language: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownDefaults = [
            english["noSummaryYet"],
            english["noSummaryAction"],
            "No summary yet. Start recording to build the meeting memory.",
            chinese["noSummaryYet"],
            chinese["noSummaryAction"]
        ].compactMap { $0 }

        guard knownDefaults.contains(trimmed) else { return summary }
        return t(trimmed.contains("Click Generate Summary") ? "noSummaryAction" : "noSummaryYet", language: language)
    }

    static func localizedAgentContent(_ content: String, language: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == english["agentReady"] || trimmed == chinese["agentReady"] else {
            return content
        }
        return t("agentReady", language: language)
    }
}

extension MeetingStatus {
    func localizedTitle(language: String) -> String {
        switch self {
        case .scheduled:
            AppText.t("scheduled", language: language)
        case .inProgress:
            AppText.t("inProgress", language: language)
        case .paused:
            AppText.t("paused", language: language)
        case .processing:
            AppText.t("processing", language: language)
        case .completed:
            AppText.t("ended", language: language)
        }
    }
}

extension SegmentKind {
    func localizedTitle(language: String) -> String {
        switch self {
        case .transcript:
            AppText.t("transcript", language: language)
        case .question:
            AppText.t("question", language: language)
        case .decision:
            AppText.t("decision", language: language)
        case .actionItem:
            AppText.t("actionItem", language: language)
        }
    }
}
