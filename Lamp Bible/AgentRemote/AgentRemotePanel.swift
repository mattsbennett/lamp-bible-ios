import LampCore
import SwiftUI

/// A writing the assistant is asked about from the phone: its chat on the
/// Mac, begun or continued, with the words chosen in it.
struct AgentRemoteWriting: Equatable, Identifiable {
    let id: String
    /// The collection it's kept in, which is what sync publishes.
    let moduleID: String
    let title: String
    var selection: String?
    /// Sent to the Mac by a sync pass before asking.
    var syncFirst = false
}

extension AgentRemoteWriting {
    /// Whether this device holds the writing otherwise than the server it
    /// syncs with does, as the Mac would take it from there: what a sync
    /// pass is waited on for before asking. A server no pass has finished
    /// at yet has nothing recorded, so it's waited on too.
    @MainActor
    func isWaitingToGoUp() async -> Bool {
        let id = id, module = moduleID
        guard let endpoint = libraryEndpoint(for: ModuleSyncManager.shared.getStorage()) else { return false }
        let source = endpoint.librarySource
        return await Task.detached(priority: .userInitiated) {
            LibrarySyncPass.hasUnsentWriting(id, inModule: module, source: source)
        }.value
    }
}

/// The writing's chat with the assistant, over the writing it's about.
struct AskAssistantSheet: View {
    let writing: AgentRemoteWriting
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = AgentRemoteClient.shared
    /// The latest edits are on their way to the Mac.
    @State private var sendingEdits = false

    var body: some View {
        NavigationStack {
            AgentRemotePanel(
                reading: LampAgentRemoteReading(),
                referenceLabel: writing.title,
                toolText: .current,
                writing: writing,
                sendingHeld: sendingEdits ? "Sending your latest edits to your Mac…" : nil
            )
            .task {
                guard writing.syncFirst else { return }
                await sendEdits()
            }
            // One glass bar, the chat scrolling under it, as the reader's
            // header is: the writing and who's answering, in the title.
            .titled(writing.title, subtitle: answeringName ?? "Ask the Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The assistant answering in the writing's chat, once it's open.
    private var answeringName: String? {
        guard let chat = client.chat,
              chat.summary.writingID?.caseInsensitiveCompare(writing.id) == .orderedSame else { return nil }
        return chat.summary.providerName
    }

    /// Sync passes until what was saved is published, so it's on its way
    /// before the Mac is asked. Best effort: the Mac checks the writing's
    /// revision itself, pulls if it's behind, and says so if it still is.
    private func sendEdits() async {
        guard SyncCoordinator.shared.settings.backend != .none else { return }
        sendingEdits = true
        defer { sendingEdits = false }
        // What's waited on is the writing going up, not a pass ending well:
        // one already running may have begun before the save, and one can
        // fail elsewhere in the library with this sent.
        var passes = 0
        for _ in 0..<60 where passes < 3 && !Task.isCancelled {
            guard await writing.isWaitingToGoUp() else { return }
            do {
                try await SyncCoordinator.shared.syncAll()
                passes += 1
            } catch SyncError.alreadyRunning, SyncError.backendTransitionInProgress {
                // The one running is followed by another, which has it.
            } catch SyncError.notConfigured {
                return
            } catch {
                passes += 1
            }
            guard await writing.isWaitingToGoUp() else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

}

/// A reader chat opened from its notification, over whatever screen Lamp is
/// on: the Chat panel, in a sheet, sending without a passage, as the
/// writing's assistant does.
struct ReaderChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = AgentRemoteClient.shared

    var body: some View {
        NavigationStack {
            AgentRemotePanel(reading: LampAgentRemoteReading(), referenceLabel: "Reader Chat", toolText: .current)
                .titled("Reader Chat", subtitle: client.chat?.summary.providerName ?? "Your Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The reader's Chat panel: the Mac's reader chats, followed and continued
/// from here, each message sent with where this device is reading. Given a
/// writing, it's that writing's chat with the assistant instead.
struct AgentRemotePanel: View {
    /// Where the reader is, sent with each message as ids.
    let reading: LampAgentRemoteReading
    /// The same place as a person reads it, for the composer's prompt.
    let referenceLabel: String
    /// The panel's text as set, for the conversation.
    let toolText: LampToolText
    /// What covers the panel's top: the reader's header, in the side-by-side
    /// split, where the panel runs up under it.
    var topObstruction: CGFloat = 0
    /// What covers the panel's bottom: the reader's bottom bar, and the home
    /// indicator.
    var bottomObstruction: CGFloat = 0
    /// Beside the reader, where nothing lifts the panel for the keyboard:
    /// the composer makes room for it itself.
    var besideReader = false
    /// The writing this panel asks about, when it's the writing's own chat.
    var writing: AgentRemoteWriting?
    /// Why nothing can be sent yet, said above the composer.
    var sendingHeld: String?
    /// Tries again what holds sending, when it failed.
    var onRetryHeld: (() -> Void)?

    @ObservedObject private var client = AgentRemoteClient.shared
    /// The writing's chat has been found and opened once: after that, list
    /// changes don't open it again over a chat opened elsewhere.
    @State private var openedWritingChat = false
    @State private var code = ""
    @State private var showingScanner = false
    @State private var scannerError: String?
    @FocusState private var composerFocused: Bool
    @FocusState private var codeFocused: Bool
    /// A writing's message between Send and its stamp being read: it's
    /// already this chat's, on the provider it has, so who answers is held.
    @State private var stampingSend = false
    /// The panel's height, which the opened setup takes at most a part of.
    @State private var panelHeight: CGFloat = 0
    /// How far up the screen the onscreen keyboard reaches, nothing with a
    /// hardware keyboard: focus alone leaves the reader's bottom bar where it
    /// was, and the composer clear of it.
    @State private var keyboardHeight: CGFloat = 0
    private var keyboardUp: Bool { keyboardHeight > 100 }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            .onAppear {
                if writing != nil { selection = writing?.selection }
                // Another chat left open isn't this writing's: its draft and
                // composer would be that chat's.
                if writing != nil, client.openChatID != nil, !showsWritingChat { client.closeChat() }
                client.panelAppeared()
                openWritingChat()
            }
            // The writing's chat, once the Mac's list says it has one, or
            // once connected with a list kept from before.
            .onChange(of: client.chats) { openWritingChat() }
            .onChange(of: client.phase) { _, phase in
                // Connected again, perhaps to another Mac: its copy of the
                // writing's chat is looked for afresh.
                if case .connected = phase {} else { openedWritingChat = false }
                openWritingChat()
            }
            .onDisappear {
                if writing == nil, composerFocused || codeFocused { NoteEditorFocus.shared.isEditing = false }
                client.panelDisappeared()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screen = UIScreen.main.bounds
                keyboardHeight = frame.minY >= screen.maxY ? 0 : max(0, screen.maxY - frame.minY)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            // Typing here, the panel takes the space above the keyboard, as a
            // note being typed does: the reader lays the split out around it.
            .onChange(of: composerFocused || codeFocused) { _, focused in
                // In the reader only: a sheet makes room for the keyboard itself.
                if writing == nil { NoteEditorFocus.shared.isEditing = focused }
            }
            .sheet(isPresented: $showingScanner) { scannerSheet }
    }

    @ViewBuilder
    private var content: some View {
        switch client.phase {
        case .stopped, .searching:
            searching
        case let .connecting(name):
            waiting("Connecting to \(name)…")
        case let .needsCode(host, notice):
            pairing(host: host, notice: notice)
        case .connected:
            if writing != nil {
                if showsWritingChat { chatView } else { writingStart }
            } else if client.openChatID != nil {
                chatView
            } else {
                chatList
            }
        case let .unavailable(message):
            unavailable(message)
        }
    }

    // MARK: - Finding and pairing

    private var searching: some View {
        ScrollView {
            VStack(spacing: 16) {
                if client.hosts.isEmpty || !client.choosingHost && client.hosts.count == 1 {
                    ProgressView()
                        .padding(.top, 16)
                    Text("Looking for your Mac…")
                        .font(.headline)
                    explanation(
                        "Chats run in Lamp Bible on your Mac. Open it there, turn on Chats on iPhone and iPad in Settings › AI & Agents, and keep both on the same network."
                    )
                } else {
                    Text("Choose a Mac")
                        .font(.headline)
                        .padding(.top, 16)
                    VStack(spacing: 0) {
                        ForEach(client.hosts) { host in
                            Button {
                                client.connect(to: host)
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                        .foregroundStyle(LampTheme.caption)
                                    Text(host.name)
                                        .foregroundStyle(Color(uiColor: .label))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(LampTheme.caption)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if host != client.hosts.last {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }
                    .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomObstruction + 16)
            .frame(maxWidth: .infinity)
        }
    }

    private func pairing(host: String, notice: String?) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Pair with \(host)")
                    .font(.headline)
                    .padding(.top, 16)
                if PresentationPairingScanner.isAvailable {
                    Button("Scan Pairing Code", systemImage: "qrcode.viewfinder") {
                        scannerError = nil
                        showingScanner = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let notice = notice ?? scannerError {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                explanation(
                    "The code is in Lamp Bible on your Mac: Settings › AI & Agents › Chats on iPhone and iPad › Pair a Device. This device is remembered after that."
                )
                HStack(spacing: 8) {
                    TextField("Or type the code", text: $code)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($codeFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(LampTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onSubmit { pairWithTypedCode() }
                    Button("Pair") { pairWithTypedCode() }
                        .disabled(LampPresentationRemotePairing.normalizedCode(code) == nil)
                }
                .frame(maxWidth: 360)
                // Always offered: the Mac connected to on its own may not be
                // the one meant, and another may have appeared since.
                Button("Choose Another Mac") { client.chooseAnotherHost() }
                    .font(.footnote)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomObstruction + 16)
            .frame(maxWidth: .infinity)
        }
    }

    private func pairWithTypedCode() {
        guard LampPresentationRemotePairing.normalizedCode(code) != nil else { return }
        client.pair(code: code)
        code = ""
    }

    private var scannerSheet: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                PresentationPairingScanner(
                    parse: LampAgentRemoteHandshake.code(fromQRPayload:),
                    onCode: { scanned in
                        showingScanner = false
                        client.pair(code: scanned)
                    },
                    onFailure: { message in
                        scannerError = message
                        showingScanner = false
                    }
                )
                .ignoresSafeArea()
                Text("Point the camera at the code from Pair a Device… in Lamp Bible’s settings on your Mac.")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingScanner = false }
                }
            }
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(LampTheme.caption)
                    .padding(.top, 24)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { client.retry() }
                    .buttonStyle(.borderedProminent)
                Button("Choose Another Mac") { client.chooseAnotherHost() }
                    .font(.footnote)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomObstruction + 16)
            .frame(maxWidth: .infinity)
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420)
    }

    // MARK: - Chats

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(hostName.map { "Chats on \($0)" } ?? "Chats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

                if let problem = client.listProblem {
                    problemText(problem)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                if client.chats.isEmpty {
                    Text("No reader chats on your Mac yet. Ask something below to start one about \(referenceLabel).")
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }

                if let unsent = client.unsent[AgentRemoteClient.newChatKey] {
                    unsentView(unsent, key: AgentRemoteClient.newChatKey)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                ForEach(client.chats) { summary in
                    Button {
                        client.open(summary.id)
                    } label: {
                        chatRow(summary)
                    }
                    .buttonStyle(.plain)
                    .disabled(client.isStartingChat)
                    Divider().padding(.leading, 16)
                }

                HStack(spacing: 20) {
                    Button("Choose Another Mac") { client.chooseAnotherHost() }
                    Button("Forget This Mac", role: .destructive) { client.forgetConnectedHost() }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                AgentChatSetupBar(
                    client: client, kind: LampAgentRemoteChatSummary.reader, summary: nil,
                    about: referenceLabel, translation: reading.translationID,
                    maxExpandedHeight: setupRoom
                )
                composer(
                prompt: "Ask about \(referenceLabel)…",
                isRunning: client.isStartingChat,
                canSend: !client.isStartingChat && client.unsent[AgentRemoteClient.newChatKey] == nil,
                onSend: { if client.startChat(draft, reading: reading) { draft = "" } },
                onStop: nil
                )
            }
        }
    }

    private func chatRow(_ summary: LampAgentRemoteChatSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if summary.isRunning {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Replying")
                }
                Text(summary.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let updated = summary.updatedAt {
                    Text(updated, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(LampTheme.caption)
                }
            }
            if let preview = summary.preview, !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Text([summary.subtitle, summary.providerName].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(LampTheme.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The composer's words, kept by the client for this Mac and chat.
    private var draft: String {
        get { client.draft(for: draftDestination) }
        nonmutating set { client.setDraft(newValue, for: draftDestination) }
    }

    /// The words chosen in the writing, sent with the next message until
    /// someone takes them off it; kept with the draft, for its chat.
    private var selection: String? {
        get { client.selection(for: draftDestination) }
        nonmutating set { client.setSelection(newValue, for: draftDestination) }
    }

    /// Where this panel's words go: its chat when it shows one, else the new
    /// chat it would begin. A writing's panel doesn't take a chat opened for
    /// something else.
    private var draftDestination: String {
        if writing != nil {
            return showsWritingChat ? (client.openChatID ?? newChatKey) : newChatKey
        }
        return client.openChatID ?? newChatKey
    }

    /// The new chat this panel's composer begins: the reader's, or the
    /// writing's.
    private var newChatKey: String {
        writing.map { AgentRemoteClient.newChatKey(writing: $0.id) } ?? AgentRemoteClient.newChatKey
    }

    private var hostName: String? {
        if case let .connected(name) = client.phase { return name }
        return nil
    }

    // MARK: - A chat

    @ViewBuilder
    private var chatView: some View {
        if let chat = client.chat {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.summary.writingID != nil {
                            Text("What the assistant changes in the writing arrives with your library’s next sync.")
                                .font(.footnote)
                                .foregroundStyle(LampTheme.caption)
                        }
                        ForEach(chat.messages) { message in
                            messageView(message)
                        }
                        if let sending = chat.sending {
                            userBubble(sending)
                                .opacity(0.6)
                        }
                        if let unsent = client.unsent[chat.id] {
                            unsentView(unsent, key: chat.id)
                        }
                        // A first message for this writing that didn't go:
                        // sent again, it goes on in this chat.
                        if let writing, let unsent = client.unsent[AgentRemoteClient.newChatKey(writing: writing.id)] {
                            unsentView(unsent, key: AgentRemoteClient.newChatKey(writing: writing.id))
                        }
                        if let partial = chat.partialReply, !partial.isEmpty {
                            assistantText(partial)
                        }
                        if chat.isRunning {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(AgentRemoteChat.describe(chat.activity))
                                    .font(.footnote)
                                    .foregroundStyle(LampTheme.caption)
                                    .lineLimit(2)
                            }
                        }
                        if let problem = chat.problem {
                            problemText(problem)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.chatEnd)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onAppear { proxy.scrollTo(Self.chatEnd, anchor: .bottom) }
                .onChange(of: chat.messages.count) { proxy.scrollTo(Self.chatEnd, anchor: .bottom) }
                .onChange(of: chat.partialReply) { proxy.scrollTo(Self.chatEnd, anchor: .bottom) }
                .onChange(of: chat.sending) { proxy.scrollTo(Self.chatEnd, anchor: .bottom) }
            }
            .modifier(ChatHeader(shown: writing == nil) {
                chatHeader(chat)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .padding(.top, topObstruction)
                    .background(.bar)
            })
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    AgentChatSetupBar(
                        client: client, kind: chat.summary.kind, summary: chat.summary,
                        about: chat.summary.writingID != nil ? (writing?.title ?? chat.summary.subtitle ?? "This writing") : referenceLabel,
                        translation: chat.summary.writingID != nil ? nil : reading.translationID,
                        // A message on its way holds the chat's provider too:
                        // the Mac may still be preparing its turn.
                        isRunning: chat.isRunning || chat.sending != nil || stampingSend,
                        maxExpandedHeight: setupRoom
                    )
                    if chat.summary.writingID != nil { selectionLine }
                    composer(
                        prompt: composerPrompt(for: chat.summary),
                        isRunning: chat.isRunning,
                        canSend: chat.summary.acceptsMessages && !chat.isRunning && chat.sending == nil
                            && !client.isChangingChoices
                            && client.unsent[chat.id] == nil && sendingHeld == nil,
                        onSend: { sendInOpenChat(chat.summary) },
                        onStop: { client.cancel() }
                    )
                }
            }
        } else {
            waiting("Opening the chat…")
        }
    }

    private static let chatEnd = "chat-end"

    /// What the opened setup may take of the panel: in the reader's short
    /// split it scrolls rather than push its own row out of the panel.
    private var setupRoom: CGFloat {
        panelHeight > 0 ? max(120, panelHeight * 0.4) : .infinity
    }

    // MARK: - A writing's chat

    /// Whether the chat open is this writing's: the one the Mac's list gives
    /// it, or the one a first message just began.
    private var showsWritingChat: Bool {
        guard let writing, let openChatID = client.openChatID else { return false }
        if client.chat?.summary.writingID?.caseInsensitiveCompare(writing.id) == .orderedSame { return true }
        return client.chatSummary(forWriting: writing.id)?.id == openChatID
    }

    /// Opens the writing's chat on the Mac when the list shows it has one.
    private func openWritingChat() {
        guard let writing, !openedWritingChat, client.phase == .connected(hostName ?? ""), !client.isStartingChat,
              let summary = client.chatSummary(forWriting: writing.id) else { return }
        openedWritingChat = true
        guard client.openChatID != summary.id else { return }
        client.open(summary.id, carryingDraftFrom: AgentRemoteClient.newChatKey(writing: writing.id))
    }

    /// Asking about a writing that has no chat yet: the first message begins
    /// it, on the Mac, about this writing.
    private var writingStart: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ask the assistant about “\(writing?.title ?? "this writing")”")
                    .font(.headline)
                Text("It works on the writing in Lamp Bible on your Mac. What it changes arrives here with your library’s next sync.")
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = client.listProblem {
                    problemText(problem)
                }
                if let writing, let unsent = client.unsent[AgentRemoteClient.newChatKey(writing: writing.id)] {
                    unsentView(unsent, key: AgentRemoteClient.newChatKey(writing: writing.id))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16 + topObstruction)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                AgentChatSetupBar(
                    client: client, kind: LampAgentRemoteChatSummary.writing, summary: nil,
                    about: writing?.title ?? "This writing",
                    isRunning: stampingSend,
                    maxExpandedHeight: setupRoom
                )
                selectionLine
                composer(
                    prompt: "Ask about this writing…",
                    isRunning: client.isStartingChat,
                    canSend: !client.isStartingChat && sendingHeld == nil
                        && writing.map { client.unsent[AgentRemoteClient.newChatKey(writing: $0.id)] == nil } == true,
                    onSend: {
                        guard let writing else { return }
                        let words = draft
                        let chosen = selection
                        let destination = draftDestination
                        stampingSend = true
                        Task {
                            defer { stampingSend = false }
                            guard let stamp = await AgentRemoteWritingStamp.current(writingID: writing.id) else {
                                client.keepUnstamped(
                                    words, selection: chosen, writingID: writing.id, key: destination, startsChat: true
                                )
                                clearSent(words, chosen: chosen, from: destination)
                                return
                            }
                            if client.startWritingChat(
                                words, writingID: writing.id, selection: chosen,
                                writingRevision: stamp.revision, writingDigest: stamp.digest
                            ) {
                                clearSent(words, chosen: chosen, from: destination)
                            }
                        }
                    },
                    onStop: nil
                )
            }
        }
    }

    /// The words chosen in the writing, going with the next message, and
    /// what holds sending, if anything.
    @ViewBuilder
    private var selectionLine: some View {
        if let sendingHeld {
            HStack(spacing: 8) {
                if onRetryHeld == nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(sendingHeld)
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onRetryHeld {
                    Button("Try Again", action: onRetryHeld)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        if let selection, !selection.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.quote")
                    .foregroundStyle(LampTheme.caption)
                Text("About: “\(selection)”")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    self.selection = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LampTheme.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Don’t send the chosen words")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func composerPrompt(for summary: LampAgentRemoteChatSummary) -> String {
        if summary.acceptsMessages {
            return summary.writingID != nil ? "Ask about this writing…" : "Ask about \(referenceLabel)…"
        }
        // A writing that came in a module, or a chat the Mac keeps to itself.
        return summary.writingID != nil ? "A writing from a module can’t be changed" : "Continue this chat on your Mac"
    }

    /// A message in the open chat: with the reader's place for a reader
    /// chat, with the chosen words for a writing's.
    private func sendInOpenChat(_ summary: LampAgentRemoteChatSummary) {
        guard let writingID = summary.writingID else {
            if client.send(draft, reading: reading) { draft = "" }
            return
        }
        // About a writing: with its revision and digest as stored now.
        let words = draft
        let chosen = selection
        let destination = draftDestination
        let known = Set(client.chat?.id == summary.id ? client.chat?.messages.map(\.id) ?? [] : [])
        stampingSend = true
        Task {
            defer { stampingSend = false }
            // Not read, it isn't sent: without the stamp the Mac would take it
            // as from an older phone and skip its check of its own copy.
            guard let stamp = await AgentRemoteWritingStamp.current(writingID: writingID) else {
                client.keepUnstamped(words, selection: chosen, writingID: writingID, key: summary.id, startsChat: false, known: known)
                clearSent(words, chosen: chosen, from: destination)
                return
            }
            if client.send(
                words, reading: nil, selection: chosen,
                writingRevision: stamp.revision, writingDigest: stamp.digest, inChat: summary.id
            ) {
                clearSent(words, chosen: chosen, from: destination)
            }
        }
    }

    /// Takes words that went (or were kept as not sent) out of the composer:
    /// where they were written, and where they've moved since, as when the
    /// writing's chat turned up while they were on their way. Words written
    /// meanwhile stay.
    private func clearSent(_ words: String, chosen: String?, from destination: String) {
        for place in Set([destination, draftDestination]) {
            if client.draft(for: place) == words { client.setDraft("", for: place) }
            if client.selection(for: place) == chosen { client.setSelection(nil, for: place) }
        }
    }

    private func chatHeader(_ chat: AgentRemoteChat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                client.closeChat()
            } label: {
                Label("Chats", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(chat.summary.subtitle.flatMap { chat.summary.writingID != nil ? $0 : nil } ?? chat.summary.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(chat.summary.providerName)
                    .font(.caption)
                    .foregroundStyle(LampTheme.caption)
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: LampAgentRemoteChatMessage) -> some View {
        if message.role == LampAgentRemoteChatMessage.user {
            userBubble(message.text)
        } else {
            assistantText(message.text)
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(toolText.font())
                .lineSpacing(toolText.lineSpacing)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func assistantText(_ text: String) -> some View {
        Text(Self.markdown(text))
            .font(toolText.font())
            .lineSpacing(toolText.lineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Mac's reply is Markdown. Emphasis, code and links are drawn, and
    /// its lines are kept as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// A message that didn't go, with what went wrong and the two ways on.
    private func unsentView(_ unsent: AgentRemoteClient.Unsent, key: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            userBubble(unsent.words)
                .opacity(0.6)
            problemText("Not sent. \(unsent.problem)")
            HStack(spacing: 16) {
                Button("Edit") {
                    if let kept = client.takeUnsent(key) {
                        draft = draft.isEmpty ? kept.words : draft + "\n" + kept.words
                        if let chosen = kept.selection { selection = chosen }
                    }
                }
                Button("Try Again") {
                    let writingID = unsent.writingID ?? client.chat?.summary.writingID
                    Task {
                        var stamp: (revision: Int?, digest: String?) = (nil, nil)
                        if let writingID {
                            guard let read = await AgentRemoteWritingStamp.current(writingID: writingID) else {
                                client.keepProblem(AgentRemoteWritingStamp.unreadable, forUnsent: key)
                                return
                            }
                            stamp = (read.revision, read.digest)
                        }
                        client.resend(
                            key, reading: writingID == nil ? reading : nil,
                            writingRevision: stamp.revision, writingDigest: stamp.digest
                        )
                    }
                }
                    .disabled(client.chat?.isRunning == true || client.isStartingChat || sendingHeld != nil)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func problemText(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Composer

    /// Above the reader's bottom bar, unless the keyboard has taken its place:
    /// below the reader the split is laid out above the keyboard; beside it,
    /// the composer rises over the keyboard itself.
    private var composerBottomPadding: CGFloat {
        guard composerFocused, keyboardUp else { return bottomObstruction + 8 }
        return besideReader ? keyboardHeight + 8 : 8
    }

    /// One line of the field, as drawn: the body's line and the field's
    /// padding, scaled with the text.
    @ScaledMetric(relativeTo: .body) private var composerFieldHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var composerButtonSize: CGFloat = 34

    private func composerButtonImage(_ name: String) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: composerButtonSize, height: composerButtonSize)
    }

    private func composer(
        prompt: String,
        isRunning: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onStop: (() -> Void)?
    ) -> some View {
        let hasWords = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(prompt, text: Binding(get: { draft }, set: { draft = $0 }), axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LampTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(LampTheme.hairline)
                }
            // As tall as the field's one line and level with it, the field
            // growing upward from the same bottom when it takes more lines.
            Group {
                if isRunning, let onStop {
                    Button(action: onStop) { composerButtonImage("stop.circle.fill") }
                        .accessibilityLabel("Stop Reply")
                } else if isRunning {
                    ProgressView()
                } else {
                    Button(action: onSend) { composerButtonImage("arrow.up.circle.fill") }
                        .disabled(!canSend || !hasWords)
                        .accessibilityLabel("Send")
                }
            }
            .frame(width: composerButtonSize, height: composerFieldHeight)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, composerBottomPadding)
        .background(.bar)
    }
}

/// The open chat's header, kept in view over the messages so the way back to
/// the list never scrolls off. It takes the place of the shared header's
/// margin, so the messages don't make room for it twice. A writing's sheet
/// has none: its own bar names the writing, and there's no list to go back to.
private struct ChatHeader<Header: View>: ViewModifier {
    let shown: Bool
    @ViewBuilder let header: () -> Header

    func body(content: Content) -> some View {
        if shown {
            content
                .contentMargins(.top, 0, for: .scrollContent)
                .safeAreaInset(edge: .top, spacing: 0, content: header)
        } else {
            content
        }
    }
}

private extension View {
    /// A title over a subtitle in the bar: the system's own from iOS 26,
    /// drawn in the bar's middle before it, where a subtitle isn't shown.
    @ViewBuilder
    func titled(_ title: String, subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            navigationTitle(title)
                .navigationSubtitle(subtitle)
        } else {
            navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
        }
    }
}

/// Who answers in a chat, and what each message is sent with: one folded
/// row over the composer, naming the provider, the model and what the chat
/// is about, as the row over a Mac window's chat does. Opened, it holds the
/// provider, model and effort menus and a card saying what the chat may
/// read. It opens by itself when the provider can't answer on the Mac.
///
/// Over an open chat, a choice moves that chat, on the Mac too. Over the
/// composer that begins a chat, it's what the chat will begin with.
struct AgentChatSetupBar: View {
    @ObservedObject var client: AgentRemoteClient
    /// `LampAgentRemoteChatSummary.reader` or `.writing`.
    let kind: String
    /// The open chat, or nil for the chat the composer begins.
    let summary: LampAgentRemoteChatSummary?
    /// What the chat is about: the passage, or the writing.
    let about: String
    /// The translation a reader chat's passage is read in.
    var translation: String?
    /// A turn is running or on its way in this chat, or being sent.
    var isRunning = false
    /// The most the opened setup takes before it scrolls.
    var maxExpandedHeight: CGFloat = .infinity
    @State private var expandedHeight: CGFloat = 0

    @AppStorage("agentRemote.showsSetup") private var showsSetup = false
    /// Opened because the provider couldn't answer, so it folds again once
    /// another is chosen or it's signed in.
    @State private var openedForConnection = false
    @State private var typing: Choice?
    @State private var typed = ""
    /// The provider a typed model or effort is for: a name means nothing to
    /// another, so it isn't sent if the chat has moved meanwhile.
    @State private var typingFor: String?

    enum Choice: String, Identifiable {
        case model = "Model"
        case effort = "Effort"
        var id: String { rawValue }
    }

    var body: some View {
        if let setup = client.setup {
            let provider = provider(in: setup)
            VStack(alignment: .leading, spacing: 10) {
                toggle(provider)
                if showsSetup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            choices(setup, provider: provider)
                            notices(provider)
                            contextCard(setup)
                        }
                        .padding(.bottom, 2)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(expandedHeight, maxExpandedHeight))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .onAppear { followConnection(provider) }
            .onChange(of: provider?.connection) { followConnection(provider) }
            .onChange(of: providerID) { typing = nil }
            .alert(typing?.rawValue ?? "", isPresented: Binding(get: { typing != nil }, set: { if !$0 { typing = nil } }), presenting: typing) { choice in
                TextField("Default", text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use Default") { chooseTyped(choice, "") }
                Button("Cancel", role: .cancel) {}
                Button("Done") { chooseTyped(choice, typed) }
                    .keyboardShortcut(.defaultAction)
            } message: { choice in
                Text(choice == .model ? provider?.modelHint ?? "" : provider?.effortHint ?? "")
            }
        }
    }

    // MARK: What it runs with

    private var chosenForNewChat: LampAgentRemoteChoices {
        client.newChatChoices[kind] ?? LampAgentRemoteChoices()
    }

    private var providerID: String? {
        summary?.provider ?? chosenForNewChat.provider ?? client.setup?.defaultProvider(forKind: kind)
    }

    private func provider(in setup: LampAgentRemoteSetup) -> LampAgentRemoteSetup.Provider? {
        setup.provider(providerID)
    }

    /// A model typed with its variant on it (`provider/model#high`), split
    /// as the Mac's menus show it, where the effort rides on the model.
    private func split(_ model: String, _ provider: LampAgentRemoteSetup.Provider?) -> (model: String, variant: String?) {
        guard provider?.effortIsOnTheModel == true, let hash = model.firstIndex(of: "#") else { return (model, nil) }
        let variant = String(model[model.index(after: hash)...])
        return (String(model[..<hash]), variant.isEmpty ? nil : variant)
    }

    /// The model the chat runs with: "" for the provider's default.
    private func model(_ provider: LampAgentRemoteSetup.Provider?) -> String {
        if let summary { return summary.model ?? "" }
        return split(chosenForNewChat.model ?? provider?.defaultModel ?? "", provider).model
    }

    private func effort(_ provider: LampAgentRemoteSetup.Provider?) -> String {
        if let summary { return summary.effort ?? "" }
        if let effort = chosenForNewChat.effort { return effort }
        // A model chosen here drops the effort carried on the old one, unless
        // it was typed with one of its own.
        if provider?.effortIsOnTheModel == true, let model = chosenForNewChat.model {
            return split(model, provider).variant ?? ""
        }
        return provider?.defaultEffort ?? ""
    }

    private var providerName: String {
        client.setup?.provider(providerID)?.shortName ?? summary?.providerName ?? "Your Mac"
    }

    /// An open chat can't be moved while it replies, or while a move is on
    /// its way.
    private var canChoose: Bool {
        guard let summary else { return !client.isStartingChat && !isRunning }
        return !isRunning && !client.isChangingChoices && summary.acceptsMessages
            && client.unsent[summary.id] == nil
    }

    private func apply(_ change: LampAgentRemoteChoices) {
        if summary != nil {
            // Named with the provider it was chosen for, which the chat may
            // have left meanwhile on the Mac.
            var change = change
            if change.provider == nil { change.provider = providerID }
            client.setChoices(change)
        } else {
            client.chooseForNewChat(change, kind: kind)
        }
    }

    private func choose(_ choice: Choice, _ value: String) {
        // A typed value's alert can outlast what allowed it.
        guard canChoose else { typing = nil; return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(choice == .model ? LampAgentRemoteChoices(model: value) : LampAgentRemoteChoices(effort: value))
        typing = nil
    }

    private func chooseTyped(_ choice: Choice, _ value: String) {
        guard typingFor == providerID else { typing = nil; return }
        choose(choice, value)
    }

    private func followConnection(_ provider: LampAgentRemoteSetup.Provider?) {
        guard let connection = provider?.connection else { return }
        if connection.needsAttention, !showsSetup {
            withAnimation(.easeInOut(duration: 0.15)) { showsSetup = true }
            openedForConnection = true
        } else if connection.isConnected, openedForConnection {
            withAnimation(.easeInOut(duration: 0.15)) { showsSetup = false }
            openedForConnection = false
        }
    }

    // MARK: The row

    private func toggle(_ provider: LampAgentRemoteSetup.Provider?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showsSetup.toggle() }
            openedForConnection = false
            if showsSetup { client.refreshSetup() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LampTheme.caption)
                    .rotationEffect(.degrees(showsSetup ? 90 : 0))
                if let image = provider?.systemImage {
                    Image(systemName: image)
                        .foregroundStyle(LampTheme.caption)
                }
                Text(LampAgentRemoteSetupLine.line(provider: providerName, model: model(provider), about: about))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let connection = provider?.connection, connection.needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(connection.label)
                }
                Spacer(minLength: 0)
                if client.isChangingChoices && summary != nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(showsSetup ? "Hides the chat's setup" : "Shows the provider, model and effort, and what each message is sent with")
    }

    // MARK: The menus

    /// The three menus in a row, wrapping chip by chip where it won't fit,
    /// each whole.
    private func choices(_ setup: LampAgentRemoteSetup, provider: LampAgentRemoteSetup.Provider?) -> some View {
        WrappingHStack(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            menus(setup, provider: provider)
        }
        .disabled(!canChoose)
        // The chips draw their own colours, which disabling doesn't dim.
        .opacity(canChoose ? 1 : 0.5)
    }

    @ViewBuilder
    private func menus(_ setup: LampAgentRemoteSetup, provider: LampAgentRemoteSetup.Provider?) -> some View {
        Menu {
            Picker("Provider", selection: Binding(
                get: { providerID ?? "" },
                set: { chosen in if chosen != providerID { apply(LampAgentRemoteChoices(provider: chosen)) } }
            )) {
                ForEach(setup.providers) { option in
                    if option.connection.needsAttention {
                        Label(option.shortName, systemImage: "exclamationmark.triangle").tag(option.id)
                    } else {
                        Text(option.shortName).tag(option.id)
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            chip(providerName, systemImage: provider?.systemImage)
        }
        .accessibilityLabel("Provider")
        .accessibilityValue(providerName)

        if let provider {
            let model = model(provider)
            Menu {
                choiceMenu(.model, value: model, offered: provider.models, provider: provider)
            } label: {
                chip(LampAgentRemoteSetupLine.choice(model, defaultLabel: "Default model"), isPlaceholder: model.isEmpty, maxTitleWidth: 170)
            }
            .accessibilityLabel("Model")

            let effort = effort(provider)
            Menu {
                if provider.takesEffort(withModel: model) {
                    choiceMenu(.effort, value: effort, offered: provider.efforts, provider: provider)
                } else {
                    Text(provider.effortNeedsModel)
                }
            } label: {
                chip(LampAgentRemoteSetupLine.choice(effort, defaultLabel: "Default effort"), isPlaceholder: effort.isEmpty, maxTitleWidth: 120)
            }
            .accessibilityLabel("Effort")
        }
    }

    /// The provider's default, the names it stands behind, and another typed.
    @ViewBuilder
    private func choiceMenu(_ choice: Choice, value: String, offered: [String], provider: LampAgentRemoteSetup.Provider) -> some View {
        let current = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Button {
            choose(choice, "")
        } label: {
            if current.isEmpty { Label("\(provider.shortName) default", systemImage: "checkmark") } else { Text("\(provider.shortName) default") }
        }
        if !offered.isEmpty {
            Section {
                ForEach(offered, id: \.self) { option in
                    Button {
                        choose(choice, option)
                    } label: {
                        if current == option { Label(option, systemImage: "checkmark") } else { Text(option) }
                    }
                }
            }
        }
        Section {
            Button(current.isEmpty || offered.contains(current) ? "Other \(choice.rawValue)…" : "\(current)…") {
                typed = current
                typingFor = providerID
                typing = choice
            }
        }
    }

    /// Capped where a typed name can run long, cut in the middle so it keeps
    /// its family and its date, as the Mac's menus are.
    private func chip(_ title: String, systemImage: String? = nil, isPlaceholder: Bool = false, maxTitleWidth: CGFloat? = nil) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(LampTheme.caption)
            }
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isPlaceholder ? Color(uiColor: .secondaryLabel) : Color(uiColor: .label))
                .frame(maxWidth: maxTitleWidth, alignment: .leading)
                .fixedSize(horizontal: maxTitleWidth == nil, vertical: false)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(LampTheme.caption)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(LampTheme.card, in: Capsule())
        .overlay { Capsule().strokeBorder(LampTheme.hairline) }
        .fixedSize()
    }

    // MARK: What it says

    @ViewBuilder
    private func notices(_ provider: LampAgentRemoteSetup.Provider?) -> some View {
        if let connection = provider?.connection, connection.needsAttention {
            VStack(alignment: .leading, spacing: 2) {
                Label("\(provider?.shortName ?? "This provider"): \(connection.label)", systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                if let remedy = connection.remedy {
                    Text(remedy)
                        .font(.caption)
                        .foregroundStyle(LampTheme.caption)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        if summary != nil, isRunning {
            Text("Wait for the reply to finish to change who answers.")
                .font(.caption)
                .foregroundStyle(LampTheme.caption)
        }
        if let problem = client.choicesProblem, let summary, client.choicesProblemChatID == summary.id {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What each message is sent with, in one card, as on the Mac.
    private func contextCard(_ setup: LampAgentRemoteSetup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: kind == LampAgentRemoteChatSummary.writing ? "square.and.pencil" : "book")
                    .foregroundStyle(LampTheme.caption)
                Text(about)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let translation, !translation.isEmpty {
                    Text(translation)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .lineLimit(1)
                }
            }
            .font(.subheadline)
            if kind == LampAgentRemoteChatSummary.writing {
                Text("The assistant may change this writing. What it changes is marked for you to review.")
                    .font(.caption)
                    .foregroundStyle(LampTheme.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let access = setup.access {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if access.readOnly {
                        Label("Read-only", systemImage: "lock")
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(access.modules)
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(LampTheme.caption)
            }
            Text("Providers and module access are set in Lamp Bible on your Mac, in Settings › AI & Agents.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LampTheme.Radius.tile, style: .continuous)
                .strokeBorder(LampTheme.hairline)
        }
    }
}
