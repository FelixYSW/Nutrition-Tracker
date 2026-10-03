import SwiftUI
import SwiftData
import PhotosUI

/// Assistant chat, one of the five destinations in the floating tab bar
/// (spec section 29A).
struct AssistantView: View {
    @Environment(\.modelContext) private var context

    @State private var viewModel: AssistantViewModel?
    @State private var photoSelection: PhotosPickerItem?
    @State private var viewingPhoto: ViewedPhoto?

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
            .keyboardDismissControls()
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $viewingPhoto) { photo in
                PhotoViewer(data: photo.data)
            }
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
                viewModel = AssistantViewModel.make(context: context)
            }
        }
    }

    @ViewBuilder
    private func content(viewModel: AssistantViewModel) -> some View {
        VStack(spacing: 0) {
            if viewModel.isAvailable {
                transcript(viewModel: viewModel)
                composer(viewModel: viewModel)
            } else {
                // Nothing for the user to set up: just say it isn't available.
                VStack {
                    Spacer()
                    EmptyStateView(
                        title: "Assistant not available",
                        message: "The assistant isn't available in this version of the "
                            + "app. Everything else works as normal.",
                        systemImage: "sparkles")
                    Spacer()
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
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
            Text(AssistantContextBuilder.dataSharingDisclosure)
                .font(.caption2)
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
        case .user(let text, let image):
            // Photo above the text bubble, both right-aligned, like Claude and
            // ChatGPT. Tapping the photo opens it full screen.
            VStack(alignment: .trailing, spacing: 6) {
                if let image {
                    Button {
                        viewingPhoto = ViewedPhoto(data: image)
                    } label: {
                        AttachmentImage(data: image)
                            .frame(maxWidth: 220, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attached photo. Opens full screen.")
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(AppTheme.accentFill, in: RoundedRectangle(
                            cornerRadius: 20, style: .continuous))
                        .foregroundStyle(AppTheme.onAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .trailing)

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

    /// One rounded box holding the attached photo's thumbnail and the text,
    /// with attach on the left and send on the right - the layout Claude and
    /// ChatGPT use.
    private func composer(viewModel: AssistantViewModel) -> some View {
        VStack(spacing: 8) {
            if viewModel.pendingWrite != nil {
                Text("Respond to the confirmation above to carry on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(AppTheme.subtleFill, in: Circle())
                }
                .padding(.bottom, 3)
                .accessibilityLabel("Attach a photo")

                VStack(alignment: .leading, spacing: 8) {
                    if let image = viewModel.attachedImageData {
                        ZStack(alignment: .topTrailing) {
                            AttachmentImage(data: image)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Button {
                                withAnimation(.snappy) { viewModel.attachedImageData = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(AppTheme.onAccent, AppTheme.accentFill)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 7, y: -7)
                            .accessibilityLabel("Remove photo")
                        }
                        .padding(.top, 4)
                        .transition(.scale.combined(with: .opacity))
                    }

                    TextField(viewModel.attachedImageData == nil
                                ? "Ask anything about your nutrition"
                                : "Ask about this photo",
                              text: Binding(get: { viewModel.composerText },
                                            set: { viewModel.composerText = $0 }),
                              axis: .vertical)
                        .lineLimit(1...5)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardBackground,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.subtleFill, lineWidth: 1))

                Button {
                    dismissKeyboard()
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                }
                .padding(.bottom, 2)
                .disabled(!viewModel.canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, AppTheme.cardPadding)
        .padding(.vertical, 10)
        .background(AppTheme.background)
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

// MARK: - Photo attachments

/// A photo from the chat, filling its frame.
struct AttachmentImage: View {
    let data: Data

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    private var placeholder: some View {
        Rectangle()
            .fill(AppTheme.subtleFill)
            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
    }
}

/// Identifiable wrapper so a sent photo can drive `fullScreenCover(item:)`.
struct ViewedPhoto: Identifiable {
    let id = UUID()
    let data: Data
}

/// Full-screen view of a sent photo, with pinch to zoom.
struct PhotoViewer: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            #if canImport(UIKit)
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * pinch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(
                        MagnifyGesture()
                            .updating($pinch) { value, state, _ in state = value.magnification }
                            .onEnded { value in
                                scale = min(max(scale * value.magnification, 1), 4)
                            })
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) { scale = scale > 1 ? 1 : 2 }
                    }
                    .accessibilityLabel("Attached photo")
            }
            #endif

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
    }
}
