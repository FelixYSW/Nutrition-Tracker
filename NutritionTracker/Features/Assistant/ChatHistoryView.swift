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
                        ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                        ForEach(group.items) { conversation in
                            Button {
                                onOpen(conversation)
                                dismiss()
                            } label: {
                                row(for: conversation)
                            }
                            .buttonStyle(.plain)
                            // The open chat is highlighted with a tinted
                            // row instead of a small label.
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

    /// Newest first, under Today, Yesterday, This week and Earlier headings.
    private var groups: [(title: String, items: [SavedConversation])] {
        let calendar = Calendar.autoupdatingCurrent
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        func title(for date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            return date >= weekAgo ? "This week" : "Earlier"
        }
        var result: [(title: String, items: [SavedConversation])] = []
        for conversation in conversations {
            let name = title(for: conversation.updatedAt)
            if let index = result.firstIndex(where: { $0.title == name }) {
                result[index].items.append(conversation)
            } else {
                result.append((title: name, items: [conversation]))
            }
        }
        return result
    }

    private func row(for conversation: SavedConversation) -> some View {
        // The latest message is the title; under it, how many messages the
        // chat has and when the last one was sent.
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.latestMessage ?? conversation.title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(Self.messageCountLabel(conversation.messageCount))
                Text("\u{00B7}")
                Text(Self.lastMessageLabel(conversation.updatedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
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
            // Just a tint over the card colour, no side bar.
            ZStack {
                AppTheme.cardBackground
                AppTheme.accent.opacity(0.12)
            }
        } else {
            AppTheme.cardBackground
        }
    }

    /// "1 message", "12 messages".
    static func messageCountLabel(_ count: Int) -> String {
        "\(count) message\(count == 1 ? "" : "s")"
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
