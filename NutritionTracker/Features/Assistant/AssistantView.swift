import SwiftUI
import SwiftData
import PhotosUI

/// Assistant chat, one of the five destinations in the floating tab bar
/// (spec section 29A).
struct AssistantView: View {
    @Environment(\.modelContext) private var context

    @State private var viewModel: AssistantViewModel?
    @State private var photoSelection: PhotosPickerItem?
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear conversation", systemImage: "trash") {
                            viewModel?.clearConversation()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("More options")
                    }
                }
            }
        }
        .onAppear {
            if viewModel == nil {
                let settings = context.loadAppSettings()
                viewModel = AssistantViewModel.make(context: context, settings: settings)
            }
        }
    }

    @ViewBuilder
    private func content(viewModel: AssistantViewModel) -> some View {
        VStack(spacing: 0) {
            switch viewModel.availability {
            case .needsOptIn:
                setupState(
                    title: "Turn on the assistant",
                    message: AssistantContextBuilder.dataSharingDisclosure,
                    actionTitle: "Open Settings")

            case .needsAPIKey:
                setupState(
                    title: "Add an API key",
                    message: "The assistant needs an API key for your chosen provider. "
                        + "Add one in Settings under AI.",
                    actionTitle: "Open Settings")

            case .ready:
                transcript(viewModel: viewModel)
                composer(viewModel: viewModel)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
    }

    private func setupState(title: String, message: String, actionTitle: String) -> some View {
        VStack {
            Spacer()
            EmptyStateView(title: title,
                           message: message,
                           systemImage: "sparkles",
                           actionTitle: actionTitle) {
                isShowingSettings = true
            }
            Spacer()
        }
    }

    private func transcript(viewModel: AssistantViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if viewModel.messages.isEmpty {
                        suggestionsCard(viewModel: viewModel)
                    }

                    ForEach(viewModel.messages) { message in
                        messageRow(message: message, viewModel: viewModel)
                            .id(message.id)
                    }

                    if viewModel.isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking\u{2026}")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, AppTheme.cardPadding)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func suggestionsCard(viewModel: AssistantViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about your own data")
                .font(.headline)
            Text("The assistant can see today's targets and food log, and your "
                 + "recent trends. It always asks before changing anything.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.starterPrompts, id: \.self) { prompt in
                Button {
                    viewModel.composerText = prompt
                } label: {
                    HStack {
                        Text(prompt)
                            .font(.footnote)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.subtleFill,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .appCard()
    }

    static let starterPrompts = [
        "What should I eat with the room I have left today?",
        "How has my protein looked over the last week?",
        "Add a plate of nasi lemak",
        "What could I do better based on my log?"
    ]

    @ViewBuilder
    private func messageRow(message: AssistantChatMessage,
                            viewModel: AssistantViewModel) -> some View {
        switch message.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AppTheme.accentFill, in: RoundedRectangle(
                        cornerRadius: 20, style: .continuous))
                    .foregroundStyle(AppTheme.onAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .assistant(let text):
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardBackground, in: RoundedRectangle(
                    cornerRadius: 16, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .proposal(let write):
            // Only render as actionable while it is still the pending one.
            AssistantConfirmationCard(
                write: write,
                isActive: viewModel.pendingWrite?.id == write.id,
                onConfirm: { Task { await viewModel.confirmPendingWrite() } },
                onDecline: { Task { await viewModel.declinePendingWrite() } })

        case .proposalResolved(let summary, let confirmed):
            HStack(spacing: 6) {
                Image(systemName: confirmed ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(confirmed ? .green : .secondary)
                    .accessibilityHidden(true)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .toolActivity(let label):
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

        case .error(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func composer(viewModel: AssistantViewModel) -> some View {
        VStack(spacing: 8) {
            if viewModel.attachedImageData != nil {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .accessibilityHidden(true)
                    Text("Menu photo attached")
                        .font(.caption)
                    Spacer()
                    Button("Remove") { viewModel.attachedImageData = nil }
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            if viewModel.pendingWrite != nil {
                Text("Respond to the confirmation above to carry on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Image(systemName: "photo")
                        .frame(width: AppTheme.minimumTapTarget,
                               height: AppTheme.minimumTapTarget)
                }
                .accessibilityLabel("Attach a menu photo")

                TextField("Ask anything about your nutrition",
                          text: Binding(get: { viewModel.composerText },
                                        set: { viewModel.composerText = $0 }),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AppTheme.subtleFill, in: Capsule())

                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(width: AppTheme.minimumTapTarget,
                               height: AppTheme.minimumTapTarget)
                }
                .disabled(!viewModel.canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, AppTheme.cardPadding)
        .padding(.vertical, 10)
        .background(.bar)
        .onChange(of: photoSelection) { _, newValue in
            guard let newValue else { return }
            Task {
                // Downsized before upload so a 12MP photo is not sent whole.
                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    #if canImport(UIKit)
                    if let prepared = try? ImagePreparer.prepare(data: data) {
                        viewModel.attachedImageData = prepared.jpegData
                    } else {
                        viewModel.attachedImageData = data
                    }
                    #else
                    viewModel.attachedImageData = data
                    #endif
                }
                photoSelection = nil
            }
        }
    }
}

/// The confirmation card. No assistant write reaches the database without the
/// user tapping through this (spec section 29A).
struct AssistantConfirmationCard: View {
    let write: PendingAssistantWrite
    let isActive: Bool
    let onConfirm: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: write.isDestructive ? "trash.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(write.isDestructive ? .red : AppTheme.accent)
                    .accessibilityHidden(true)
                Text(write.confirmationTitle)
                    .font(.subheadline.weight(.semibold))
            }

            detail

            if isActive {
                HStack(spacing: 10) {
                    Button(write.confirmButtonTitle, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(write.isDestructive ? .red : AppTheme.accent)
                    Button("Cancel", action: onDecline)
                        .buttonStyle(.bordered)
                }
            }
        }
        .appCard()
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(isActive ? AppTheme.accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var detail: some View {
        switch write.action {
        case .add(let draft):
            draftSummary(draft)

        case .edit(_, let draft, let originalName):
            VStack(alignment: .leading, spacing: 6) {
                if originalName != draft.name {
                    Text("Was: \(originalName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                draftSummary(draft)
            }

        case .delete(_, let name, let calories):
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.weight(.medium))
                Text("\(AppFormatters.amount(calories)) kcal will be removed from your log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func draftSummary(_ draft: FoodEntryDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(draft.name).font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Text("\(AppFormatters.quantity(draft.quantity, unit: draft.unit)) \(draft.unit.shortLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            NutritionSummaryView(nutrition: draft.total, showsFibre: false)
            if !draft.ingredients.isEmpty {
                Text(draft.ingredients.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Figures are estimates. You can edit this entry afterwards.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
