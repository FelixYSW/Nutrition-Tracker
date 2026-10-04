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
                            .listRowBackground(AppTheme.cardBackground)
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
                Text(conversation.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if conversation.id == currentID {
                Text("Open now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            } else if let preview = conversation.preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
