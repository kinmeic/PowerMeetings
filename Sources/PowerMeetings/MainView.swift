import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MainView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @State private var isShowingSettings = false

    var body: some View {
        NavigationSplitView {
            MeetingListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } content: {
            MeetingWorkspaceView()
                .navigationSplitViewColumnWidth(min: 520, ideal: 650)
        } detail: {
            if modelSettings.chatAgentEnabled {
                AgentPanelView()
                    .navigationSplitViewColumnWidth(min: 340, ideal: 400)
            } else {
                EmptyView()
                    .navigationSplitViewColumnWidth(min: 0, ideal: 0)
            }
        }
        .background(AppTheme.background)
        .navigationTitle(meetingStore.selectedMeeting?.title ?? "PowerMeetings")
        .background(WindowTitleUpdater(title: meetingStore.selectedMeeting?.title ?? "PowerMeetings"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .frame(width: 720, height: 560)
        }
    }
}

#if os(macOS)
private struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}
#else
private struct WindowTitleUpdater: View {
    let title: String
    var body: some View { EmptyView() }
}
#endif

enum AppTheme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.96, green: 0.94, blue: 0.89),
            Color(red: 0.89, green: 0.93, blue: 0.94)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let ink = Color(red: 0.13, green: 0.15, blue: 0.16)
    static let muted = Color(red: 0.42, green: 0.46, blue: 0.46)
    static let card = Color.white.opacity(0.76)
    static let amber = Color(red: 0.94, green: 0.58, blue: 0.24)
    static let moss = Color(red: 0.30, green: 0.46, blue: 0.37)
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24) -> some View {
        background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.65), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.07), radius: 18, x: 0, y: 10)
    }
}

extension TimeInterval {
    var clockString: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
