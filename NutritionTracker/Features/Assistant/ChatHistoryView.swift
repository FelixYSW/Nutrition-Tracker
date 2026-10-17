import SwiftUI

/// Past assistant chats, newest first. Tap one to reopen it; swipe to delete.
struct ChatHistoryView: View {
    /// The chat on screen, marked in the list and not deletable from here.
    let currentID: UUID?
    let onOpen: (SavedConversation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [SavedConversation] = []
    @State private var isConfirmingDeleteAll = false

    private let store = ChatHistoryStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    EmptyStateView(title: "No past chats",
                                   message: "Chats with the assistant are saved here on this "
                                       + "iPhone, so you can come back to them.",
                                   systemImage: "clock.arrow.circlepath")
                } else {
                    List {
                        ForEach(conversations) { conversation in
                            Button {
                                onOpen(conversation)
                                dismiss()
                            } label: {
                                row(for: conversation)
                            }
                            .buttonStyle(.plain)
                            // The open chat is highlighted - a tinted row
                            // with an accent bar - instead of a small label.
                            .listRowBackground(rowBackground(isOpen: conversation.id == currentID))
                            .swipeActions {
                                if conversation.id != currentID {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        delete(conversation)
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Past chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Delete all past chats", systemImage: "trash", role: .destructive) {
                            isConfirmingDeleteAll = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("More options")
                    }
                    .disabled(conversations.allSatisfy { $0.id == currentID })
                }
            }
            .alert("Delete all past chats?", isPresented: $isConfirmingDeleteAll) {
                Button("Delete", role: .destructive) { deleteAllPast() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The chat you have open stays. Food you logged through the assistant "
                     + "is not affected.")
            }
        }
        .onAppear { conversations = store.all() }
    }

    private func row(for conversation: SavedConversation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.lastMessageLabel(conversation.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let preview = conversation.preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(conversation.id == currentID ? "Open now" : "")
        .accessibilityAddTraits(conversation.id == currentID ? .isSelected : [])
    }

    @ViewBuilder
    private func rowBackground(isOpen: Bool) -> some View {
        if isOpen {
            ZStack(alignment: .leading) {
                AppTheme.cardBackground
                AppTheme.accent.opacity(0.12)
                AppTheme.accent
                    .frame(width: 4)
            }
        } else {
            AppTheme.cardBackground
        }
    }

    /// When the chat's last message was sent: "Today, 3:42 PM",
    /// "Yesterday, 9:05 AM", "13 Oct, 3:42 PM", or with the year once it's
    /// not this year.
    static func lastMessageLabel(_ date: Date, now: Date = .now,
                                 calendar: Calendar = .autoupdatingCurrent) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(day), \(time)"
    }

    private func delete(_ conversation: SavedConversation) {
        store.delete(id: conversation.id)
        withAnimation { conversations.removeAll { $0.id == conversation.id } }
    }

    private func deleteAllPast() {
        for conversation in conversations where conversation.id != currentID {
            store.delete(id: conversation.id)
        }
        withAnimation { conversations.removeAll { $0.id != currentID } }
    }
}
