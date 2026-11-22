import Combine
import Foundation
import LampCore
import Network
import UIKit
import UserNotifications

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
    /// Turns waited for in other chats are followed by the list.
    @Published private(set) var openChatID: String? {
        didSet { if openChatID != oldValue { followAwaited() } }
    }
    @Published private(set) var isStartingChat = false
    /// What went wrong with a request made from the list.
    @Published private(set) var listProblem: String?
    /// The Macs paired: the iCloud subscription names their pairings.
    @Published private(set) var rememberedHosts: [LampAgentRemoteRememberedHost] {
        didSet { if rememberedHosts.map(\.deviceID) != oldValue.map(\.deviceID) { AgentTurnPush.refresh() } }
    }
    /// Set when someone asks to choose another Mac, so a single one found
    /// isn't connected to again on its own.
    @Published private(set) var choosingHost = false
    /// A message that didn't go: refused by the Mac, or caught by the
    /// connection ending. Kept with the chat it was for, so it can be sent
    /// again or edited rather than typed again.
    struct Unsent: Equatable {
        let words: String
        var problem: String
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

    /// Moves what was kept with no Mac known to be `secret`'s, where it has
    /// nothing of its own for the same destination.
    private static func adopt(_ kept: inout [String: String], as secret: String) {
        for (key, value) in kept where key.hasPrefix("|") {
            kept[key] = nil
            let mine = secret + key
            if kept[mine] == nil { kept[mine] = value }
        }
    }

    /// The words chosen in a writing that go with the next message, kept as
    /// drafts are, so a selection never crosses to another writing's chat.
    @Published private var selections: [String: String] = [:]

    func selection(for destination: String) -> String? {
        selections["\(chatsHostSecret ?? "")|\(destination)"]
    }

    func setSelection(_ text: String?, for destination: String) {
        selections["\(chatsHostSecret ?? "")|\(destination)"] = text?.isEmpty == false ? text : nil
    }

    /// Moves what was written for one destination to another, joined to what
    /// is there.
    private func moveDraft(from source: String, to destination: String) {
        guard source != destination else { return }
        // The chosen words go too, with or without words written to them,
        // and in place of any kept there: they were chosen since.
        if let chosen = selection(for: source) {
            setSelection(nil, for: source)
            setSelection(chosen, for: destination)
        }
        let moving = draft(for: source)
        guard !moving.isEmpty else { return }
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

    /// A turn this device asked for, still running on the Mac, to tell the
    /// person of when it ends out of their sight (`AgentTurnNotifications`).
    struct AwaitedTurn: Equatable {
        var title: AgentTurnNotifications.Title
        var route: AgentTurnRoute
        /// The reply as saved, once the Mac has sent it.
        var reply: String?
        /// What went wrong, when the Mac said.
        var failure: String?
        /// The question the turn began with, whose reply is the one to tell.
        var turnID: UUID?
        /// The pairing it was asked under, whose Mac's pushes are known or not.
        var deviceID: String?
        let since: Date
    }
    /// By chat id. While any is running the connection stays, with no panel
    /// showing, and Lamp asks iOS for time to hear it end once it's left.
    private(set) var awaited: [String: AwaitedTurn] = [:]
    /// How long a turn is waited for before it's taken as never ending.
    static let awaitedLimit: TimeInterval = 2 * 60 * 60
    /// How often the list is asked for while a turn waited for runs in a
    /// chat other than the one open, whose events the Mac doesn't send.
    static let awaitedListInterval: TimeInterval = 10
    private var awaitedListTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []

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
                    if !enabled { self?.awaited = [:]; self?.stop() }
                }
            }
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredBackground() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameActive() }
            },
        ]
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
        lastNeeded = Date()
        stopIfUnneeded()
    }

    /// Ends the connection once nothing needs it: no panel showing, and no
    /// turn this device asked for still to be heard ending.
    private func stopIfUnneeded() {
        dropStaleAwaited()
        guard panelsShowing == 0, awaited.isEmpty else {
            lastNeeded = Date()
            return
        }
        // A question still on its way: the Mac may begin its turn yet, so the
        // connection waits for its answer, a while at most.
        let asking = startRequest != nil || !sendRequests.isEmpty
        if asking, AgentTurnNotifications.isEnabledNow, Date().timeIntervalSince(lastNeeded) < Self.askingWait {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { self?.stopIfUnneeded() }
            }
            return
        }
        stop()
    }

    /// When a panel or a turn last needed the connection.
    private var lastNeeded = Date()
    /// How long a question sent as its panel closed holds the connection
    /// for the Mac to begin its turn.
    static let askingWait: TimeInterval = 60

    /// The reader chat a tapped notification asked for: opened now, or once
    /// a connection has come, by the Chat panel the reader shows.
    func show(chatID: String) {
        if case .connected = phase, chat?.id != chatID {
            open(chatID)
        } else if chat?.id != chatID {
            openChatID = chatID
            chat = nil
        }
    }

    // MARK: - Turns this device waits for

    /// A turn this device asked for began in `chatID`.
    private func awaitTurn(in chatID: String, turnID: UUID?) {
        guard AgentTurnNotifications.isEnabledNow else { return }
        let summary = chats.first(where: { $0.id == chatID }) ?? (chat?.id == chatID ? chat?.summary : nil)
        guard let summary else { return }
        awaited[chatID] = AwaitedTurn(
            title: AgentTurnNotifications.title(of: summary),
            route: AgentTurnNotifications.route(of: summary),
            turnID: turnID,
            deviceID: rememberedHosts.first(where: { $0.hostSecret == chatsHostSecret })?.deviceID,
            since: Date()
        )
        if UIApplication.shared.applicationState == .background { holdForAwaited() }
        followAwaited()
    }

    /// The turn waited for in `chatID` ended: told, unless its chat is on
    /// screen. `preview` is the list's last words, for a turn whose end was
    /// learned from the list rather than heard.
    /// The turn waited for in `chatID` ended: told, unless its chat is on
    /// screen. A reply is quoted only when it's known to answer the turn's
    /// question: heard as it came, or after that question in the chat open.
    /// Learned from the list, which says only that nothing is running, the
    /// notification says no more than that it finished.
    private func awaitedTurnEnded(in chatID: String, learnedFromList: Bool = false) {
        guard let turn = awaited.removeValue(forKey: chatID) else { return }
        let pushedAlready = hasHeard(chatID: chatID, turnID: turn.turnID?.uuidString)
        let watched = UIApplication.shared.applicationState == .active && panelsShowing > 0 && chat?.id == chatID
        if !watched, !pushedAlready {
            let open = chat?.id == chatID ? chat : nil
            let outcome: AgentTurnNotifications.Outcome
            // The chat's notice is this turn's only while no later turn began.
            let notice = turn.reply == nil && !Self.isSuperseded(turn.turnID, in: open?.messages ?? []) ? open?.view.notice : nil
            if let failure = turn.failure ?? notice {
                outcome = .failed(failure)
            } else if let reply = turn.reply ?? open.flatMap({ Self.reply(to: turn.turnID, in: $0.messages) }) {
                outcome = .replied(reply)
            } else {
                // How it ended isn't known here: the list says only that
                // nothing runs, and a turn stopped before any words has no
                // reply. The Mac's push, if it comes, says.
                outcome = .finished
            }
            postUnlessPushed(outcome, turn: turn, chatID: chatID)
        } else {
            noteHeard(chatID: chatID, turnID: turn.turnID?.uuidString)
        }
        followAwaited()
        // After what's being handled now: the connection may end with it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopIfUnneeded()
                if self.awaited.isEmpty { self.releaseBackgroundTime() }
            }
        }
    }

    /// Whether an event is of the turn waited for: by the turn it names,
    /// where both are known.
    nonisolated static func isSameTurn(_ awaited: UUID?, _ event: UUID?) -> Bool {
        guard let awaited, let event else { return true }
        return awaited == event
    }

    /// Whether a question asked after `turnID` shows its turn is over, the
    /// chat having gone on to another while this device wasn't following.
    nonisolated static func isSuperseded(_ turnID: UUID?, in messages: [LampAgentRemoteChatMessage]) -> Bool {
        guard let turnID, let asked = messages.firstIndex(where: { $0.id == turnID }) else { return false }
        return messages[messages.index(after: asked)...].contains { $0.role == LampAgentRemoteChatMessage.user }
    }

    /// The assistant's reply to the question `turnID`, if the chat has one
    /// after it.
    static func reply(to turnID: UUID?, in messages: [LampAgentRemoteChatMessage]) -> String? {
        guard let turnID, let asked = messages.firstIndex(where: { $0.id == turnID }) else { return nil }
        return messages[messages.index(after: asked)...]
            .prefix { $0.role != LampAgentRemoteChatMessage.user }
            .last { $0.role == LampAgentRemoteChatMessage.assistant }?.text
    }

    /// The last turn heard ending in each chat, this device's own, or shown
    /// by iCloud's push, so the same turn isn't told twice.
    private var heard: [String: (turnID: String?, at: Date)] = [:]

    func noteHeard(chatID: String, turnID: String?) {
        heard[chatID] = (turnID, Date())
    }

    /// Posts the turn's notification, unless iCloud's push of it has been
    /// shown since the turn began, while Lamp wasn't there to see it come:
    /// the push says how it ended, which this may not know.
    /// Heard, for the push of the same turn, only once this has posted, and
    /// only when it says how the turn ended: a push that does still shows.
    private func postUnlessPushed(_ outcome: AgentTurnNotifications.Outcome, turn: AwaitedTurn, chatID: String) {
        // Held until the notification is with the system: with Lamp left,
        // iOS would otherwise suspend it between the look and the post.
        let hold = BackgroundHold(name: "Agent turn alert")
        let release: @Sendable () -> Void = { hold.end() }
        UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] delivered in
            for shown in delivered {
                if let pushed = AgentTurnPush.turn(fromPush: shown.request.content.userInfo) {
                    AgentTurnPush.notePushSeen(from: pushed.deviceID)
                }
            }
            // A push is shown under an identifier of iOS's own: known by what
            // it carries.
            let pushed = delivered.contains { shown in
                guard shown.date >= turn.since,
                      let pushed = AgentTurnPush.turn(fromPush: shown.request.content.userInfo),
                      pushed.chatID == chatID else { return false }
                // A late push of the chat's turn before isn't this one's.
                guard let mine = turn.turnID?.uuidString, let theirs = pushed.turnID else { return true }
                return mine.caseInsensitiveCompare(theirs) == .orderedSame
            }
            guard !pushed else { return release() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // With Lamp left, and this Mac's pushes known to come, its
                    // push of this turn tells: two would alert twice, as iOS
                    // can't fold a push into a notification already shown.
                    if UIApplication.shared.applicationState == .background, AgentTurnPush.isSubscribed,
                       let deviceID = turn.deviceID, AgentTurnPush.pushSeen(from: deviceID) {
                        return release()
                    }
                    if outcome != .finished { self?.noteHeard(chatID: chatID, turnID: turn.turnID?.uuidString) }
                    AgentTurnNotifications.post(
                        outcome, title: turn.title, route: turn.route, chatID: chatID, completion: release
                    )
                }
            }
        }
    }
    /// How long a turn heard ending stands for a push of the same chat that
    /// names no turn, or one from a Mac that names it otherwise.
    static let heardWindow: TimeInterval = 10 * 60

    /// Whether a push telling of a turn in `chatID` says nothing new: the
    /// turn was heard ending here, or the chat is on screen now.
    func hasHeard(chatID: String, turnID: String?) -> Bool {
        if UIApplication.shared.applicationState == .active, panelsShowing > 0, chat?.id == chatID,
           case .connected = phase {
            return true
        }
        guard let last = heard[chatID] else { return false }
        if let turnID, let heardID = last.turnID {
            return turnID.caseInsensitiveCompare(heardID) == .orderedSame
        }
        return Date().timeIntervalSince(last.at) < Self.heardWindow
    }

    private func dropStaleAwaited() {
        let now = Date()
        awaited = awaited.filter { now.timeIntervalSince($0.value.since) < Self.awaitedLimit }
    }

    /// Asks for the list now and then while a turn waited for runs in a chat
    /// other than the one open: the Mac sends events for the open one only.
    /// Kept running while any turn is waited for, which also lets one that
    /// outlives `awaitedLimit` go, and the connection with it.
    private func followAwaited() {
        guard !awaited.isEmpty else {
            awaitedListTimer?.invalidate()
            awaitedListTimer = nil
            return
        }
        guard awaitedListTimer == nil else { return }
        awaitedListTimer = Timer.scheduledTimer(withTimeInterval: Self.awaitedListInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dropStaleAwaited()
                guard !self.awaited.isEmpty else {
                    self.followAwaited()
                    self.releaseBackgroundTime()
                    self.stopIfUnneeded()
                    return
                }
                switch self.phase {
                case .connected:
                    if self.awaited.keys.contains(where: { $0 != self.openChatID }) { self.seal(.listChats()) }
                // Lost while a turn is waited for: found again once the
                // network's back, in Lamp, without waiting to come back to it.
                case .stopped, .unavailable:
                    if UIApplication.shared.applicationState == .active { self.reconnectIfLost(promptly: false) }
                default:
                    break
                }
            }
        }
    }

    /// What the list says of the turns waited for.
    private func checkAwaited(against summaries: [LampAgentRemoteChatSummary]) {
        for summary in summaries where awaited[summary.id] != nil && !summary.isRunning {
            awaitedTurnEnded(in: summary.id, learnedFromList: true)
        }
        // Gone from the Mac's list: deleted there, with nothing to tell. An
        // empty list says more of the Mac (its library not open) than of
        // the chat, and retires nothing.
        let listed = Set(summaries.map(\.id))
        let gone = awaited.keys.filter { !listed.contains($0) }
        guard !summaries.isEmpty, !gone.isEmpty else { return }
        for chatID in gone { awaited[chatID] = nil }
        followAwaited()
        if awaited.isEmpty { releaseBackgroundTime() }
        stopIfUnneeded()
    }

    private func enteredBackground() {
        // A ping unanswered by now isn't judged while Lamp is away: its
        // background time is for hearing a turn end.
        probe = nil
        dropStaleAwaited()
        // A question still on its way may begin a turn to wait for.
        let asking = AgentTurnNotifications.isEnabledNow && (startRequest != nil || !sendRequests.isEmpty)
        if !awaited.isEmpty || asking { holdForAwaited() }
    }

    /// Back in Lamp with a turn still waited for: to hear how it ended, the
    /// connection comes back, panel or not.
    /// When a lost connection was last made again without asking.
    private var lastLossRetry = Date.distantPast
    static let lossRetryInterval: TimeInterval = 30

    private func becameActive() {
        releaseBackgroundTime()
        dropStaleAwaited()
        // Back in Lamp with a chat on screen or a turn waited for: the
        // connection may have ended while Lamp was away, which a word to the
        // Mac shows at once rather than at the next message.
        guard !awaited.isEmpty || panelsShowing > 0 else { return }
        switch phase {
        case .connected:
            probeConnection()
            if !awaited.isEmpty { seal(.listChats()) }
        default:
            reconnectIfLost()
        }
    }

    /// Whether the last connection was ended by the network rather than by
    /// the Mac's word (remote chats off, this device turned away), so it's
    /// made again on its own, to the same Mac, never another one found.
    private var lostRecoverably = false
    /// Browsing to find the Mac a lost connection was to, and only it.
    private var rediscoveringLast = false
    /// Its name, as browsing finds Macs.
    private var recoveryTarget: String?
    /// The search under way, whose time limit is its own.
    private var recoveryAttempt: UUID?
    /// The secret of the Mac being found again: a Mac of the same name that
    /// proves another secret isn't it, and isn't connected to in its place.
    private var recoverySecret: String?
    /// The Mac last connected to, by name and proven secret.
    private var lastConnected: (name: String, secret: String)?
    /// For finding the Mac and connecting to it, handshake and all.
    static let rediscoveryWait: TimeInterval = 15

    /// Looks for the Mac a lost connection was to by browsing, as it may be
    /// at another address now, and connects to it alone, never another that
    /// happens to show. Not found in a while, the loss is said again, with
    /// Try Again and Choose Another Mac.
    private func rediscover() {
        guard let target = host?.name else { return }
        rediscoveringLast = true
        recoveryTarget = target
        // Checked only against a Mac this device was connected to under this
        // name: a first connection that never got through proves nothing.
        recoverySecret = lastConnected?.name == target ? lastConnected?.secret : nil
        let attempt = UUID()
        recoveryAttempt = attempt
        browse()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rediscoveryWait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rediscoveringLast, self.recoveryAttempt == attempt else { return }
                // Only while still looking or connecting: found and answered,
                // asking for a code, or already said to have failed (no Local
                // Network access, another version), the search is over.
                switch self.phase {
                case .searching, .connecting: break
                default: return
                }
                // Not found, or found but not answering: said, with the
                // buttons, rather than left turning.
                self.rediscoveringLast = false
                self.browser?.cancel()
                self.browser = nil
                self.teardown()
                self.lostRecoverably = true
                self.phase = .unavailable("\(target) couldn\u{2019}t be reached. Check it\u{2019}s open and on the same network.")
            }
        }
    }

    /// `promptly` on coming back to Lamp; otherwise, as from the waited
    /// turn's timer, no oftener than `lossRetryInterval`, so a Mac that stays
    /// away leaves its message and buttons up between tries.
    private func reconnectIfLost(promptly: Bool = true) {
        switch phase {
        case .unavailable:
            guard lostRecoverably,
                  promptly || Date().timeIntervalSince(lastLossRetry) > Self.lossRetryInterval else { return }
            lastLossRetry = Date()
            rediscover()
        case .stopped:
            start()
        default:
            break
        }
    }

    /// The ping asked since coming back, unanswered: a connection iOS ended
    /// while Lamp was away can look open until something is sent on it.
    private var probe: UUID?
    /// Pings sent on this connection and not yet answered. Pongs come back
    /// in order, so the probe is answered only by the last ping's: an
    /// earlier one, delivered late, leaves it waiting.
    private var pingsOutstanding = 0
    private weak var pingedConnection: NWConnection?
    static let probeWait: TimeInterval = 5

    private func probeConnection() {
        guard case .connected = phase, let watched = connection else { return }
        let id = UUID()
        probe = id
        if pingedConnection !== watched {
            pingedConnection = watched
            pingsOutstanding = 0
        }
        pingsOutstanding += 1
        seal(.ping)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeWait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.probe == id, self.connection === watched else { return }
                self.probe = nil
                // No word back: lost, and made again as any loss is.
                watched.cancel()
                self.connection = nil
                self.perform(self.session?.closed(byHost: false, reason: nil) ?? [])
            }
        }
    }

    /// The time iOS gives an app it has left to finish, used to hear a turn
    /// end: half a minute or so, after which Lamp is suspended.
    private func holdForAwaited() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Agent turn") { [weak self] in
            MainActor.assumeIsolated { self?.releaseBackgroundTime() }
        }
    }

    private func releaseBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
        rediscoveringLast = false
        lostRecoverably = false
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
        // The person's choice now, not the lost connection's.
        lostRecoverably = false
        rediscoveringLast = false
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
        awaited = [:]
        releaseBackgroundTime()
        chats = []
        chat = nil
        openChatID = nil
        // What was written for this Mac goes with it; other Macs' stays.
        unsent = [:]
        parkedUnsent[secret] = nil
        drafts = drafts.filter { !$0.key.hasPrefix(secret + "|") }
        selections = selections.filter { !$0.key.hasPrefix(secret + "|") }
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
        if rediscoveringLast {
            if let match = hosts.first(where: { $0.name == recoveryTarget }) { connect(to: match, automatic: true) }
            return
        }
        if let match = hosts.first(where: { $0.name == last }) ?? (hosts.count == 1 ? hosts.first : nil) {
            connect(to: match)
        }
    }

    // MARK: - Connecting

    /// `automatic` for recovery's own connection; any other, the person's
    /// choice, ends recovery, its deadline and its check of which Mac it is.
    func connect(to host: Host, pendingCode: String? = nil, automatic: Bool = false) {
        if !automatic {
            rediscoveringLast = false
            recoverySecret = nil
        }
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
        // A code entered is a pairing the person chose: recovery's over.
        rediscoveringLast = false
        recoverySecret = nil
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
                // Found again by name, but proven to be another Mac: not
                // taken for the one that was lost, nor its chats dropped.
                if rediscoveringLast, let expected = recoverySecret, let secret = session?.hostSecret, secret != expected {
                    rediscoveringLast = false
                    teardown()
                    lostRecoverably = false
                    // Not tried again by Try Again: which Mac is the person's
                    // to choose, from those found.
                    self.host = nil
                    choosingHost = true
                    phase = .unavailable("Another Mac answered as \(host.name). Choose the Mac to use.")
                    // Nothing more this connection said is taken in.
                    return
                }
                if let secret = session?.hostSecret {
                    if chatsHostSecret != secret {
                        // Another Mac's chats aren't this one's. What wasn't
                        // sent to it waits for it; drafts are kept by Mac.
                        if let earlier = chatsHostSecret {
                            parkedUnsent[earlier] = unsent
                            unsent = [:]
                            // Another Mac's turns, which this one can't tell of.
                            awaited = [:]
                            followAwaited()
                            chatWritings = [:]
                            chats = []
                            chat = nil
                            openChatID = nil
                            listProblem = nil
                        }
                        if let parked = parkedUnsent.removeValue(forKey: secret) {
                            unsent.merge(parked) { current, _ in current }
                        }
                        // Written before any Mac was known (the first opening
                        // after launch): this Mac's, as the first one reached.
                        if chatsHostSecret == nil {
                            Self.adopt(&drafts, as: secret)
                            Self.adopt(&selections, as: secret)
                        }
                    }
                    chatsHostSecret = secret
                }
                phase = .connected(host.name)
                if let secret = session?.hostSecret { lastConnected = (host.name, secret) }
                lostRecoverably = false
                rediscoveringLast = false
                UserDefaults.standard.set(host.name, forKey: Self.lastHostKey)
                rememberedHosts = memory.hosts
                // Back where this device was before the connection dropped.
                if let openChatID {
                    let request = LampAgentRemoteMessage.openChat(openChatID)
                    openRequest = request.requestID
                    seal(request)
                }
                // How the turns waited for went while it was down.
                if !awaited.isEmpty { seal(.listChats()) }
            case let .received(message):
                handle(message)
            case .pairAgain:
                pendingNotice = AgentRemoteProblemText.refused
                // Recovery's own retry stays recovery's: no one chose anew.
                if let host { connect(to: host, automatic: rediscoveringLast) } else { teardown(); phase = .unavailable(AgentRemoteProblemText.refused) }
            case let .failed(problem):
                // Not reached is the network's doing; turned away is the Mac's.
                if case .unreachable = problem { lostRecoverably = true } else { lostRecoverably = false }
                teardown()
                phase = .unavailable(AgentRemoteProblemText.text(problem))
            case .lost:
                teardown()
                // Lost while Lamp was away, as iOS ends a suspended app's
                // connections, and found so once someone's looking again:
                // connected again without asking, once in a while; a second
                // loss soon after is said, as the Mac may really be gone.
                let wanted = panelsShowing > 0 || !awaited.isEmpty
                if closingReason == nil, wanted, UIApplication.shared.applicationState == .active,
                   Date().timeIntervalSince(lastLossRetry) > Self.lossRetryInterval, let host {
                    lastLossRetry = Date()
                    lostRecoverably = true
                    phase = .unavailable("The connection to \(host.name) was lost.")
                    // After what's being handled now, which was the old
                    // connection's.
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            // Still wanted: not stopped, nor connected by hand, meanwhile.
                            guard let self, case .unavailable = self.phase, self.lostRecoverably,
                                  self.panelsShowing > 0 || !self.awaited.isEmpty else { return }
                            self.rediscover()
                        }
                    }
                    break
                }
                // Ended by the network, not the Mac's word: worth making again
                // on coming back, to the same Mac.
                lostRecoverably = closingReason == nil
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
            checkAwaited(against: chats)
        case .snapshot:
            guard let snapshot = message.snapshot else { return }
            let started = message.requestID != nil && message.requestID == startRequest?.id
            guard started || snapshot.summary.id == openChatID else { return }
            // This device's requests, before what the snapshot settles of them
            // takes them out below.
            let ours = Set(sendRequests.keys).union(unsent.values.compactMap(\.requestID))
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
            followAwaited()
            if let turn = awaited[snapshot.summary.id],
               !snapshot.summary.isRunning || Self.isSuperseded(turn.turnID, in: snapshot.messages) {
                awaitedTurnEnded(in: snapshot.summary.id)
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
            // A Mac that names the request each question came with settles
            // what the connection ending left unsure: named, it went. Older
            // Macs say nothing, and the note stays.
            if let askedBy = snapshot.askedBy {
                let went = Set(askedBy.map(\.requestID))
                // This device's question, its turn still running, its start
                // missed while the connection was down: waited for now.
                if snapshot.summary.isRunning, awaited[id] == nil,
                   let last = snapshot.messages.last(where: { $0.role == LampAgentRemoteChatMessage.user }),
                   let asked = askedBy.first(where: { $0.messageID == last.id }), ours.contains(asked.requestID) {
                    awaitTurn(in: id, turnID: last.id)
                }
                for (key, kept) in unsent where kept.requestID.map(went.contains) == true {
                    unsent[key] = nil
                }
                for requestID in went {
                    if let request = sendRequests.removeValue(forKey: requestID), chat?.id == request.chatID {
                        chat?.sending = nil
                    }
                }
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
                if event.kind == LampAgentRemoteChatEvent.turnStarted, !arrived.isEmpty {
                    awaitTurn(in: event.chatID, turnID: event.turnID ?? asked.id)
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
            if let turn = awaited[event.chatID], Self.isSameTurn(turn.turnID, event.turnID) {
                if event.kind == LampAgentRemoteChatEvent.reply, let said = event.message,
                   said.role == LampAgentRemoteChatMessage.assistant {
                    awaited[event.chatID]?.reply = said.text
                } else if event.kind == LampAgentRemoteChatEvent.failed {
                    awaited[event.chatID]?.failure = event.text ?? "Something went wrong on your Mac."
                }
            }
            if let index = chats.firstIndex(where: { $0.id == event.chatID }) {
                if event.kind == LampAgentRemoteChatEvent.turnStarted { chats[index].isRunning = true }
                if event.kind == LampAgentRemoteChatEvent.turnEnded {
                    chats[index].isRunning = false
                    // What the assistant changed in a writing comes by sync:
                    // start a pass now rather than wait for the next.
                    if chats[index].writingID != nil {
                        SyncCoordinator.shared.syncAfterChange()
                    }
                }
            }
            if event.kind == LampAgentRemoteChatEvent.turnEnded,
               let turn = awaited[event.chatID], Self.isSameTurn(turn.turnID, event.turnID) {
                awaitedTurnEnded(in: event.chatID)
            }
        case .failed:
            failed(message)
        case .pong:
            // The Mac answered the ping sent on coming back: alive. Nothing
            // read before it proves that, as it may have waited in a buffer,
            // nor a pong to an earlier ping.
            if pingedConnection === connection, pingsOutstanding > 0 {
                pingsOutstanding -= 1
                if pingsOutstanding == 0 { probe = nil }
            }
        default:
            // `accepted` is the session's; anything else is a kind a later
            // Lamp knows.
            break
        }
    }

    private func failed(_ message: LampAgentRemoteMessage) {
        let text = AgentRemoteFailureText.text(code: message.errorCode, message: message.errorMessage)
        if message.errorCode == LampAgentRemoteFailure.aiOff {
            lostRecoverably = false
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

    /// A message about a writing kept as not sent before it went: its
    /// revision couldn't be read here, and the Mac would take one without it
    /// as from an older phone and not check its own copy.
    /// `known` is the chat's messages when it was asked, taken before the
    /// stamp was looked for.
    func keepUnstamped(_ words: String, selection: String?, writingID: String, key: String, startsChat: Bool, known: Set<UUID> = []) {
        var kept = Unsent(words: words, problem: AgentRemoteWritingStamp.unreadable, selection: selection, writingID: writingID)
        if startsChat {
            keepForNewChat(kept, key: key)
            return
        }
        kept.known = known
        if let waiting = unsent[key] {
            kept = Unsent(
                words: waiting.words + "\n\n" + words, problem: kept.problem, known: waiting.known,
                reading: waiting.reading, selection: selection ?? waiting.selection, writingID: writingID,
                writingRevision: waiting.writingRevision, writingDigest: waiting.writingDigest
            )
        }
        unsent[key] = kept
    }

    /// Says why a message kept as not sent still hasn't gone.
    func keepProblem(_ problem: String, forUnsent key: String) {
        unsent[key]?.problem = problem
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
        // A chat with a question on its way, or a turn waited for, stays
        // followed on the Mac, so its turn is heard beginning and ending;
        // opening another chat replaces it there.
        if let openChatID, awaited[openChatID] == nil,
           !sendRequests.values.contains(where: { $0.chatID == openChatID }) {
            seal(.closeChat(openChatID))
        }
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
        // Stopped here: its reader was there, and isn't told.
        awaited[chat.id] = nil
        if awaited.isEmpty { releaseBackgroundTime() }
        followAwaited()
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

/// Time asked of iOS to finish something once Lamp is left, given back once,
/// from whichever thread finishes it or when iOS calls time.
final class BackgroundHold: @unchecked Sendable {
    private let lock = NSLock()
    private var task = UIBackgroundTaskIdentifier.invalid

    @MainActor
    init(name: String) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        lock.lock()
        let ending = task
        task = .invalid
        lock.unlock()
        guard ending != .invalid else { return }
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(ending) }
    }
}
