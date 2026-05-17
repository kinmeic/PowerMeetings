import SwiftUI

struct MeetingListView: View {
    @EnvironmentObject private var meetingStore: MeetingStore
    @State private var searchText = ""
    @State private var editingMeetingID: Meeting.ID?
    @State private var draftTitle = ""
    @FocusState private var focusedRenameID: Meeting.ID?

    private var filteredMeetings: [Meeting] {
        guard searchText.isEmpty == false else { return meetingStore.meetings }
        return meetingStore.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            searchField

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredMeetings) { meeting in
                        MeetingRowView(
                            meeting: meeting,
                            isSelected: meeting.id == meetingStore.selectedMeeting?.id,
                            isEditing: editingMeetingID == meeting.id,
                            draftTitle: bindingForDraftTitle(meetingID: meeting.id),
                            focusedRenameID: $focusedRenameID,
                            onCommitRename: { commitRename(for: meeting.id) },
                            onCancelRename: cancelRename
                        )
                        .onTapGesture {
                            if editingMeetingID == nil {
                                meetingStore.selectedMeetingID = meeting.id
                            }
                        }
                        .contextMenu {
                            Button {
                                beginRename(meeting)
                            } label: {
                                Label("Rename Meeting", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                meetingStore.deleteMeeting(id: meeting.id)
                            } label: {
                                Label("Delete Meeting", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(22)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("Search meetings", text: $searchText)
                .textFieldStyle(.plain)

            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.muted.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white.opacity(0.7), in: Capsule())
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PowerMeetings")
                    .font(.system(.title2, design: .serif, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                Text("Live memory for serious meetings")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }

            Spacer()

            Button {
                meetingStore.createMeeting()
            } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .background(AppTheme.ink, in: Circle())
            .foregroundStyle(.white)
        }
    }

    private func bindingForDraftTitle(meetingID: Meeting.ID) -> Binding<String> {
        Binding(
            get: { editingMeetingID == meetingID ? draftTitle : "" },
            set: { newValue in
                if editingMeetingID == meetingID {
                    draftTitle = newValue
                }
            }
        )
    }

    private func beginRename(_ meeting: Meeting) {
        meetingStore.selectedMeetingID = meeting.id
        editingMeetingID = meeting.id
        draftTitle = meeting.title
        focusedRenameID = meeting.id
    }

    private func commitRename(for meetingID: Meeting.ID) {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty == false {
            meetingStore.renameMeeting(id: meetingID, title: title)
        }
        cancelRename()
    }

    private func cancelRename() {
        editingMeetingID = nil
        draftTitle = ""
        focusedRenameID = nil
    }
}

private struct MeetingRowView: View {
    let meeting: Meeting
    let isSelected: Bool
    let isEditing: Bool
    @Binding var draftTitle: String
    var focusedRenameID: FocusState<Meeting.ID?>.Binding
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                statusPill
                Spacer()
                Text(meeting.scheduledAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }

            if isEditing {
                TextField("Meeting name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .focused(focusedRenameID, equals: meeting.id)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text(meeting.title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 20)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? AppTheme.amber : .clear)
                .frame(width: 5)
                .padding(.vertical, 18)
        }
    }

    private var statusPill: some View {
        Text(meeting.status.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(statusColor.opacity(0.16), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch meeting.status {
        case .scheduled: AppTheme.muted
        case .inProgress: .red
        case .paused: AppTheme.amber
        case .processing: .blue
        case .completed: AppTheme.moss
        }
    }
}
