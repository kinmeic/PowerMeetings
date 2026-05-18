import SwiftUI
import Speech

struct SettingsView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case audio = "Audio"
        case realtime = "Realtime"
        case chatAgent = "Chat Agent"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @StateObject private var audioLevelMonitor = SettingsAudioLevelMonitor()

    @State private var selectedTab = SettingsTab.audio
    @State private var selectedAudioDeviceID: String?
    @State private var provider = ModelProvider.openAI.rawValue
    @State private var apiBaseURL = ""
    @State private var apiKey = ""
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
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 10)

            Group {
                switch selectedTab {
                case .audio:
                    audioSettings
                case .realtime:
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
                Text("Settings")
                    .font(.system(.title2, design: .serif, weight: .bold))
                Text("Configure audio capture, realtime models, and the external WorkAgent chat endpoint.")
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
            Section("Input Device") {
                Picker("Default input", selection: $selectedAudioDeviceID) {
                    ForEach(audioDeviceManager.devices) { device in
                        Text(device.isDefault ? "\(device.name) · System Default" : device.name)
                            .tag(Optional(device.id))
                    }
                }

                Button("Refresh Devices") {
                    audioDeviceManager.refreshDevices()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("macOS Speech")
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
                        Button("Refresh") {
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

                HStack(spacing: 14) {
                    Text("Input Level")
                    Spacer()
                    SettingsInputLevelMeter(level: audioLevelMonitor.level)
                }
            }

            Section("Capture Roadmap") {
                Toggle("Noise suppression", isOn: .constant(true))
                Toggle("System audio capture", isOn: .constant(false))
                Text("System audio capture will use ScreenCaptureKit and requires a separate macOS permission flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var realtimeModelSettings: some View {
        Form {
            Section("Realtime") {
                Picker("Provider", selection: $provider) {
                    ForEach(ModelProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider.rawValue)
                    }
                }

                TextField("API Base URL", text: $apiBaseURL)
                SecureField("API Key", text: $apiKey)
                Picker("Local Language", selection: $localLanguage) {
                    ForEach(LocalMeetingLanguage.allCases) { language in
                        Text(language.label).tag(language.rawValue)
                    }
                }
                TextField("Translation Model", text: $translationModel)
                TextField("Summary Model", text: $summaryModel)
                Text("Live transcription uses macOS Speech locally when Speech Recognition is authorized. The model provider is only used for realtime translation and meeting summaries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var chatAgentSettings: some View {
        Form {
            Section("WorkAgent Service") {
                Toggle("Enable Meeting Agent", isOn: $chatAgentEnabled)
                Picker("Scheme", selection: $chatAgentScheme) {
                    Text("http").tag("http")
                    Text("https").tag("https")
                }
                TextField("Address", text: $chatAgentHost)
                    .textContentType(.URL)
                TextField("Port", value: $chatAgentPort, formatter: Self.portFormatter)
                TextField("Base Path", text: $chatAgentBasePath)
                SecureField("Token", text: $chatAgentAuthToken)

                Text("PowerMeetings will call \(normalizedChatStreamURL) with `Authorization: Bearer <token>`, matching WorkAgent WebUI's `BASE_PATH + /api/agent/chat/stream` contract.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
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
        provider = modelSettings.provider
        apiBaseURL = modelSettings.apiBaseURL
        apiKey = modelSettings.apiKey
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
            "Authorized"
        case .notDetermined:
            "Not Authorized"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        @unknown default:
            "Unknown"
        }
    }

    private var speechAuthorizationButtonTitle: String {
        speechAuthorizationStatus == .notDetermined ? "Request Access" : "Open System Settings"
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
            speechAuthorizationMessage = "Requesting Speech Recognition access. If macOS does not show a prompt, open System Settings and enable PowerMeetings manually."

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if isRequestingSpeechAuthorization {
                    speechAuthorizationMessage = "Still waiting for macOS Speech Recognition. If no prompt appeared, use Open System Settings and enable PowerMeetings under Privacy & Security > Speech Recognition."
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
            "Speech Recognition is authorized. Live transcription can run locally."
        case .notDetermined:
            "macOS has not shown the Speech Recognition prompt yet."
        case .denied:
            "Speech Recognition was denied. Enable it in System Settings to use live transcription."
        case .restricted:
            "Speech Recognition is restricted on this Mac."
        @unknown default:
            "Speech Recognition status is unknown."
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
        modelSettings.provider = provider
        modelSettings.apiBaseURL = apiBaseURL
        modelSettings.apiKey = apiKey
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
