import Combine
import Foundation
import LampCore
import Network
import UIKit

/// The phone's window onto the Mac's agent chats.
///
/// The phone can't sign in to the providers' command-line tools, so it runs
/// no agent of its own: the Mac does, and this follows its reader chats and
/// sends the next message, over the local network or peer to peer, with
/// nothing of ours in between. Core's `LampAgentRemoteDeviceConnection` holds
/// the protocol, the same machine the Mac's host is tested against; this
/// finds the Mac, carries the bytes, and keeps what the panel shows.
///
/// Connections run on the main queue: what passes over one is a chat, and
/// every change to it is something the panel draws.
@MainActor
final class AgentRemoteClient: ObservableObject {
    static let shared = AgentRemoteClient()

    enum Phase: Equatable {
        case stopped
        /// Looking for Macs, with none chosen yet.
        case searching
        case connecting(String)
        /// The Mac doesn't know this device: scan its pairing code.
        case needsCode(host: String, notice: String?)
        case connected(String)
        /// Something to say, and a way to try again.
        case unavailable(String)
    }

    struct Host: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint

        static func == (lhs: Host, rhs: Host) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var hosts: [Host] = []
    @Published private(set) var chats: [LampAgentRemoteChatSummary] = []
    /// The chat open, once its snapshot has come.
    @Published private(set) var chat: AgentRemoteChat?
    /// The chat asked for, which `chat` becomes when its snapshot comes.
    @Published private(set) var openChatID: String?
    @Published private(set) var isStartingChat = false
    /// What went wrong with a request made from the list.
    @Published private(set) var listProblem: String?
    @Published private(set) var rememberedHosts: [LampAgentRemoteRememberedHost]
    /// Set when someone asks to choose another Mac, so a single one found
    /// isn't connected to again on its own.
    @Published private(set) var choosingHost = false
    /// A message that didn't go: refused by the Mac, or caught by the
    /// connection ending. Kept with the chat it was for, so it can be sent
    /// again or edited rather than typed again.
    struct Unsent: Equatable {
        let words: String
        let problem: String
        /// The chat's messages when it was sent, so the same words asked
        /// before aren't taken for it.
        var known: Set<UUID> = []
        /// Where the reader was when it was asked, so Try Again asks about
        /// the same passage, wherever the reader is now.
        var reading: LampAgentRemoteReading?
        /// The request it went in, when the connection ended before the Mac
        /// answered: the Mac names it on the question's events if it had it.
        var requestID: UUID?
        /// The words chosen in the writing it was asked about, sent with it.
        var selection: String?
        /// The writing a new chat's first message was about.
        var writingID: String?
        /// It begins a new chat when sent again, rather than going on in the
        /// chat it's kept under: said outright, since a chat's id can look
        /// like anything.
        var startsChat = false
        /// The writing's revision it was sent with, which a retry keeps as
        /// the least the Mac's copy must be.
        var writingRevision: Int?
        /// The writing's body digest that went with that revision.
        var writingDigest: String?
    }

    /// Messages not sent, by chat id; a new chat's first message under its
    /// new-chat key ("" for the reader's, one per writing).
    @Published private(set) var unsent: [String: Unsent] = [:]
    static let newChatKey = ""

    /// Where a new chat about a writing keeps its draft and a first message
    /// that didn't go.
    /// Its own form, which no chat id the Mac gives takes (the Mac's writing
    /// chats are `writing:<id>`).
    static func newChatKey(writing writingID: String) -> String { "new-writing|\(writingID.uppercased())" }

    /// What's being written, for each Mac (by its secret, whatever it's
    /// called) and chat: kept here, so a panel closed or switched away from
    /// keeps it, and words meant for one conversation never go to another.
    @Published private var drafts: [String: String] = [:]

    /// The words written for one destination: a chat's id, or a new chat's
    /// key. Each panel says which is its own, so one window's chat never
    /// takes another's words.
    func draft(for destination: String) -> String {
        drafts["\(chatsHostSecret ?? "")|\(destination)"] ?? ""
    }

    func setDraft(_ text: String, for destination: String) {
        drafts["\(chatsHostSecret ?? "")|\(destination)"] = text.isEmpty ? nil : text
    }

    /// Moves what was written for one destination to another, joined to what
    /// is there.
    private func moveDraft(from source: String, to destination: String) {
        let moving = draft(for: source)
        guard !moving.isEmpty, source != destination else { return }
        setDraft("", for: source)
        let waiting = draft(for: destination)
        setDraft(waiting.isEmpty ? moving : waiting + "\n\n" + moving, for: destination)
    }

    private let memory: AgentRemoteMemory
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var session: LampAgentRemoteDeviceConnection?
    private var host: Host?
    /// Said on the pairing screen when it next opens.
    private var pendingNotice: String?
    /// The new chat asked for, and its first message.
    private var startRequest: StartRequest?

    private struct StartRequest {
        let id: UUID
        let words: String
        let known: Set<UUID>
        let reading: LampAgentRemoteReading?
        /// Where the new chat's draft and a first message that didn't go are kept.
        let key: String
        let writingID: String?
        let selection: String?
    }
    /// Sends not yet answered, with the chat each was for and its words.
    private var sendRequests: [UUID: (chatID: String, words: String, known: Set<UUID>, reading: LampAgentRemoteReading?, selection: String?)] = [:]

    /// The writing revision each request about a writing went with.
    private var requestRevisions: [UUID: Int] = [:]
    /// And the body digest that went with it.
    private var requestDigests: [UUID: String] = [:]

    /// Whether `messages` holds this question as a message the chat didn't
    /// have when it was sent: the same words asked before are not it.
    private static func holds(_ messages: [LampAgentRemoteChatMessage], _ words: String, known: Set<UUID>) -> Bool {
        messages.contains { $0.role == LampAgentRemoteChatMessage.user && $0.text == words && !known.contains($0.id) }
    }
    private var aiObserver: AnyCancellable?
    /// The Chat panels showing, one per reader window: the connection stays
    /// while any of them does.
    private var panelsShowing = 0
    /// Why the Mac is about to close the connection, when it said: shown in
    /// place of the connection simply having been lost.
    private var closingReason: String?
    /// The secret of the Mac the chats shown are from, to tell when a
    /// connection reaches another Mac, whatever either is called.
    private var chatsHostSecret: String?
    /// Remembered keys a connection had turned away, not offered again until
    /// pairing replaces them. Not forgotten: a replayed hello from something
    /// that isn't the Mac, or a slow network, would otherwise undo a real
    /// pairing. Forgetting a Mac is the person's choice.
    private var refusedKeys: Set<String> = []
    /// Not-sent messages for Macs other than the one connected, by secret,
    /// kept for when it's back.
    private var parkedUnsent: [String: [String: Unsent]] = [:]
    /// The last chat asked for, so only its failure abandons the chat being
    /// opened.
    private var openRequest: UUID?
    /// The connected Mac names a question's request on its events, so a
    /// question without one was asked elsewhere, whatever its words.
    private var hostNamesRequests = false

    private static let lastHostKey = "agentRemote.lastHostName"
    static let localNetworkDenied = "Lamp Bible needs Local Network access to find your Mac. Allow it for Lamp Bible in Settings, then try again."
    /// How long a Mac has to answer a remembered key: it answers at once
    /// where it knows the key.
    static let savedKeyWait: TimeInterval = 6

    init(memory: AgentRemoteMemory = .shared) {
        self.memory = memory
        rememberedHosts = memory.hosts
        aiObserver = AIFeatures.shared.$isEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    if !enabled { self?.stop() }
                }
            }
    }

    // MARK: - Finding the Mac

    /// A Chat panel appeared.
    func panelAppeared() {
        panelsShowing += 1
        start()
    }

    /// A Chat panel went away: the connection ends with the last of them.
    func panelDisappeared() {
        panelsShowing = max(0, panelsShowing - 1)
        if panelsShowing == 0 { stop() }
    }

    /// Begins looking for Macs, if not already connected or connecting.
    func start() {
        guard AIFeatures.shared.isEnabled else { return }
        #if DEBUG
        if let demo = UserDefaults.standard.string(forKey: "AgentRemoteDemo") {
            showDemo(demo)
            return
        }
        #endif
        switch phase {
        case .connected, .connecting, .needsCode:
            return
        default:
            break
        }
        browse()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        teardown()
        hosts = []
        chat = nil
        choosingHost = false
        phase = .stopped
    }

    func retry() {
        if let host, !choosingHost {
            connect(to: host)
        } else {
            browse()
        }
    }

    /// Lets someone pick from the Macs found rather than the one chosen.
    func chooseAnotherHost() {
        teardown()
        choosingHost = true
        browse()
    }

    func forget(_ remembered: LampAgentRemoteRememberedHost) {
        memory.forget(remembered.id)
        rememberedHosts = memory.hosts
    }

    /// Forgets the Mac connected to, at the person's asking: the next
    /// connection to it pairs by code.
    func forgetConnectedHost() {
        guard let secret = chatsHostSecret else { return }
        // Ended first, so nothing waiting on this Mac is kept to be sent to
        // the next one.
        teardown()
        for remembered in memory.hosts where remembered.hostSecret == secret {
            memory.forget(remembered.id)
        }
        rememberedHosts = memory.hosts
        chats = []
        chat = nil
        openChatID = nil
        // What was written for this Mac goes with it; other Macs' stays.
        unsent = [:]
        parkedUnsent[secret] = nil
        drafts = drafts.filter { !$0.key.hasPrefix(secret + "|") }
        chatsHostSecret = nil
        chooseAnotherHost()
    }

    private func browse() {
        browser?.cancel()
        listProblem = nil
        phase = .searching
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: LampAgentRemoteProtocol.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case let .failed(error):
                    self.phase = .unavailable(error.localizedDescription)
                case let .waiting(error):
                    // Local Network access turned down: the browser waits for
                    // it rather than failing, and would look for ever.
                    if case let .dns(code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        self.phase = .unavailable(Self.localNetworkDenied)
                    }
                case .ready:
                    if self.phase == .unavailable(Self.localNetworkDenied) { self.phase = .searching }
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.hosts = results.compactMap { result -> Host? in
                    guard case let .service(name, type, domain, interface) = result.endpoint else { return nil }
                    let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
                    return Host(id: endpoint.debugDescription, name: name, endpoint: endpoint)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.connectIfOneIsClear()
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    /// The Mac chosen last time, or the only one there is: connected to
    /// without asking, since opening the chat panel is the asking.
    private func connectIfOneIsClear() {
        guard phase == .searching, connection == nil, !choosingHost else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastHostKey)
        if let match = hosts.first(where: { $0.name == last }) ?? (hosts.count == 1 ? hosts.first : nil) {
            connect(to: match)
        }
    }

    // MARK: - Connecting

    func connect(to host: Host, pendingCode: String? = nil) {
        closingReason = nil
        hostNamesRequests = false
        browser?.cancel()
        browser = nil
        teardown()
        choosingHost = false
        self.host = host
        phase = .connecting(host.name)
        session = LampAgentRemoteDeviceConnection(
            remembered: memory.hosts.filter { !refusedKeys.contains($0.id) },
            hostName: host.name,
            clientName: PresentationRemoteClient.clientName,
            pendingCode: pendingCode
        )
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: host.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case let .failed(error), let .waiting(error):
                    // Waiting is a route gone while connecting: say so and
                    // offer to try again, rather than spin.
                    self.ended(error: error)
                default:
                    break
                }
            }
        }
        self.connection = connection
        connection.start(queue: .main)
        receive(on: connection)
    }

    /// The code from the Mac's QR, or typed. If the connection it was meant
    /// for has closed while someone scanned, a new one answers with it.
    func pair(code: String) {
        guard LampPresentationRemotePairing.normalizedCode(code) != nil else { return }
        if session?.isWaitingForCode == true, connection != nil {
            perform(session?.pair(code: code) ?? [])
            if case .needsCode = phase, let host { phase = .connecting(host.name) }
        } else if let host {
            connect(to: host, pendingCode: code)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) { [weak self, weak connection] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.perform(self.session?.receive(data) ?? [])
                }
                // What was received may have closed it.
                guard self.connection === connection else { return }
                if isComplete || error != nil {
                    self.ended(error: error)
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    /// The connection ended. The Mac closing it, cleanly or by a reset, is
    /// told apart from the network losing it: only the Mac can turn a key
    /// away.
    private func ended(error: NWError?) {
        let byHost = error == nil || error == .posix(.ECONNRESET)
        let effects = session?.closed(byHost: byHost, reason: error?.localizedDescription) ?? []
        connection?.cancel()
        connection = nil
        perform(effects)
    }

    /// Ends the connection. Anything still waiting on an answer is kept as
    /// not sent, since whether the Mac had it can't be known.
    private func teardown() {
        connection?.cancel()
        connection = nil
        session = nil
        let problem = "The connection ended before your Mac answered, so it may have it. Check the chats before trying again."
        if let startRequest {
            keepForNewChat(Unsent(
                words: startRequest.words, problem: problem, known: startRequest.known,
                reading: startRequest.reading, requestID: startRequest.id,
                selection: startRequest.selection, writingID: startRequest.writingID,
                writingRevision: requestRevisions[startRequest.id], writingDigest: requestDigests[startRequest.id]
            ), key: startRequest.key)
        }
        for (requestID, request) in sendRequests {
            unsent[request.chatID] = Unsent(
                words: request.words, problem: problem, known: request.known,
                reading: request.reading, requestID: requestID, selection: request.selection,
                writingRevision: requestRevisions[requestID], writingDigest: requestDigests[requestID]
            )
        }
        isStartingChat = false
        startRequest = nil
        sendRequests = [:]
        chat?.sending = nil
    }

    private func perform(_ effects: [LampAgentRemoteDeviceConnection.Effect]) {
        // Everything the session has sealed goes out first, in its order:
        // what the steps below seal takes later numbers, and must follow it.
        for case let .send(data) in effects {
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
        for effect in effects {
            switch effect {
            case .send:
                break
            case let .needsCode(problem):
                phase = .needsCode(host: host?.name ?? "your Mac", notice: problem.map(AgentRemoteProblemText.text) ?? pendingNotice)
                pendingNotice = nil
            case let .remember(remembered):
                memory.remember(remembered)
                refusedKeys.remove(remembered.id)
                rememberedHosts = memory.hosts
            case let .keyRefused(id):
                refusedKeys.insert(id)
            case .watchSavedKey:
                let watched = connection
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.savedKeyWait) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let watched, self.connection === watched,
                              self.session?.offered != nil else { return }
                        let effects = self.session?.savedKeyTimedOut() ?? []
                        self.perform(effects)
                    }
                }
            case .connected:
                guard let host else { break }
                if let secret = session?.hostSecret {
                    if chatsHostSecret != secret {
                        // Another Mac's chats aren't this one's. What wasn't
                        // sent to it waits for it; drafts are kept by Mac.
                        if let earlier = chatsHostSecret {
                            parkedUnsent[earlier] = unsent
                            unsent = [:]
                            chatWritings = [:]
                            chats = []
                            chat = nil
                            openChatID = nil
                            listProblem = nil
                        }
                        if let parked = parkedUnsent.removeValue(forKey: secret) {
                            unsent.merge(parked) { current, _ in current }
                        }
                    }
                    chatsHostSecret = secret
                }
                phase = .connected(host.name)
                UserDefaults.standard.set(host.name, forKey: Self.lastHostKey)
                rememberedHosts = memory.hosts
                // Back where this device was before the connection dropped.
                if let openChatID {
                    let request = LampAgentRemoteMessage.openChat(openChatID)
                    openRequest = request.requestID
                    seal(request)
                }
            case let .received(message):
                handle(message)
            case .pairAgain:
                pendingNotice = AgentRemoteProblemText.refused
                if let host { connect(to: host) } else { teardown(); phase = .unavailable(AgentRemoteProblemText.refused) }
            case let .failed(problem):
                teardown()
                phase = .unavailable(AgentRemoteProblemText.text(problem))
            case .lost:
                teardown()
                phase = .unavailable(closingReason ?? "The connection to \(host?.name ?? "your Mac") was lost.")
                closingReason = nil
            }
        }
    }

    // MARK: - Messages

    private func handle(_ message: LampAgentRemoteMessage) {
        switch message.kind {
        case .chats:
            chats = message.chats ?? []
            noteWritings(chats)
        case .snapshot:
            guard let snapshot = message.snapshot else { return }
            let started = message.requestID != nil && message.requestID == startRequest?.id
            guard started || snapshot.summary.id == openChatID else { return }
            // Words typed while the new chat was on its way belong to it.
            if started, let startKey = startRequest?.key {
                moveDraft(from: startKey, to: snapshot.summary.id)
            }
            openChatID = snapshot.summary.id
            // The list knows the chat too, a new one included, so its
            // running state and its writing are known from it.
            noteWritings([snapshot.summary])
            if let index = chats.firstIndex(where: { $0.id == snapshot.summary.id }) {
                chats[index] = snapshot.summary
            } else {
                chats.insert(snapshot.summary, at: 0)
            }
            if chat?.id == snapshot.summary.id {
                chat?.apply(snapshot)
            } else {
                chat = AgentRemoteChat(snapshot)
            }
            if started, let start = startRequest {
                // The new chat comes before its first turn: the question is
                // still on its way, as any message sent in it would be.
                startRequest = nil
                isStartingChat = false
                // What the snapshot already holds came before this question:
                // a writing's chat goes on from what was said in it.
                sendRequests[start.id] = (
                    snapshot.summary.id, start.words, Set(snapshot.messages.map(\.id)), start.reading, start.selection
                )
                chat?.sending = start.words
            }
            // A question the snapshot already holds has arrived, whether it
            // was still on its way or kept as not sent when a connection ended.
            let id = snapshot.summary.id
            sendRequests = sendRequests.filter {
                $0.value.chatID != id || !Self.holds(snapshot.messages, $0.value.words, known: $0.value.known)
            }
            if let kept = unsent[id], Self.holds(snapshot.messages, kept.words, known: kept.known) {
                unsent[id] = nil
            }
            // The bubble for a message on its way stays while its request
            // does, a chat opened again included, and goes with it.
            if chat?.id == id {
                chat?.sending = sendRequests.values.first(where: { $0.chatID == id })?.words
            }
        case .event:
            guard let event = message.event else { return }
            chat?.apply(event)
            // The Mac began the turn with the question: it arrived.
            // A turn stopped before it showed anything brings its question
            // as a `reply`.
            if event.kind == LampAgentRemoteChatEvent.turnStarted || event.kind == LampAgentRemoteChatEvent.reply,
               let asked = event.message, asked.role == LampAgentRemoteChatMessage.user {
                if event.requestID != nil { hostNamesRequests = true }
                let pending = sendRequests.map {
                    AgentRemoteAcknowledgement.Pending(id: $0.key, chatID: $0.value.chatID, words: $0.value.words, known: $0.value.known)
                }
                let arrived = AgentRemoteAcknowledgement.arrived(
                    asked, in: event.chatID, requestID: event.requestID,
                    hostNamesRequests: hostNamesRequests, pending: pending
                )
                for requestID in arrived {
                    if let request = sendRequests.removeValue(forKey: requestID), chat?.id == request.chatID {
                        chat?.sending = nil
                    }
                }
                let kept = unsent.compactMap { key, value in
                    value.requestID.map { AgentRemoteAcknowledgement.Pending(id: $0, chatID: key, words: value.words, known: value.known) }
                }
                let arrivedKept = AgentRemoteAcknowledgement.arrived(
                    asked, in: event.chatID, requestID: event.requestID,
                    hostNamesRequests: hostNamesRequests, pending: kept
                )
                for (key, value) in unsent where value.requestID.map(arrivedKept.contains) == true {
                    unsent[key] = nil
                }
            }
            if let index = chats.firstIndex(where: { $0.id == event.chatID }) {
                if event.kind == LampAgentRemoteChatEvent.turnStarted { chats[index].isRunning = true }
                if event.kind == LampAgentRemoteChatEvent.turnEnded {
                    chats[index].isRunning = false
                    // What the assistant changed in a writing comes by sync:
                    // start a pass now rather than wait for the next.
                    if chats[index].writingID != nil {
                        Task { try? await SyncCoordinator.shared.syncAll() }
                    }
                }
            }
        case .failed:
            failed(message)
        default:
            // `accepted` is the session's; anything else is a kind a later
            // Lamp knows.
            break
        }
    }

    private func failed(_ message: LampAgentRemoteMessage) {
        let text = AgentRemoteFailureText.text(code: message.errorCode, message: message.errorMessage)
        if message.errorCode == LampAgentRemoteFailure.aiOff {
            teardown()
            phase = .unavailable(text)
            return
        }
        // Not answering anything: the Mac has forgotten this device, and
        // closes the connection next. Pairing again is what's left.
        if message.errorCode == LampAgentRemoteFailure.notAllowed, message.requestID == nil {
            closingReason = AgentRemoteProblemText.refused
            return
        }
        if let requestID = message.requestID, let start = startRequest, requestID == start.id {
            startRequest = nil
            isStartingChat = false
            // A Mac from before writing chats refuses one as not allowed.
            let problem = start.writingID != nil && message.errorCode == LampAgentRemoteFailure.notAllowed
                ? Self.macTooOldForWritings : text
            keepForNewChat(Unsent(
                words: start.words, problem: problem, known: start.known, reading: start.reading,
                selection: start.selection, writingID: start.writingID,
                writingRevision: requestRevisions[start.id], writingDigest: requestDigests[start.id]
            ), key: start.key)
            return
        }
        if let requestID = message.requestID, let request = sendRequests.removeValue(forKey: requestID) {
            if chat?.id == request.chatID { chat?.sending = nil }
            if message.errorCode == LampAgentRemoteFailure.notFound {
                // The chat has gone: the question can begin a new one.
                let writingID = writingID(ofChat: request.chatID)
                keepForNewChat(Unsent(
                    words: request.words, problem: text, known: request.known, reading: request.reading,
                    selection: request.selection, writingID: writingID,
                    writingRevision: requestRevisions[requestID], writingDigest: requestDigests[requestID]
                ), key: writingID.map(Self.newChatKey(writing:)) ?? Self.newChatKey)
                if openChatID == request.chatID { leaveChat(saying: text) }
            } else {
                unsent[request.chatID] = Unsent(
                    words: request.words, problem: text, known: request.known, reading: request.reading,
                    selection: request.selection, writingRevision: requestRevisions[requestID], writingDigest: requestDigests[requestID]
                )
            }
            return
        }
        if message.errorCode == LampAgentRemoteFailure.notFound, let openChatID, message.chatID == openChatID {
            leaveChat(saying: text)
            return
        }
        // A chat asked for that couldn't be opened: back to the list, saying
        // why, rather than waiting on a snapshot that won't come.
        if let requestID = message.requestID, requestID == openRequest {
            leaveChat(saying: text)
            return
        }
        if chat != nil {
            chat?.requestProblem = text
        } else {
            listProblem = text
        }
    }

    /// Keeps a question for a new chat. One already waiting there is kept too,
    /// the two joined, so neither is lost: Edit brings both back.
    private func keepForNewChat(_ kept: Unsent, key: String = AgentRemoteClient.newChatKey) {
        var kept = kept
        kept.startsChat = true
        if let waiting = unsent[key], waiting.words != kept.words {
            unsent[key] = Unsent(
                words: waiting.words + "\n\n" + kept.words, problem: kept.problem,
                reading: kept.reading ?? waiting.reading, selection: kept.selection ?? waiting.selection,
                writingID: kept.writingID ?? waiting.writingID, startsChat: true,
                writingRevision: [kept.writingRevision, waiting.writingRevision].compactMap { $0 }.max()
            )
        } else {
            unsent[key] = kept
        }
    }

    static let macTooOldForWritings = "Your Mac didn’t take this. If Lamp Bible there hasn’t been updated lately, update it to ask about writings from here."


    /// Back to the list, saying why: the open chat has gone from the Mac.
    private func leaveChat(saying text: String) {
        // A question kept for the chat that's gone can begin a new one, about
        // the same writing if the chat was one's.
        let writingID = openChatID.flatMap(writingID(ofChat:))
        let key = writingID.map(Self.newChatKey(writing:)) ?? Self.newChatKey
        if let openChatID, var kept = unsent.removeValue(forKey: openChatID) {
            kept.writingID = writingID
            keepForNewChat(kept, key: key)
        }
        // And one still on its way to it, which now never will arrive.
        for (requestID, request) in sendRequests where request.chatID == openChatID {
            sendRequests[requestID] = nil
            keepForNewChat(Unsent(
                words: request.words, problem: text, reading: request.reading,
                selection: request.selection, writingID: writingID,
                writingRevision: requestRevisions[requestID], writingDigest: requestDigests[requestID]
            ), key: key)
        }
        // And what was being written in it, to the new chat's composer.
        if let openChatID { moveDraft(from: openChatID, to: key) }
        chat = nil
        openChatID = nil
        listProblem = text
        seal(.listChats())
    }

    private func seal(_ message: LampAgentRemoteMessage) {
        perform(session?.seal(message) ?? [])
    }

    /// Seals and sends a request, saying whether it went: one too large to
    /// seal, or with no connection to go on, doesn't.
    private func sealAndSend(_ message: LampAgentRemoteMessage) -> Bool {
        let effects = session?.seal(message) ?? []
        guard !effects.isEmpty else { return false }
        perform(effects)
        return true
    }

    static let unsealable = "It couldn’t be sent: it may be too long, or the connection has closed."

    // MARK: - What the panel asks for

    /// Opens a chat. `carryingDraftFrom` is the new-chat key whose draft goes
    /// with it: what was written for a writing before it had a chat.
    func open(_ chatID: String, carryingDraftFrom newChatKey: String? = nil) {
        // A new chat on its way opens itself when it comes.
        guard !isStartingChat else { return }
        listProblem = nil
        if let newChatKey { moveDraft(from: newChatKey, to: chatID) }
        openChatID = chatID
        chat = nil
        let request = LampAgentRemoteMessage.openChat(chatID)
        openRequest = request.requestID
        seal(request)
    }

    func closeChat() {
        if let openChatID { seal(.closeChat(openChatID)) }
        chat = nil
        openChatID = nil
        seal(.listChats())
    }

    /// Sends a message in the open chat. Returns whether the words were
    /// taken, sent or kept as not sent, so the composer clears only then.
    @discardableResult
    func send(
        _ text: String,
        reading: LampAgentRemoteReading?,
        selection: String? = nil,
        writingRevision: Int? = nil,
        writingDigest: String? = nil,
        inChat chatID: String? = nil
    ) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Meant for one chat, after a pause: not sent to another opened since.
        if let chatID, chat?.id != chatID { return false }
        // One at a time: until the Mac starts the turn, or refuses it, the
        // last message is still on its way.
        // A message that didn't go is sent again or edited first, so one
        // refused can't be lost under the next.
        guard let chat, !words.isEmpty, !chat.isRunning, chat.sending == nil, unsent[chat.id] == nil,
              !sendRequests.values.contains(where: { $0.chatID == chat.id }) else { return false }
        let request = LampAgentRemoteMessage.send(
            words, to: chat.id, reading: reading, selection: selection,
            writingRevision: writingRevision, writingDigest: writingDigest
        )
        let known = Set(chat.messages.map(\.id))
        guard sealAndSend(request) else {
            unsent[chat.id] = Unsent(
                words: words, problem: Self.unsealable, known: known, reading: reading,
                selection: selection, writingRevision: writingRevision, writingDigest: writingDigest
            )
            return true
        }
        if let requestID = request.requestID {
            sendRequests[requestID] = (chat.id, words, known, reading, selection)
            requestRevisions[requestID] = writingRevision
            requestDigests[requestID] = writingDigest
        }
        self.chat?.sending = words
        self.chat?.requestProblem = nil
        return true
    }

    /// Sends a message that didn't go, again: in its chat, which must be the
    /// one open, or as a new chat's first message.
    /// `writingRevision` is the writing's revision now, for a message about
    /// one: the Mac checks its copy is as new before working on it.
    func resend(_ key: String, reading: LampAgentRemoteReading?, writingRevision: Int? = nil, writingDigest: String? = nil) {
        guard let kept = unsent[key], kept.startsChat || chat?.id == key else { return }
        // At least the revision it was first sent with, whichever panel
        // retries, with the digest that goes with the one used.
        let useKept = (kept.writingRevision ?? .min) > (writingRevision ?? .min)
        let writingDigest = useKept ? kept.writingDigest : (writingDigest ?? kept.writingDigest)
        let writingRevision = [writingRevision, kept.writingRevision].compactMap { $0 }.max()
        let isNewChat = kept.startsChat
        // Taken out first, as sending needs; put back if it fails again.
        unsent[key] = nil
        if isNewChat, let writingID = kept.writingID, let chat,
           chat.summary.writingID?.caseInsensitiveCompare(writingID) == .orderedSame {
            // The writing's chat is open now: the question goes on in it.
            // Refused here (another message is on its way, or waits), the
            // question stays where it was.
            if !send(kept.words, reading: nil, selection: kept.selection, writingRevision: writingRevision, writingDigest: writingDigest), unsent[key] == nil {
                unsent[key] = kept
            }
        } else if isNewChat {
            if let writingID = kept.writingID {
                startWritingChat(kept.words, writingID: writingID, selection: kept.selection, writingRevision: writingRevision, writingDigest: writingDigest)
            } else {
                startChat(kept.words, reading: kept.reading ?? reading ?? LampAgentRemoteReading())
            }
            if startRequest == nil, unsent[key] == nil { unsent[key] = kept }
        } else {
            send(kept.words, reading: kept.reading ?? reading, selection: kept.selection, writingRevision: writingRevision, writingDigest: writingDigest)
            if sendRequests.values.contains(where: { $0.chatID == key }) == false, unsent[key] == nil { unsent[key] = kept }
        }
    }

    /// Takes a message that didn't go out of the chat, to be edited, with the
    /// words chosen in the writing that went with it.
    func takeUnsent(_ key: String) -> Unsent? {
        defer { unsent[key] = nil }
        return unsent[key]
    }

    func cancel() {
        guard let chat else { return }
        seal(.cancel(chat.id))
    }

    #if DEBUG
    /// For looking at the panel in the simulator, which has no Mac to find:
    /// launch with `-AgentRemoteDemo list`, `chat`, `unsent`, `pair`,
    /// `writing-start` or `writing-chat`.
    private func showDemo(_ demo: String) {
        let now = Date()
        let summaries = [
            LampAgentRemoteChatSummary(
                id: "demo-1", title: "Romans 5", subtitle: "Romans 5:20", kind: LampAgentRemoteChatSummary.reader,
                provider: "claude", providerName: "Claude", updatedAt: now.addingTimeInterval(-600),
                preview: "Where sin increased, grace abounded all the more: Paul's word is a strong one.",
                isRunning: true, acceptsMessages: true
            ),
            LampAgentRemoteChatSummary(
                id: "demo-2", title: "Isaiah 53", subtitle: "Isaiah 53:5", kind: LampAgentRemoteChatSummary.reader,
                provider: "codex", providerName: "Codex", updatedAt: now.addingTimeInterval(-86_400 * 2),
                preview: "The servant is pierced for our transgressions.", acceptsMessages: true
            ),
        ]
        switch demo {
        case "pair":
            phase = .needsCode(host: "Study Mac", notice: nil)
        case "chat":
            phase = .connected("Study Mac")
            chats = summaries
            openChatID = "demo-1"
            chat = AgentRemoteChat(LampAgentRemoteChatSnapshot(
                summary: summaries[0],
                messages: [
                    LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "Why does Paul say grace *abounded*?", date: now.addingTimeInterval(-700)),
                    LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.assistant, text: "Paul uses **hyperperisseuō**, “to overflow beyond measure.” Where the law made sin plain, grace did not merely keep pace: it surpassed it.", date: now.addingTimeInterval(-690)),
                    LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "How does that connect to chapter 6?", date: now.addingTimeInterval(-620)),
                ],
                partialReply: "Chapter 6 opens with the question this raises: “Are we to continue in sin that grace may abound?”",
                activity: LampAgentRemoteActivity(kind: LampAgentRemoteActivity.tool, name: "read passage", summary: "Romans 6:1-4")
            ))
        case "writing-start":
            phase = .connected("Study Mac")
            chats = summaries
        case "writing-chat":
            phase = .connected("Study Mac")
            let summary = LampAgentRemoteChatSummary(
                id: "demo-w", title: "Tighten the opening paragraph", subtitle: "John 10: The Shepherd Who Knows His Sheep",
                kind: LampAgentRemoteChatSummary.writing, writingID: "demo", provider: "claude", providerName: "Claude",
                updatedAt: now.addingTimeInterval(-300), acceptsMessages: true
            )
            chats = summaries + [summary]
            demoWritingChat = true
            openChatID = "demo-w"
            chat = AgentRemoteChat(LampAgentRemoteChatSnapshot(
                summary: summary,
                messages: [
                    LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "Tighten the opening paragraph.", date: now.addingTimeInterval(-320)),
                    LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.assistant, text: "I cut the opening to two sentences and moved the quotation of John 10:14 to the start, so the paragraph begins with the Shepherd’s own words.", date: now.addingTimeInterval(-300)),
                ]
            ))
        case "unsent":
            phase = .connected("Study Mac")
            chats = summaries
            openChatID = "demo-2"
            chat = AgentRemoteChat(LampAgentRemoteChatSnapshot(
                summary: summaries[1],
                messages: [
                    LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "Who is the servant here?", date: now.addingTimeInterval(-900)),
                    LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.assistant, text: "Isaiah leaves the servant unnamed in 53; the New Testament reads him as *Jesus* (Acts 8:35).", date: now.addingTimeInterval(-880)),
                ]
            ))
            unsent["demo-2"] = Unsent(
                words: "And what does “by his wounds” mean?",
                problem: AgentRemoteFailureText.text(code: LampAgentRemoteFailure.needsSetup, message: nil)
            )
        default:
            phase = .connected("Study Mac")
            chats = summaries
        }
    }
    #endif

    /// Starts a chat with its first message. Returns whether the words were
    /// taken, as `send` does.
    @discardableResult
    func startChat(_ text: String, reading: LampAgentRemoteReading) -> Bool {
        start(text, key: Self.newChatKey, reading: reading, writingID: nil, selection: nil) { words in
            LampAgentRemoteNewChat(reading: reading, firstMessage: words)
        }
    }

    /// Asks the assistant about a writing, with the words chosen in it. The
    /// Mac goes on in the writing's chat if it has one, and its snapshot
    /// shows what was said before.
    @discardableResult
    func startWritingChat(_ text: String, writingID: String, selection: String?, writingRevision: Int? = nil, writingDigest: String? = nil) -> Bool {
        start(text, key: Self.newChatKey(writing: writingID), reading: nil, writingID: writingID, selection: selection, writingRevision: writingRevision, writingDigest: writingDigest) { words in
            .writing(writingID, firstMessage: words, selection: selection, writingRevision: writingRevision, writingDigest: writingDigest)
        }
    }

    private func start(
        _ text: String,
        key: String,
        reading: LampAgentRemoteReading?,
        writingID: String?,
        selection: String?,
        writingRevision: Int? = nil,
        writingDigest: String? = nil,
        newChat: (String) -> LampAgentRemoteNewChat
    ) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !isStartingChat, unsent[key] == nil else { return false }
        let request = LampAgentRemoteMessage.startChat(newChat(words))
        guard sealAndSend(request) else {
            keepForNewChat(Unsent(
                words: words, problem: Self.unsealable, reading: reading, selection: selection,
                writingID: writingID, writingRevision: writingRevision, writingDigest: writingDigest
            ), key: key)
            return true
        }
        if let requestID = request.requestID {
            requestRevisions[requestID] = writingRevision
            requestDigests[requestID] = writingDigest
            startRequest = StartRequest(
                id: requestID, words: words, known: [], reading: reading,
                key: key, writingID: writingID, selection: selection
            )
        }
        isStartingChat = true
        listProblem = nil
        return true
    }

    /// The writing each chat seen on this Mac is about, kept when a list
    /// later leaves the chat out, as one deleted while disconnected.
    private var chatWritings: [String: String] = [:]

    /// The writing a chat is about, if it's a writing's.
    private func writingID(ofChat id: String) -> String? {
        if chat?.id == id, let writingID = chat?.summary.writingID { return writingID }
        return chats.first { $0.id == id }?.writingID ?? chatWritings[id]
    }

    private func noteWritings(_ summaries: [LampAgentRemoteChatSummary]) {
        for summary in summaries {
            if let writingID = summary.writingID { chatWritings[summary.id] = writingID }
        }
    }

    /// The writing's chat on the Mac, if it has one.
    func chatSummary(forWriting writingID: String) -> LampAgentRemoteChatSummary? {
        #if DEBUG
        // The demo's writing chat stands for whichever writing is open.
        if demoWritingChat, let demo = chats.first(where: { $0.id == "demo-w" }) { return demo }
        #endif
        return chats.first { $0.writingID?.caseInsensitiveCompare(writingID) == .orderedSame }
    }

    #if DEBUG
    private var demoWritingChat = false
    #endif
}
