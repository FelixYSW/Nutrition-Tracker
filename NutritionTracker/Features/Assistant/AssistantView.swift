import SwiftUI
import SwiftData
import PhotosUI

/// Assistant chat, one of the five destinations in the floating tab bar
/// (spec section 29A).
struct AssistantView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: AssistantViewModel?
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var viewingPhoto: ViewedPhoto?
    @State private var isShowingPhotoPicker = false
    @State private var isShowingCamera = false
    @State private var cameraProblem: String?
    @State private var isShowingHistory = false
    // Chat scrolling: whether the end of the chat is on screen, and whether
    // new content should keep it there (off once the user scrolls away).
    @State private var isAtBottom = true
    @State private var isFollowingBottom = true
    // Bumped to ask the scroll view to jump to the end.
    @State private var jumpRequest = 0

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
                PhotoViewer(images: photo.images, startIndex: photo.index)
            }
            .alert("Camera unavailable", isPresented: Binding(
                get: { cameraProblem != nil },
                set: { if !$0 { cameraProblem = nil } })) {
                Button("OK", role: .cancel) { cameraProblem = nil }
            } message: {
                Text(cameraProblem ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .accessibilityLabel("Past chats")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy) { viewModel?.startNewConversation() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .accessibilityLabel("New chat")
                    }
                    .disabled(viewModel?.messages.isEmpty ?? true)
                }
            }
            .sheet(isPresented: $isShowingHistory) {
                ChatHistoryView(currentID: viewModel?.conversationID) { conversation in
                    viewModel?.open(conversation)
                }
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = AssistantViewModel.make(context: context)
            }
        }
        // Leaving the app mid-chat still keeps it in history.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel?.persist() }
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

    @ViewBuilder
    private func transcript(viewModel: AssistantViewModel) -> some View {
        Group {
            if #available(iOS 18, *) {
                FollowingScrollView(isAtBottom: $isAtBottom,
                                    isFollowing: $isFollowingBottom,
                                    jumpRequest: jumpRequest) {
                    transcriptRows(viewModel: viewModel)
                }
            } else {
                legacyTranscript(viewModel: viewModel)
            }
        }
        // Sending always jumps to the bottom and starts following again.
        .onChange(of: viewModel.messages.count) { oldCount, newCount in
            if newCount > oldCount, case .user? = viewModel.messages.last?.kind {
                jumpToBottom()
            }
        }
        .onChange(of: viewModel.conversationID) { _, _ in jumpToBottom() }
        .overlay(alignment: .bottom) {
            if !isAtBottom && !viewModel.messages.isEmpty {
                Button {
                    jumpToBottom()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .appGlass(in: Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to the latest message")
                .padding(.bottom, 10)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isAtBottom)
    }

    /// The messages, then "Thinking…", then an end-of-chat marker.
    private func transcriptRows(viewModel: AssistantViewModel) -> some View {
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

            // Only used on iOS 17, which has no scroll geometry: its
            // visibility stands in for "at the bottom", and it's the jump target.
            Color.clear
                .frame(height: 1)
                .id(Self.bottomID)
                .onAppear { legacyAnchorVisible(true) }
                .onDisappear { legacyAnchorVisible(false) }
        }
        .padding(.horizontal, AppTheme.cardPadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Scrolls to the end and keeps following new content.
    private func jumpToBottom() {
        isFollowingBottom = true
        jumpRequest += 1
    }

    private static let bottomID = "transcript-bottom"

    // MARK: iOS 17 scrolling

    private func legacyTranscript(viewModel: AssistantViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptRows(viewModel: viewModel)
            }
            .modifier(UserScrollDetector(
                onScrollStart: { isFollowingBottom = false },
                onScrollEnd: { if isAtBottom { isFollowingBottom = true } }))
            .onChange(of: jumpRequest) { _, _ in legacyScroll(proxy, animated: true) }
            .onChange(of: viewModel.isSending) { _, _ in legacyFollow(proxy) }
            .onChange(of: viewModel.revealedLength) { _, _ in legacyFollow(proxy) }
            .onChange(of: viewModel.messages.count) { _, _ in legacyFollow(proxy) }
        }
    }

    private func legacyAnchorVisible(_ visible: Bool) {
        if #unavailable(iOS 18) {
            if visible != isAtBottom { isAtBottom = visible }
        }
    }

    /// Follows growing content - but only once it has pushed the end off
    /// screen, so a short chat never jumps.
    private func legacyFollow(_ proxy: ScrollViewProxy) {
        guard isFollowingBottom, !isAtBottom else { return }
        legacyScroll(proxy, animated: false)
    }

    private func legacyScroll(_ proxy: ScrollViewProxy, animated: Bool) {
        // Wait a beat so the new row has been laid out before scrolling to it.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
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
        case .user(let text, let images):
            // Photos above the text bubble, both right-aligned, like Claude and
            // ChatGPT. Tapping a photo opens it full screen.
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    SentPhotos(images: images) { index in
                        viewingPhoto = ViewedPhoto(images: images, index: index)
                    }
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
            MarkdownText(viewModel.displayedText(text, for: message.id))
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
                isActive: viewModel.pendingWrites.contains { $0.id == write.id },
                isReplaced: viewModel.replacedWriteIDs.contains(write.id),
                onConfirm: { Task { await viewModel.confirm(write) } },
                onDecline: { Task { await viewModel.decline(write) } })

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

    /// One rounded box holding the attached photos and the text, with attach
    /// on the left and send on the right - the layout Claude and ChatGPT use.
    private func composer(viewModel: AssistantViewModel) -> some View {
        VStack(spacing: 8) {
            if !viewModel.pendingWrites.isEmpty {
                HStack(spacing: 8) {
                    Text(viewModel.pendingWrites.count > 1
                         ? "Confirm the cards above, or tell the assistant what to change."
                         : "Confirm the card above, or tell the assistant what to change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // One tap for a meal split into several dishes.
                    let together = viewModel.confirmableTogether.count
                    if together > 1 {
                        Button("Add all \(together)") {
                            Task { await viewModel.confirmAllAdditions() }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Attach: take a photo with the camera, or pick several.
                Menu {
                    Button("Take Photo", systemImage: "camera") { openCamera() }
                    Button("Choose Photos", systemImage: "photo.on.rectangle") {
                        isShowingPhotoPicker = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(AppTheme.subtleFill, in: Circle())
                }
                .disabled(!viewModel.canAttachMore)
                .padding(.bottom, 3)
                .accessibilityLabel("Attach photos")
                .accessibilityHint(viewModel.canAttachMore
                                   ? "Take a photo or choose from your library"
                                   : "Up to \(AssistantViewModel.maxAttachments) photos")

                VStack(alignment: .leading, spacing: 8) {
                    if !viewModel.attachments.isEmpty {
                        attachmentStrip(viewModel: viewModel)
                    }

                    TextField(placeholder(for: viewModel),
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
                .accessibilityLabel(viewModel.isLoadingAttachment ? "Send, waiting for photos" : "Send")
            }
        }
        .padding(.horizontal, AppTheme.cardPadding)
        .padding(.vertical, 10)
        .background(AppTheme.background)
        .photosPicker(isPresented: $isShowingPhotoPicker,
                      selection: $photoSelections,
                      maxSelectionCount: max(1, viewModel.remainingAttachmentSlots),
                      matching: .images)
        .onChange(of: photoSelections) { _, items in
            guard !items.isEmpty else { return }
            for item in items { attach(item, to: viewModel) }
            photoSelections = []
        }
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker(onImage: { image in
                isShowingCamera = false
                attach(image, to: viewModel)
            }, onCancel: {
                isShowingCamera = false
            })
            .ignoresSafeArea()
        }
        #endif
    }

    /// Thumbnails above the text, each with an x. One still loading shows a
    /// spinner in its place, as Claude does while an image uploads.
    private func attachmentStrip(viewModel: AssistantViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let data = attachment.data {
                                AttachmentImage(data: data)
                            } else {
                                ZStack {
                                    AppTheme.subtleFill
                                    ProgressView()
                                }
                                .accessibilityLabel("Loading photo")
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            withAnimation(.snappy) { viewModel.removeAttachment(id: attachment.id) }
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
                    .transition(.scale.combined(with: .opacity))
                }
            }
            // Room for the x buttons, which sit just outside each thumbnail.
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .animation(.snappy, value: viewModel.attachments)
    }

    private func placeholder(for viewModel: AssistantViewModel) -> String {
        switch viewModel.attachments.count {
        case 0: "Ask anything about your nutrition"
        case 1: "Ask about this photo"
        default: "Ask about these photos"
        }
    }

    // MARK: Attaching

    #if canImport(UIKit)
    /// Opens the camera, or explains why it can't (spec section 34).
    private func openCamera() {
        if let explanation = CameraPermission.current().explanation {
            cameraProblem = explanation
        } else {
            isShowingCamera = true
        }
    }

    private func attach(_ image: UIImage, to viewModel: AssistantViewModel) {
        guard let id = viewModel.beginAttachment() else { return }
        Task {
            let data = await Self.downsized(image)
            viewModel.finishAttachment(id: id, data: data)
        }
    }

    /// Resized off the main thread so the composer stays responsive; a 12MP
    /// photo is never sent whole.
    private static func downsized(_ image: UIImage) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            (try? ImagePreparer.prepare(image: image))?.jpegData
        }.value
    }
    #else
    private func openCamera() {}
    #endif

    private func attach(_ item: PhotosPickerItem, to viewModel: AssistantViewModel) {
        guard let id = viewModel.beginAttachment() else { return }
        Task {
            var result: Data?
            if let data = try? await item.loadTransferable(type: Data.self) {
                #if canImport(UIKit)
                if let image = UIImage(data: data) {
                    result = await Self.downsized(image)
                }
                #else
                result = data
                #endif
            }
            viewModel.finishAttachment(id: id, data: result)
        }
    }
}

/// The confirmation card. No assistant write reaches the database without the
/// user tapping through this (spec section 29A).
struct AssistantConfirmationCard: View {
    let write: PendingAssistantWrite
    let isActive: Bool
    /// Closed because the user asked for changes and a new card replaced it.
    var isReplaced: Bool = false
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
            } else if isReplaced {
                Label("Replaced by the updated card below", systemImage: "arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .appCard()
        // A replaced card fades back so the current one stands out.
        .opacity(isReplaced ? 0.55 : 1)
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
            // Logged for another time, e.g. a shake "before midnight" after
            // midnight: shown so a wrong day is caught before saving.
            if abs(draft.consumedAt.timeIntervalSinceNow) > 30 * 60 {
                Label("For \(ChatHistoryView.lastMessageLabel(draft.consumedAt).lowercasedFirstWord)",
                      systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
            }
            NutritionSummaryView(nutrition: draft.total, showsFibre: false)
            if !draft.ingredients.isEmpty {
                // The breakdown the total is built from, so a wrong amount is
                // easy to spot before saving.
                // Columns, so grams, kcal and the source tag line up row to row.
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(draft.ingredients) { item in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(item.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(AppFormatters.amount(item.quantity)) g")
                                .gridColumnAlignment(.trailing)
                            Text("\(AppFormatters.amount(item.total.calories)) kcal")
                                .gridColumnAlignment(.trailing)
                            Group {
                                if item.provenance.isEstimate {
                                    Text("est.")
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("estimate")
                                } else if item.provenance.isDeclared {
                                    Text("label")
                                        .foregroundStyle(AppTheme.within)
                                        .accessibilityLabel(item.provenance.displayName)
                                } else {
                                    Text("")
                                }
                            }
                            .gridColumnAlignment(.leading)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }
            Text(!draft.ingredients.isEmpty && draft.ingredients.allSatisfy(\.provenance.isDeclared)
                 ? "Figures from the label. You can edit this entry afterwards."
                 : "Figures are estimates. You can edit this entry afterwards.")
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

/// Photos in a sent message: one shown large, several as a two-column grid of
/// squares, right-aligned like the rest of the user's message.
struct SentPhotos: View {
    let images: [Data]
    let onOpen: (Int) -> Void

    var body: some View {
        if images.count == 1, let only = images.first {
            Button { onOpen(0) } label: {
                AttachmentImage(data: only)
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attached photo. Opens full screen.")
        } else {
            let columns = [GridItem(.fixed(108), spacing: 6), GridItem(.fixed(108), spacing: 6)]
            LazyVGrid(columns: columns, alignment: .trailing, spacing: 6) {
                ForEach(images.indices, id: \.self) { index in
                    Button { onOpen(index) } label: {
                        AttachmentImage(data: images[index])
                            .frame(width: 108, height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Photo \(index + 1) of \(images.count). Opens full screen.")
                }
            }
            .fixedSize()
        }
    }
}

/// Identifiable wrapper so sent photos can drive `fullScreenCover(item:)`.
struct ViewedPhoto: Identifiable {
    let id = UUID()
    let images: [Data]
    let index: Int
}

/// Full-screen view of a message's photos: swipe between them, pinch or
/// double-tap to zoom.
struct PhotoViewer: View {
    let images: [Data]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(images.indices, id: \.self) { index in
                    ZoomablePhoto(data: images[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

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
        .onAppear { selection = min(max(startIndex, 0), max(images.count - 1, 0)) }
    }
}

/// One photo that can be pinched or double-tapped to zoom.
struct ZoomablePhoto: View {
    let data: Data
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
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
    }
}

// MARK: - Chat scrolling

/// Where the chat sits relative to its end, from the scroll view's geometry.
enum BottomEdgeTracker {
    /// How close counts as "at the bottom", in points.
    static let tolerance: CGFloat = 40

    /// The visible area reaches the end of the content, allowing for the
    /// bottom inset (the tab bar) and a little slack. Short chats that don't
    /// fill the screen count as at the bottom.
    static func isAtBottom(visibleMaxY: CGFloat, contentHeight: CGFloat,
                           bottomInset: CGFloat) -> Bool {
        visibleMaxY - bottomInset >= contentHeight - tolerance
    }

    /// Whether the chat is taller than the space it has, i.e. there is
    /// anything to scroll at all.
    static func overflows(contentHeight: CGFloat, containerHeight: CGFloat,
                          topInset: CGFloat, bottomInset: CGFloat) -> Bool {
        contentHeight + topInset + bottomInset > containerHeight + 1
    }
}

/// The chat's scroll view on iOS 18+.
///
/// Scrolls with `ScrollPosition.scrollTo(edge: .bottom)`, which goes to the
/// true end of the content however the lazy rows were estimated, rather than
/// to a marker row that may not have been laid out yet. New content is
/// followed by watching the content height, and only while the chat is
/// taller than the screen - so a short chat never jumps as a reply appears.
@available(iOS 18, *)
private struct FollowingScrollView<Content: View>: View {
    @Binding var isAtBottom: Bool
    @Binding var isFollowing: Bool
    /// Changes whenever the chat should jump to its end (send, button, new chat).
    let jumpRequest: Int
    @ViewBuilder let content: Content

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var overflows = false

    private struct Metrics: Equatable {
        var atBottom: Bool
        var overflows: Bool
        var contentHeight: CGFloat
    }

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Metrics.self) { geometry in
            Metrics(atBottom: BottomEdgeTracker.isAtBottom(
                        visibleMaxY: geometry.visibleRect.maxY,
                        contentHeight: geometry.contentSize.height,
                        bottomInset: geometry.contentInsets.bottom),
                    overflows: BottomEdgeTracker.overflows(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        topInset: geometry.contentInsets.top,
                        bottomInset: geometry.contentInsets.bottom),
                    contentHeight: geometry.contentSize.height)
        } action: { old, new in
            overflows = new.overflows
            if new.atBottom != isAtBottom { isAtBottom = new.atBottom }
            // The reply grew (or a row was added) while following: keep the
            // end in view.
            if new.contentHeight > old.contentHeight, isFollowing, new.overflows {
                position.scrollTo(edge: .bottom)
            }
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .interacting: isFollowing = false
            case .idle: if isAtBottom { isFollowing = true }
            default: break
            }
        }
        .onChange(of: jumpRequest) { _, _ in
            guard overflows else { return }
            withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
        }
    }
}

/// Reports when the user starts and stops scrolling the chat themselves, as
/// opposed to the app scrolling it to follow a reply.
private struct UserScrollDetector: ViewModifier {
    let onScrollStart: () -> Void
    let onScrollEnd: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting: onScrollStart()
                case .idle: onScrollEnd()
                default: break
                }
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { _ in onScrollStart() }
                .onEnded { _ in onScrollEnd() })
        }
    }
}

private extension String {
    /// "Yesterday, 11:45 PM" -> "yesterday, 11:45 PM", to read as "For yesterday, …".
    /// Dates such as "13 Oct, …" are left as they are.
    var lowercasedFirstWord: String {
        guard hasPrefix("Today") || hasPrefix("Yesterday") else { return self }
        return prefix(1).lowercased() + dropFirst()
    }
}
