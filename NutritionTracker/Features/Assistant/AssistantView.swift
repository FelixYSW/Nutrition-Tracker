import SwiftUI
import SwiftData
import PhotosUI

/// Assistant chat, one of the five destinations in the floating tab bar
/// (spec section 29A).
struct AssistantView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var allEntries: [FoodEntry]
    @Query(sort: \NutritionTarget.updatedAt, order: .reverse) private var targets: [NutritionTarget]
    /// The message box, so a suggestion like "Log my lunch" can open the
    /// keyboard with the sentence started.
    @FocusState private var isComposerFocused: Bool

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
            // The title and buttons are drawn in the page, like every tab.
            .toolbar(.hidden, for: .navigationBar)
            .keyboardDismissControls()
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
    /// Title and chat buttons, pinned above the conversation.
    private func header(viewModel: AssistantViewModel) -> some View {
        PageHeader(title: "Assistant") {
            HStack(spacing: 10) {
                GlassIconButton(systemImage: "clock.arrow.circlepath", label: "Past chats") {
                    isShowingHistory = true
                }
                GlassIconButton(systemImage: "square.and.pencil", label: "New chat") {
                    withAnimation(.snappy) { viewModel.startNewConversation() }
                }
                .disabled(viewModel.messages.isEmpty)
                .opacity(viewModel.messages.isEmpty ? 0.35 : 1)
            }
        }
        .padding(.horizontal, AppTheme.cardPadding + 4)
        .padding(.top, AppTheme.pageSpacing)
        .padding(.bottom, 8)
    }

    private func content(viewModel: AssistantViewModel) -> some View {
        VStack(spacing: 0) {
            header(viewModel: viewModel)
            if viewModel.isAvailable {
                if viewModel.messages.isEmpty && !viewModel.isSending {
                    emptyChat(viewModel: viewModel)
                } else {
                    transcript(viewModel: viewModel)
                }
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
        // A fresh scroll view per chat, laid out from the bottom up. Jumping
        // an existing one to the end of a newly opened chat went by estimated
        // row heights and overshot, leaving a gap until the next scroll.
        .id(viewModel.conversationID)
        // Sending always jumps to the bottom and starts following again.
        .onChange(of: viewModel.messages.count) { oldCount, newCount in
            if newCount > oldCount, case .user? = viewModel.messages.last?.kind {
                jumpToBottom()
            }
        }
        .onChange(of: viewModel.conversationID) { _, _ in
            isFollowingBottom = true
            isAtBottom = true
        }
        .overlay(alignment: .bottom) {
            if !isAtBottom && !viewModel.messages.isEmpty {
                Button {
                    // Used mid-typing too: jumping down mustn't close the keyboard.
                    KeyboardDismissal.keepOpen()
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
            .defaultScrollAnchor(.bottom)   // a newly opened chat starts at its end
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

    /// A new chat: greeting, where today stands, and suggestions for now.
    private func emptyChat(viewModel: AssistantViewModel) -> some View {
        let today = LocalDay.entries(allEntries, on: .now)
        return EmptyChatView(
            caloriesSoFar: LocalDay.total(today).calories,
            calorieRange: targets.first?.ranges.calories,
            hasLoggedToday: !today.isEmpty,
            onAsk: { question in
                viewModel.composerText = question
                Task { await viewModel.send() }
            },
            onDraft: { start in
                viewModel.composerText = start
                isComposerFocused = true
            },
            onMenuPhoto: { fromCamera in
                viewModel.composerText = "What should I order from this menu to fit my ranges?"
                if fromCamera { openCamera() } else { isShowingPhotoPicker = true }
            })
    }

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
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(AppTheme.accentFill, in: UnevenRoundedRectangle(
                            topLeadingRadius: 22, bottomLeadingRadius: 22,
                            bottomTrailingRadius: 6, topTrailingRadius: 22,
                            style: .continuous))
                        .foregroundStyle(AppTheme.onAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant(let text):
            MarkdownText(viewModel.displayedText(text, for: message.id))
                .font(.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardBackground, in: UnevenRoundedRectangle(
                    topLeadingRadius: 22, bottomLeadingRadius: 6,
                    bottomTrailingRadius: 22, topTrailingRadius: 22,
                    style: .continuous))
                .overlay(UnevenRoundedRectangle(
                    topLeadingRadius: 22, bottomLeadingRadius: 6,
                    bottomTrailingRadius: 22, topTrailingRadius: 22,
                    style: .continuous)
                    .stroke(AppTheme.cardBorder, lineWidth: 1))
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
                    .foregroundStyle(AppTheme.over)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.over.opacity(0.12),
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
                        .focused($isComposerFocused)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardBackground,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.subtleFill, lineWidth: 1))

                // Only there when there's something to send and the assistant
                // is free; otherwise the text box takes the whole width.
                if viewModel.canSend {
                    Button {
                        dismissKeyboard()
                        Task { await viewModel.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                    }
                    .padding(.bottom, 2)
                    .accessibilityLabel("Send")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: viewModel.canSend)
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
    /// Opens the photos waiting to be sent in the viewer, at the one tapped.
    /// Photos still loading are skipped.
    private func preview(_ attachment: ComposerAttachment, in viewModel: AssistantViewModel) {
        let loaded = viewModel.attachments.filter { $0.data != nil }
        guard let index = loaded.firstIndex(where: { $0.id == attachment.id }) else { return }
        KeyboardDismissal.keepOpen()
        viewingPhoto = ViewedPhoto(images: loaded.compactMap(\.data), index: index)
    }

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
                        // Tap to look at it full size before sending.
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture { preview(attachment, in: viewModel) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows the photo full size")

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
            ImagePreparer.assistantJPEG(from: image)
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
            HStack(spacing: 8) {
                Image(systemName: write.isDestructive ? "trash" : "plus.circle")
                    .foregroundStyle(write.isDestructive ? AppTheme.destructiveText : .secondary)
                    .accessibilityHidden(true)
                Text(write.confirmationTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            detail

            if isActive {
                VStack(spacing: 4) {
                    Button(write.confirmButtonTitle, action: onConfirm)
                        .buttonStyle(PrimaryButtonStyle(
                            fill: write.isDestructive ? AppTheme.destructiveText : AppTheme.accentFill))
                    Button(action: onDecline) {
                        Text("Cancel")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: AppTheme.minimumTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
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
        VStack(alignment: .leading, spacing: 8) {
            // Name and amount on the left, calories on the right.
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name)
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(AppFormatters.quantity(draft.quantity, unit: draft.unit)) \(draft.unit.shortLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(AppFormatters.amount(draft.total.calories))
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                    Text("kcal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            // Logged for another time, e.g. a shake "before midnight" after
            // midnight: shown so a wrong day is caught before saving.
            if abs(draft.consumedAt.timeIntervalSinceNow) > 30 * 60 {
                Label("For \(ChatHistoryView.lastMessageLabel(draft.consumedAt).lowercasedFirstWord)",
                      systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
            }
            // Calories are in the row above; the tiles add the macros.
            NutritionSummaryView(nutrition: draft.total, showsCalories: false)
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
                                // Small tinted pills, as in the mockup.
                                if item.provenance.isEstimate {
                                    sourcePill("est.", tint: AppTheme.color(for: .carbs),
                                               text: AppTheme.textColor(for: .carbs))
                                        .accessibilityLabel("estimate")
                                } else if item.provenance.isDeclared {
                                    sourcePill("label", tint: AppTheme.within,
                                               text: AppTheme.stateTextColor(for: .within))
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

    private func sourcePill(_ title: String, tint: Color, text: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(text)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
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

/// Full-screen view of photos: swipe between them, pinch or double-tap to
/// zoom. The chat stays faintly visible behind a dark, see-through shade.
/// Tap the shade around the photo, or drag the photo down, to close.
struct PhotoViewer: View {
    let images: [Data]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    /// How far the photo has been dragged down; fades the shade as it goes.
    @State private var dragOffset: CGFloat = 0

    /// Shade opacity: mostly dark, lighter as the photo is pulled away.
    private var shadeOpacity: Double {
        0.82 * max(0.25, 1 - Double(dragOffset) / 600)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Near-black (never pure #000), partly see-through.
            Color(hex: 0x141311)
                .opacity(shadeOpacity)
                .ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(images.indices, id: \.self) { index in
                    ZoomablePhoto(data: images[index],
                                  dragOffset: $dragOffset,
                                  onClose: { dismiss() })
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
                    .foregroundStyle(Color(hex: 0xF6F4EF))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .opacity(dragOffset > 0 ? 0 : 1)
            .accessibilityLabel("Close")
        }
        // Our own shade replaces the cover's opaque background.
        .presentationBackground(.clear)
        .onAppear { selection = min(max(startIndex, 0), max(images.count - 1, 0)) }
    }
}

/// One photo in the viewer. Zooming and panning use the system's own zooming
/// scroll view, as in Photos: pinch zooms where the fingers are, a zoomed
/// photo can be dragged around, and double-tap zooms in on the spot tapped.
/// Not zoomed, a tap on the space around the photo or a drag down closes it.
struct ZoomablePhoto: View {
    let data: Data
    @Binding var dragOffset: CGFloat
    let onClose: () -> Void

    /// Pulled further than this, or flicked down, and the photo closes.
    private let closeDistance: CGFloat = 120

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            ZoomableImageView(
                image: image,
                onTapOutside: onClose,
                onDismissDrag: { distance in dragOffset = max(0, distance) },
                onDismissDragEnd: { distance, velocity in
                    if distance > closeDistance || velocity > 900 {
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                })
                .offset(y: dragOffset)
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel("Photo")
                .accessibilityAddTraits(.isImage)
                .accessibilityAction(named: "Close", onClose)
        }
        #endif
    }
}

#if canImport(UIKit)
/// A zooming `UIScrollView` around the image, with taps and the drag-down
/// gesture added.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onTapOutside: () -> Void
    /// How far the photo has been pulled down so far.
    let onDismissDrag: (CGFloat) -> Void
    /// The final distance and downward speed when the finger lifts.
    let onDismissDragEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(image: image)
        let coordinator = context.coordinator
        view.delegate = coordinator
        coordinator.scrollView = view

        let doubleTap = UITapGestureRecognizer(target: coordinator,
                                               action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: coordinator,
                                               action: #selector(Coordinator.singleTapped(_:)))
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        let pullDown = UIPanGestureRecognizer(target: coordinator,
                                              action: #selector(Coordinator.pulled(_:)))
        pullDown.delegate = coordinator
        view.addGestureRecognizer(pullDown)
        coordinator.pullDown = pullDown
        return view
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImageView
        weak var scrollView: ZoomScrollView?
        weak var pullDown: UIPanGestureRecognizer?

        init(_ parent: ZoomableImageView) { self.parent = parent }

        private var isZoomed: Bool {
            guard let scrollView else { return false }
            return scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centerImage()
        }

        /// Zooms in on the spot tapped, or back out.
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if isZoomed {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: scrollView.imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scrollView.bounds.width / scale,
                                  height: scrollView.bounds.height / scale)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2,
                                           y: point.y - size.height / 2,
                                           width: size.width, height: size.height),
                                animated: true)
            }
        }

        /// A tap on the space around the photo closes the viewer.
        @objc func singleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let point = gesture.location(in: scrollView.imageView)
            if !scrollView.imageView.bounds.contains(point) {
                parent.onTapOutside()
            }
        }

        @objc func pulled(_ gesture: UIPanGestureRecognizer) {
            let distance = gesture.translation(in: gesture.view).y
            switch gesture.state {
            case .changed:
                parent.onDismissDrag(distance)
            case .ended, .cancelled:
                parent.onDismissDragEnd(distance, gesture.velocity(in: gesture.view).y)
            default:
                break
            }
        }

        /// The pull-down only starts on a downward, mostly vertical drag of a
        /// photo that isn't zoomed; anything else is left to panning the
        /// zoomed photo or swiping to the next one.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard gesture === pullDown, let pan = gesture as? UIPanGestureRecognizer else {
                return true
            }
            guard !isZoomed else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
        }
    }
}

/// Scroll view that fits the image to the screen at 1x and keeps it centred
/// at every zoom level.
final class ZoomScrollView: UIScrollView {
    let imageView: UIImageView
    private var fittedSize: CGSize = .zero

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Fit the image to the screen once per size (first layout, rotation).
        guard bounds.width > 0, bounds.height > 0, bounds.size != fittedSize else { return }
        fittedSize = bounds.size
        zoomScale = minimumZoomScale
        let imageSize = imageView.image?.size ?? bounds.size
        let fit = min(bounds.width / max(imageSize.width, 1),
                      bounds.height / max(imageSize.height, 1))
        imageView.frame = CGRect(x: 0, y: 0,
                                 width: imageSize.width * fit, height: imageSize.height * fit)
        contentSize = imageView.frame.size
        centerImage()
    }

    /// Pads around an image smaller than the screen, so it sits in the middle.
    func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal,
                                    bottom: vertical, right: horizontal)
    }
}
#endif

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
    /// True while the animated jump to the end runs. Rows measured on the way
    /// change the content height, and snapping to the end for each of those
    /// cut into the animation and made it stutter.
    @State private var isJumping = false

    private struct Metrics: Equatable {
        var atBottom: Bool
        var overflows: Bool
        var contentHeight: CGFloat
    }

    var body: some View {
        ScrollView {
            content
        }
        // Lay the chat out from its last message, so opening a long chat
        // measures the rows on screen rather than guessing at all of them.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
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
            // The content changed height while following - a reply grew, a
            // row was added, or estimated rows were measured and came out
            // shorter: keep exactly at the end, with no gap below it.
            if new.contentHeight != old.contentHeight, isFollowing, new.overflows, !isJumping {
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
            isJumping = true
            withAnimation(.smooth(duration: 0.45)) {
                position.scrollTo(edge: .bottom)
            } completion: {
                isJumping = false
                // Rows measured during the glide may have moved the end a
                // little; settle on it exactly, without a second animation.
                position.scrollTo(edge: .bottom)
            }
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
