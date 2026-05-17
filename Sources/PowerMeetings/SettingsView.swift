import SwiftUI

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

    @State private var selectedTab = SettingsTab.audio
    @State private var selectedAudioDeviceID: String?
    @State private var provider = ModelProvider.openAI.rawValue
    @State private var apiBaseURL = ""
    @State private var apiKey = ""
    @State private var realtimeModel = ""
    @State private var translationModel = ""
    @State private var localLanguage = LocalMeetingLanguage.mandarinChinese.rawValue
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
            Section("Provider") {
                Picker("Provider", selection: $provider) {
                    ForEach(ModelProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider.rawValue)
                    }
                }

                TextField("API Base URL", text: $apiBaseURL)
                SecureField("API Key", text: $apiKey)
            }

            Section("Realtime Pipeline") {
                Picker("Local Language", selection: $localLanguage) {
                    ForEach(LocalMeetingLanguage.allCases) { language in
                        Text(language.label).tag(language.rawValue)
                    }
                }
                TextField("Realtime ASR / Audio Model", text: $realtimeModel)
                TextField("Translation Model", text: $translationModel)
                Text("PowerMeetings listens for Mandarin and English locally. Speech matching the local language is shown as-is; the other language is translated using the configured model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var chatAgentSettings: some View {
        Form {
            Section("WorkAgent Service") {
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
        realtimeModel = modelSettings.realtimeModel
        translationModel = modelSettings.translationModel
        localLanguage = modelSettings.localLanguage
        chatAgentScheme = modelSettings.chatAgentScheme
        chatAgentHost = modelSettings.chatAgentHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : modelSettings.chatAgentHost
        chatAgentPort = modelSettings.chatAgentPort
        chatAgentBasePath = modelSettings.chatAgentBasePath
        chatAgentAuthToken = modelSettings.chatAgentAuthToken
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
        modelSettings.realtimeModel = realtimeModel
        modelSettings.translationModel = translationModel
        modelSettings.localLanguage = localLanguage
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
