import LampCore
import SwiftUI

/// The reader's Chat panel: the Mac's reader chats, followed and continued
/// from here, each message sent with where this device is reading.
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

    @ObservedObject private var client = AgentRemoteClient.shared
    @State private var code = ""
    @State private var showingScanner = false
    @State private var scannerError: String?
    @FocusState private var composerFocused: Bool
    @FocusState private var codeFocused: Bool
    /// How far up the screen the onscreen keyboard reaches, nothing with a
    /// hardware keyboard: focus alone leaves the reader's bottom bar where it
    /// was, and the composer clear of it.
    @State private var keyboardHeight: CGFloat = 0
    private var keyboardUp: Bool { keyboardHeight > 100 }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { client.panelAppeared() }
            .onDisappear {
                if composerFocused || codeFocused { NoteEditorFocus.shared.isEditing = false }
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
                NoteEditorFocus.shared.isEditing = focused
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
            if client.openChatID != nil {
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
            composer(
                prompt: "Ask about \(referenceLabel)…",
                isRunning: client.isStartingChat,
                canSend: !client.isStartingChat && client.unsent[AgentRemoteClient.newChatKey] == nil,
                onSend: { if client.startChat(draft, reading: reading) { draft = "" } },
                onStop: nil
            )
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
        get { client.draft }
        nonmutating set { client.draft = newValue }
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
            // Kept in view, so the way back to the list never scrolls off.
            // The header takes the place of the shared header's margin, so
            // the messages don't make room for it twice.
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) {
                chatHeader(chat)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .padding(.top, topObstruction)
                    .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer(
                    prompt: chat.summary.acceptsMessages ? "Ask about \(referenceLabel)…" : "Continue this chat on your Mac",
                    isRunning: chat.isRunning,
                    canSend: chat.summary.acceptsMessages && !chat.isRunning && chat.sending == nil
                        && client.unsent[chat.id] == nil,
                    onSend: { if client.send(draft, reading: reading) { draft = "" } },
                    onStop: { client.cancel() }
                )
            }
        } else {
            waiting("Opening the chat…")
        }
    }

    private static let chatEnd = "chat-end"

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
                Text(chat.summary.title)
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
                    if let words = client.takeUnsent(key) {
                        draft = draft.isEmpty ? words : draft + "\n" + words
                    }
                }
                Button("Try Again") { client.resend(key, reading: reading) }
                    .disabled(client.chat?.isRunning == true || client.isStartingChat)
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
            if isRunning, let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .accessibilityLabel("Stop Reply")
            } else if isRunning {
                ProgressView()
                    .frame(width: 28, height: 28)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSend || !hasWords)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, composerBottomPadding)
        .background(.bar)
    }
}
