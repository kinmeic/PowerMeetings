import SwiftUI
import Speech

struct SettingsView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case audio
        case general
        case chatAgent

        var id: String { String(describing: self) }

        func title(language: String) -> String {
            switch self {
            case .audio:
                AppText.t("audio", language: language)
            case .general:
                AppText.t("general", language: language)
            case .chatAgent:
                AppText.t("chatAgent", language: language)
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @StateObject private var audioLevelMonitor = SettingsAudioLevelMonitor()

    @State private var selectedTab = SettingsTab.audio
    @State private var selectedAudioDeviceID: String?
    @State private var noiseSuppressionEnabled = false
    @State private var systemAudioCaptureEnabled = false
    @State private var provider = ModelProvider.openAI.rawValue
    @State private var apiBaseURL = ""
    @State private var apiKey = ""
    @State private var realtimeASRProvider = RealtimeASRProvider.macOSSpeech.rawValue
    @State private var realtimeASRAPIKey = ""
    @State private var realtimeASRModel = ""
    @State private var translationModel = ""
    @State private var summaryModel = ""
    @State private var localLanguage = LocalMeetingLanguage.mandarinChinese.rawValue
    @State private var speechAuthorizationStatus = SpeechAuthorizationBridge.currentStatus
    @State private var speechAuthorizationMessage = ""
    @State private var isRequestingSpeechAuthorization = false
    @State private var chatAgentEnabled = true
    @State private var chatAgentScheme = "http"
    @State private var chatAgentHost = ""
    @State private var chatAgentPort = 8000
    @State private var chatAgentBasePath = ""
    @State private var chatAgentAuthToken = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title(language: localLanguage)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 10)

            Group {
                switch selectedTab {
                case .audio:
                    audioSettings
                case .general:
                    realtimeModelSettings
                case .chatAgent:
                    chatAgentSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 14)

            footer
        }
        .onAppear {
            audioDeviceManager.refreshDevices()
            loadDraftValues()
            speechAuthorizationStatus = SpeechAuthorizationBridge.currentStatus
            audioLevelMonitor.start(deviceID: selectedAudioDeviceID)
        }
        .onDisappear {
            audioLevelMonitor.stop()
        }
        .onChange(of: selectedAudioDeviceID) { _, deviceID in
            audioLevelMonitor.start(deviceID: deviceID)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppText.t("settings", language: localLanguage))
                    .font(.system(.title2, design: .serif, weight: .bold))
                Text(AppText.t("settingsDescription", language: localLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private var audioSettings: some View {
        Form {
            Section(AppText.t("inputDevice", language: localLanguage)) {
                Picker(AppText.t("defaultInput", language: localLanguage), selection: $selectedAudioDeviceID) {
                    ForEach(audioDeviceManager.devices) { device in
                        Text(device.isDefault ? "\(device.name) · \(AppText.t("systemDefault", language: localLanguage))" : device.name)
                            .tag(Optional(device.id))
                    }
                }

                Button(AppText.t("refreshDevices", language: localLanguage)) {
                    audioDeviceManager.refreshDevices()
                }

                if realtimeASRProvider == RealtimeASRProvider.macOSSpeech.rawValue {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(AppText.t("macOSSpeech", language: localLanguage))
                            Spacer()
                            Text(speechAuthorizationLabel)
                                .font(.caption.bold())
                                .foregroundStyle(speechAuthorizationColor)
                            Button(speechAuthorizationButtonTitle) {
                                Task {
                                    await requestSpeechAuthorization()
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(speechAuthorizationStatus == .authorized || isRequestingSpeechAuthorization)
                            Button(AppText.t("refresh", language: localLanguage)) {
                                refreshSpeechAuthorizationStatus()
                            }
                            .buttonStyle(.borderless)
                        }
                        if speechAuthorizationMessage.isEmpty == false {
                            Text(speechAuthorizationMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 14) {
                    Text(AppText.t("inputLevel", language: localLanguage))
                    Spacer()
                    SettingsInputLevelMeter(level: audioLevelMonitor.level)
                }
            }

            Section(AppText.t("captureProcessing", language: localLanguage)) {
                Toggle(AppText.t("noiseSuppression", language: localLanguage), isOn: $noiseSuppressionEnabled)
                Text(AppText.t("noiseSuppressionHelp", language: localLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(AppText.t("systemAudioCapture", language: localLanguage), isOn: $systemAudioCaptureEnabled)
                Text(AppText.t("systemAudioCaptureHelp", language: localLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var realtimeModelSettings: some View {
        Form {
            Section(AppText.t("asrProvider", language: localLanguage)) {
                Picker(AppText.t("realtimeASR", language: localLanguage), selection: $realtimeASRProvider) {
                    ForEach(RealtimeASRProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider.rawValue)
                    }
                }
                TextField(AppText.t("asrModel", language: localLanguage), text: $realtimeASRModel)
                SecureField(AppText.t("asrAPIKey", language: localLanguage), text: $realtimeASRAPIKey)
                Text(AppText.t("asrHelp", language: localLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(AppText.t("textModelProvider", language: localLanguage)) {
                Picker(AppText.t("llmProvider", language: localLanguage), selection: $provider) {
                    ForEach(ModelProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider.rawValue)
                    }
                }

                TextField(AppText.t("apiBaseURL", language: localLanguage), text: $apiBaseURL)
                SecureField(AppText.t("llmAPIKey", language: localLanguage), text: $apiKey)
                Picker(AppText.t("localLanguage", language: localLanguage), selection: $localLanguage) {
                    ForEach(LocalMeetingLanguage.allCases) { language in
                        Text(language.label).tag(language.rawValue)
                    }
                }
                TextField(AppText.t("translationModel", language: localLanguage), text: $translationModel)
                TextField(AppText.t("summaryModel", language: localLanguage), text: $summaryModel)
                Text(AppText.t("textModelHelp", language: localLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var chatAgentSettings: some View {
        Form {
            Section(AppText.t("workAgentService", language: localLanguage)) {
                Toggle(AppText.t("enableMeetingAgent", language: localLanguage), isOn: $chatAgentEnabled)
                Picker(AppText.t("scheme", language: localLanguage), selection: $chatAgentScheme) {
                    Text("http").tag("http")
                    Text("https").tag("https")
                }
                TextField(AppText.t("address", language: localLanguage), text: $chatAgentHost)
                    .textContentType(.URL)
                TextField(AppText.t("port", language: localLanguage), value: $chatAgentPort, formatter: Self.portFormatter)
                TextField(AppText.t("basePath", language: localLanguage), text: $chatAgentBasePath)
                SecureField(AppText.t("token", language: localLanguage), text: $chatAgentAuthToken)

                Text(String(format: AppText.t("chatAgentHelp", language: localLanguage), normalizedChatStreamURL))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(AppText.t("close", language: localLanguage)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(AppText.t("save", language: localLanguage)) {
                saveDraftValues()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.moss)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .background(.regularMaterial)
    }

    private var normalizedChatStreamURL: String {
        let configuration = ChatAgentConfiguration(
            scheme: chatAgentScheme,
            host: chatAgentHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: chatAgentPort,
            basePath: chatAgentBasePath,
            authToken: chatAgentAuthToken
        )
        guard configuration.host.isEmpty == false else {
            return "\(configuration.baseURL)\(configuration.chatStreamPath)"
        }
        return "\(configuration.baseURL)\(configuration.chatStreamPath)"
    }

    private func loadDraftValues() {
        selectedAudioDeviceID = audioDeviceManager.selectedDeviceID
        noiseSuppressionEnabled = modelSettings.noiseSuppressionEnabled
        systemAudioCaptureEnabled = modelSettings.systemAudioCaptureEnabled
        provider = modelSettings.provider
        apiBaseURL = modelSettings.apiBaseURL
        apiKey = modelSettings.apiKey
        realtimeASRProvider = modelSettings.realtimeASRProvider
        realtimeASRAPIKey = modelSettings.realtimeASRAPIKey
        realtimeASRModel = modelSettings.realtimeASRModel
        translationModel = modelSettings.translationModel
        summaryModel = modelSettings.summaryModel
        localLanguage = modelSettings.localLanguage
        chatAgentEnabled = modelSettings.chatAgentEnabled
        chatAgentScheme = modelSettings.chatAgentScheme
        chatAgentHost = modelSettings.chatAgentHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : modelSettings.chatAgentHost
        chatAgentPort = modelSettings.chatAgentPort
        chatAgentBasePath = modelSettings.chatAgentBasePath
        chatAgentAuthToken = modelSettings.chatAgentAuthToken
    }

    private var speechAuthorizationLabel: String {
        switch speechAuthorizationStatus {
        case .authorized:
            AppText.t("authorized", language: localLanguage)
        case .notDetermined:
            AppText.t("notAuthorized", language: localLanguage)
        case .denied:
            AppText.t("denied", language: localLanguage)
        case .restricted:
            AppText.t("restricted", language: localLanguage)
        @unknown default:
            AppText.t("unknown", language: localLanguage)
        }
    }

    private var speechAuthorizationButtonTitle: String {
        speechAuthorizationStatus == .notDetermined
            ? AppText.t("requestAccess", language: localLanguage)
            : AppText.t("openSystemSettings", language: localLanguage)
    }

    private var speechAuthorizationColor: Color {
        switch speechAuthorizationStatus {
        case .authorized:
            AppTheme.moss
        case .notDetermined:
            AppTheme.amber
        case .denied, .restricted:
            .red
        @unknown default:
            AppTheme.muted
        }
    }

    private func refreshSpeechAuthorizationStatus() {
        speechAuthorizationStatus = SpeechAuthorizationBridge.currentStatus
        speechAuthorizationMessage = speechAuthorizationMessage(for: speechAuthorizationStatus)
    }

    @MainActor
    private func requestSpeechAuthorization() async {
        refreshSpeechAuthorizationStatus()

        if speechAuthorizationStatus == .notDetermined {
            isRequestingSpeechAuthorization = true
            speechAuthorizationMessage = AppText.t("speechRequesting", language: localLanguage)

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if isRequestingSpeechAuthorization {
                    speechAuthorizationMessage = AppText.t("speechWaiting", language: localLanguage)
                }
            }

            let status = await SpeechAuthorizationBridge.requestStatus()
            isRequestingSpeechAuthorization = false
            speechAuthorizationStatus = status
            speechAuthorizationMessage = speechAuthorizationMessage(for: status)
            if status != .authorized {
                openSpeechPrivacySettings()
            }
        } else {
            speechAuthorizationMessage = speechAuthorizationMessage(for: speechAuthorizationStatus)
            openSpeechPrivacySettings()
        }
    }

    private func speechAuthorizationMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            AppText.t("speechAuthorized", language: localLanguage)
        case .notDetermined:
            AppText.t("speechNotDetermined", language: localLanguage)
        case .denied:
            AppText.t("speechDenied", language: localLanguage)
        case .restricted:
            AppText.t("speechRestricted", language: localLanguage)
        @unknown default:
            AppText.t("speechUnknown", language: localLanguage)
        }
    }

    private func openSpeechPrivacySettings() {
        #if os(macOS)
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for text in urls {
            if let url = URL(string: text), NSWorkspace.shared.open(url) {
                break
            }
        }
        #endif
    }

    private func saveDraftValues() {
        let normalizedEndpoint = normalizeChatAgentEndpoint(
            host: chatAgentHost,
            port: chatAgentPort,
            scheme: chatAgentScheme,
            basePath: chatAgentBasePath
        )
        audioDeviceManager.selectedDeviceID = selectedAudioDeviceID
        modelSettings.noiseSuppressionEnabled = noiseSuppressionEnabled
        modelSettings.systemAudioCaptureEnabled = systemAudioCaptureEnabled
        modelSettings.provider = provider
        modelSettings.apiBaseURL = apiBaseURL
        modelSettings.apiKey = apiKey
        modelSettings.realtimeASRProvider = realtimeASRProvider
        modelSettings.realtimeASRAPIKey = realtimeASRAPIKey
        modelSettings.realtimeASRModel = realtimeASRModel
        modelSettings.translationModel = translationModel
        modelSettings.summaryModel = summaryModel
        modelSettings.localLanguage = localLanguage
        modelSettings.chatAgentEnabled = chatAgentEnabled
        modelSettings.chatAgentScheme = normalizedEndpoint.scheme
        modelSettings.chatAgentHost = normalizedEndpoint.host
        modelSettings.chatAgentPort = normalizedEndpoint.port
        modelSettings.chatAgentBasePath = normalizedEndpoint.basePath
        modelSettings.chatAgentAuthToken = chatAgentAuthToken
        UserDefaults.standard.synchronize()
    }

    private func normalizeChatAgentEndpoint(
        host: String,
        port: Int,
        scheme: String,
        basePath: String
    ) -> (scheme: String, host: String, port: Int, basePath: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return (scheme, "127.0.0.1", port, ChatAgentConfiguration(basePath: basePath).normalizedBasePath)
        }

        let urlText: String
        if trimmed.contains("://") {
            urlText = trimmed
        } else {
            urlText = "\(scheme)://\(trimmed)"
        }

        guard let components = URLComponents(string: urlText),
              let parsedHost = components.host else {
            return (scheme, trimmed, port, ChatAgentConfiguration(basePath: basePath).normalizedBasePath)
        }

        let pathBase = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combinedBasePath = pathBase.isEmpty ? basePath : pathBase

        return (
            components.scheme ?? scheme,
            parsedHost,
            components.port ?? port,
            ChatAgentConfiguration(basePath: combinedBasePath).normalizedBasePath
        )
    }

    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.usesGroupingSeparator = false
        formatter.minimum = 1
        formatter.maximum = 65_535
        return formatter
    }()
}

private struct SettingsInputLevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [AppTheme.moss, AppTheme.amber], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * level))
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
