import SwiftUI

@main
struct PowerMeetingsApp: App {
    @StateObject private var meetingStore = MeetingStore()
    @StateObject private var audioDeviceManager = AudioDeviceManager()
    @StateObject private var modelSettings = ModelSettingsStore()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(meetingStore)
                .environmentObject(audioDeviceManager)
                .environmentObject(modelSettings)
                .frame(minWidth: 1180, minHeight: 760)
                .task {
                    audioDeviceManager.refreshDevices()
                    meetingStore.bootstrapSampleData()
                }
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(audioDeviceManager)
                .environmentObject(modelSettings)
                .frame(width: 720, height: 560)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text(AppText.t("settingsMenu", language: modelSettings.localLanguage))
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
