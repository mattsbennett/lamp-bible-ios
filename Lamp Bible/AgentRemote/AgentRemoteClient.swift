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
        /// Where it was reached by address rather than found by Bonjour, as
        /// over Tailscale, whose network carries no Bonjour.
        var address: LampAgentRemoteAddress? = nil

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
    /// What the Mac's chats can run with: its providers, their models and
    /// efforts, and whether each is signed in there. Nil until it says, and
    /// from a Mac older than setup on devices, which offers no choices.
    @Published private(set) var setup: LampAgentRemoteSetup?
    /// A change of who answers in the open chat, on its way to the Mac.
    @Published private(set) var isChangingChoices = false
    /// Why the last change of who answers wasn't made, and the chat it was
    /// asked for, where alone it's shown.
    @Published var choicesProblem: String?
    @Published private(set) var choicesProblemChatID: String?
    private var choicesRequestChatID: String?
    /// An answer to a request a turn waits on, on its way to the Mac: one at
    /// a time, until the Mac says it was taken or refused.
    @Published private(set) var approvalAnswer: AgentRemoteApprovalAnswer?
    /// Why an answer given here wasn't taken, and the request it answered,
    /// on whose card alone it's shown.
    @Published private(set) var approvalProblem: (digest: String, text: String)?
    /// Notices about answers given here, by chat, for a chat closed before
    /// its answer was settled (`tell(_:inChat:)`).
    private var approvalNotices: [String: (text: String, digest: String, turn: UUID?)] = [:]
    /// Requests whose answer timed out, by digest, with their chat: not
    /// answered again until the chat, asked for afresh, shows them still
    /// waiting, or the late reply comes. A second answer then could undo
    /// nothing the first had done.
    @Published private(set) var lockedApprovals: [String: (chatID: String, refresh: UUID?)] = [:]
    /// Answers whose reply didn't come in time (`approvalReplyWait`): no
    /// longer holding the buttons, but a reply that comes late still says
    /// what became of them.
    private var lateApprovalAnswers: [UUID: AgentRemoteApprovalAnswer] = [:]
    private var approvalDeadline: Task<Void, Never>?
    /// How long an answer waits for the Mac's word before it's taken as
    /// unknown: long enough for Claude's hook to read it.
    static let approvalReplyWait: Duration = .seconds(30)
    /// What a new chat of each kind (`LampAgentRemoteChatSummary.reader`,
    /// `.writing`) is to start with, as chosen here before it has begun:
    /// what isn't chosen is what the Mac would open it on.
    @Published private(set) var newChatChoices: [String: LampAgentRemoteChoices] = [:]
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
    private let addressBook: AgentRemoteAddressBook
    /// The addresses Macs are reached at where Bonjour doesn't find them.
    @Published private(set) var addresses: [AgentRemoteAddressBook.Entry] = []
    /// The Macs Bonjour finds, which `hosts` lists before those at an address.
    private var bonjourHosts: [Host] = [] {
        didSet { listHosts() }
    }
    /// The addresses in the pairing code being paired with, kept for its Mac
    /// once the pairing is.
    private var pairingAddresses: [LampAgentRemoteAddress] = []
    /// The wait before a Mac Bonjour hasn't shown is tried at an address.
    private var addressFallback: UUID?
    /// The Mac expected at the host connected to on its own, and that host:
    /// kept through retries of it, let go when the person chooses or pairs.
    private var expectedSecret: String?
    private var expectedHostID: String?
    /// Set while the only Mac Bonjour shows is tried as the last one, which
    /// was paired at an address: another answering sends it there instead.
    private var probingBonjour = false
    /// The name Bonjour finds the Mac being found again by, where it was
    /// reached at an address.
    private var recoveryBonjourName: String?
    static let addressFallbackWait: TimeInterval = 3
    /// The host last connected to when it was one at an address, whose name
    /// may be a Bonjour Mac's too.
    private static let lastHostIDKey = "agentRemote.lastHostID"
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
    private var choicesRequest: UUID?
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

    init(memory: AgentRemoteMemory = .shared, addressBook: AgentRemoteAddressBook = .shared) {
        self.memory = memory
        self.addressBook = addressBook
        rememberedHosts = memory.hosts
        addresses = addressBook.entries
        listHosts()
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
        // An answer to a request on its way holds it too, until the Mac's
        // word on it or its time runs out (`approvalReplyWait`), whatever
        // the notifications: cut off, it might not arrive, or not be heard
        // of.
        if approvalAnswer != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { self?.stopIfUnneeded() }
            }
            return
        }
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
                self.releaseBackgroundTimeIfUnneeded()
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
                // A turn's end, not a request waiting: only that says the
                // Mac's push of an end will come.
                if let pushed = AgentTurnPush.turn(fromPush: shown.request.content.userInfo), !pushed.isWait {
                    AgentTurnPush.notePushSeen(from: pushed.deviceID)
                }
            }
            // A push is shown under an identifier of iOS's own: known by what
            // it carries.
            let pushed = delivered.contains { shown in
                guard shown.date >= turn.since,
                      let pushed = AgentTurnPush.turn(fromPush: shown.request.content.userInfo),
                      pushed.chatID == chatID, !pushed.isWait else { return false }
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
    func hasHeard(chatID: String, turnID: String?, deviceID: String? = nil) -> Bool {
        if isWatching(chatID: chatID, deviceID: deviceID) { return true }
        guard let last = heard[chatID] else { return false }
        if let turnID, let heardID = last.turnID {
            return turnID.caseInsensitiveCompare(heardID) == .orderedSame
        }
        return Date().timeIntervalSince(last.at) < Self.heardWindow
    }

    /// Whether the chat is on screen, with the Mac connected to keep it so:
    /// the one `deviceID` pairs with, when it's named, since two Macs' chats
    /// of the same writing have the same id.
    func isWatching(chatID: String, deviceID: String? = nil) -> Bool {
        // A connection come back to isn't known to be there until it answers.
        guard UIApplication.shared.applicationState == .active, panelsShowing > 0, chat?.id == chatID,
              case .connected = phase, probe == nil else { return false }
        return deviceID == nil || deviceID == rememberedHosts.first(where: { $0.hostSecret == chatsHostSecret })?.deviceID
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
                    self.releaseBackgroundTimeIfUnneeded()
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
        releaseBackgroundTimeIfUnneeded()
        stopIfUnneeded()
    }

    private func enteredBackground() {
        // A ping unanswered by now isn't judged while Lamp is away: its
        // background time is for hearing a turn end.
        probe = nil
        dropStaleAwaited()
        // A question still on its way may begin a turn to wait for.
        let asking = AgentTurnNotifications.isEnabledNow && (startRequest != nil || !sendRequests.isEmpty)
        // And an answer to a request, until the Mac's word on it, whatever
        // the notifications: suspended, it would never be heard of.
        if !awaited.isEmpty || asking || approvalAnswer != nil { holdForAwaited() }
    }

    /// Back in Lamp with a turn still waited for: to hear how it ended, the
    /// connection comes back, panel or not.
    /// When a lost connection was last made again without asking.
    private var lastLossRetry = Date.distantPast
    static let lossRetryInterval: TimeInterval = 30

    private func becameActive() {
        #if DEBUG
        // A demo has no Mac to look for again.
        if UserDefaults.standard.string(forKey: "AgentRemoteDemo") != nil { return }
        #endif
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
    /// The proven Mac's secret while a loss is being recovered from: kept
    /// through failed attempts, let go when the person chooses a Mac or it's
    /// found again.
    private var pinnedSecret: String?
    /// The name of the Mac the pin is for: kept while recovery tries
    /// same-named candidates, dropped for a Mac of another name.
    private var pinnedName: String?

    /// The Mac last connected to, by the host it was found as and the
    /// secret it proved: tied to that host, not only its name, which
    /// another Mac may share.
    private var lastConnected: (hostID: String, secret: String)?
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
        // Checked against the Mac this device proved it was connected to,
        // pinned for the whole recovery: an attempt that failed with a
        // same-named Mac doesn't loosen it. A first connection that never got
        // through proves nothing, and pins nothing.
        if pinnedSecret != nil, let host, !isPinned(host) { pinnedSecret = nil }
        if pinnedSecret == nil, let id = host?.id, lastConnected?.hostID == id {
            pinnedSecret = lastConnected?.secret
            pinnedName = target
        }
        recoverySecret = pinnedSecret
        let attempt = UUID()
        recoveryAttempt = attempt
        // Looked for by Bonjour first, under the name it has there, then at
        // an address it answered at (`armAddressFallback`), whichever way it
        // was reached last.
        recoveryBonjourName = host?.address.flatMap { address in
            addresses.first { $0.text == address.text }?.bonjourName
        }
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

    /// A direct retry made without the person, to a Mac never proven: said
    /// to have failed if it hasn't answered in a while, not left turning.
    private func armConnectDeadline() {
        guard case .connecting = phase, let target = host?.name, let watched = connection else { return }
        let attempt = UUID()
        recoveryAttempt = attempt
        connectDeadlineArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rediscoveryWait) { [weak self] in
            MainActor.assumeIsolated {
                // Only over the connection it was set for: a newer one, from a
                // panel opened meanwhile, has its own course.
                guard let self, self.recoveryAttempt == attempt, self.connection === watched,
                      case .connecting = self.phase else { return }
                self.connectDeadlineArmed = false
                if self.tryNextAddress() { return }
                self.teardown()
                self.lostRecoverably = true
                self.phase = .unavailable("\(target) couldn\u{2019}t be reached. Check it\u{2019}s open and on the same network.")
            }
        }
    }

    /// Whether the connection being made has `armConnectDeadline`'s limit:
    /// carried to the connection that replaces it to pair afresh, which is
    /// still the same attempt (`.pairAgain`). Every new connection starts
    /// without it, and answering ends it.
    private var connectDeadlineArmed = false

    /// `promptly` on coming back to Lamp; otherwise, as from the waited
    /// turn's timer, no oftener than `lossRetryInterval`, so a Mac that stays
    /// away leaves its message and buttons up between tries.
    private func reconnectIfLost(promptly: Bool = true) {
        switch phase {
        case .unavailable:
            guard lostRecoverably,
                  promptly || Date().timeIntervalSince(lastLossRetry) > Self.lossRetryInterval else { return }
            lastLossRetry = Date()
            // Found again by browsing only when this device proved which Mac
            // it was; one never connected to is tried where it was chosen.
            if let host, isPinned(host) || lastConnected?.hostID == host.id {
                rediscover()
            } else if let host {
                connect(to: host, chosen: false)
                armConnectDeadline()
            }
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

    /// Gives the background time back once nothing it's held for is left:
    /// no turn waited for, no question on its way that may begin one (as
    /// `enteredBackground` holds it for), no answer to a request unheard of.
    private func releaseBackgroundTimeIfUnneeded() {
        let asking = AgentTurnNotifications.isEnabledNow && (startRequest != nil || !sendRequests.isEmpty)
        if awaited.isEmpty && approvalAnswer == nil && !asking { releaseBackgroundTime() }
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

    /// Another Mac answered as the one being found again: nothing more it
    /// says is taken in, and which Mac to use is the person's to choose, not
    /// Try Again's nor the next browse's, until they do.
    private func rejectRecoveredMac() {
        let name = host?.name ?? "your Mac"
        rediscoveringLast = false
        teardown()
        lostRecoverably = false
        host = nil
        mustChooseHost = true
        choosingHost = true
        phase = .unavailable("Another Mac answered as \(name). Choose the Mac to use.")
    }

    /// Set when a Mac was turned away for not being the one found again:
    /// kept through the panel closing, so reopening it doesn't connect to it.
    private var mustChooseHost = false

    func stop() {
        rediscoveringLast = false
        lostRecoverably = false
        // Closed, the recovery is over: what opens next is a fresh start.
        pinnedSecret = nil
        pinnedName = nil
        recoveryAttempt = nil
        browser?.cancel()
        browser = nil
        addressFallback = nil
        teardown()
        bonjourHosts = []
        chat = nil
        choosingHost = mustChooseHost
        phase = .stopped
    }

    func retry() {
        // The person's attempt now: no automatic deadline over it, and every
        // address worth trying again.
        recoveryAttempt = nil
        triedAddresses = []
        // After a loss: looked for again the same way, with its time limit
        // and its check that it's that Mac.
        // Only for a Mac this device proved it was connected to: one that
        // never answered is tried again where it was chosen.
        if lostRecoverably, let host, !choosingHost,
           isPinned(host) || lastConnected?.hostID == host.id {
            lastLossRetry = Date()
            rediscover()
            return
        }
        if let host, !choosingHost {
            // Still the lost Mac's to answer as, whatever ended the last
            // try: a same-named Mac that failed recovery isn't taken for it
            // on a plain retry.
            connect(to: host, chosen: false, expecting: isPinned(host) ? pinnedSecret : nil)
        } else {
            browse()
        }
    }

    /// Lets someone pick from the Macs found rather than the one chosen.
    func chooseAnotherHost() {
        // The person's choice now, not the lost connection's.
        lostRecoverably = false
        pinnedSecret = nil
        rediscoveringLast = false
        teardown()
        choosingHost = true
        browse()
    }

    func forget(_ remembered: LampAgentRemoteRememberedHost) {
        memory.forget(remembered.id)
        rememberedHosts = memory.hosts
        addressBook.forget(pairing: remembered.id)
        refreshAddresses()
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
            addressBook.forget(pairing: remembered.id)
        }
        rememberedHosts = memory.hosts
        refreshAddresses()
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
        // Its providers, and what was chosen among them.
        setup = nil
        newChatChoices = [:]
        choicesProblem = nil
        chatsHostSecret = nil
        chooseAnotherHost()
    }

    private func browse() {
        // A new search: every route worth trying again.
        triedAddresses = []
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
                self.bonjourHosts = results.compactMap { result -> Host? in
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
        armAddressFallback()
    }

    // MARK: - Addresses

    /// The hosts to choose from: those Bonjour finds, then the addresses kept.
    private func listHosts() {
        hosts = bonjourHosts + addresses.compactMap(Self.host(for:))
    }

    private static func host(for entry: AgentRemoteAddressBook.Entry) -> Host? {
        guard let address = entry.address, let port = NWEndpoint.Port(rawValue: address.port) else { return nil }
        return Host(
            id: "address " + entry.text, name: entry.name ?? entry.text,
            endpoint: .hostPort(host: NWEndpoint.Host(address.host), port: port), address: address
        )
    }

    func refreshAddresses() {
        addresses = addressBook.entries
        listHosts()
    }

    /// Connects to a Mac at a typed address, keeping it to try again.
    /// False where it isn't one (`LampAgentRemoteAddress.parse`).
    func connect(toAddress typed: String) -> Bool {
        guard let address = LampAgentRemoteAddress.parse(typed) else { return false }
        addressBook.keep(address)
        refreshAddresses()
        if let host = hosts.first(where: { $0.address == address }) { connect(to: host) }
        return true
    }

    func forgetAddress(_ entry: AgentRemoteAddressBook.Entry) {
        addressBook.forget(entry.text)
        refreshAddresses()
        // Not tried again on its own once forgotten.
        if host?.address?.text == entry.text, connection == nil {
            host = nil
            lostRecoverably = false
        }
    }

    /// The pairing a Mac's secret answers to, by its id: what the address
    /// book knows a Mac by, which holds no secret.
    private func pairing(forSecret secret: String?) -> String? {
        guard let secret else { return nil }
        return memory.hosts.first { $0.hostSecret == secret }?.id
    }

    private func secret(forPairing pairing: String?) -> String? {
        guard let pairing else { return nil }
        return memory.hosts.first { $0.id == pairing }?.hostSecret
    }

    /// Whether `host` is the Mac a loss is being recovered from: by the name
    /// it was proven under, or at an address that Mac answered at, so
    /// recovery that moved from Bonjour to an address keeps its check.
    private func isPinned(_ host: Host) -> Bool {
        guard let pinnedSecret else { return false }
        if pinnedName == host.name { return true }
        // Reached the other way: at an address it answered at, or under the
        // Bonjour name it was found by.
        return addresses.contains { entry in
            secret(forPairing: entry.pairing) == pinnedSecret
                && (host.address.map { $0.text == entry.text } ?? (entry.bonjourName == host.name))
        }
    }

    /// Set while an address is being typed, so nothing found meanwhile is
    /// connected to on its own and takes the typing away.
    var enteringAddress = false

    /// Addresses tried for the Mac being reached, this time round.
    private var triedAddresses: Set<String> = []

    /// After an address didn't answer: another the same Mac answered at, not
    /// yet tried, under the same check. False where there's none.
    private func tryNextAddress() -> Bool {
        // After an address, or after Bonjour's route to the same Mac.
        if let failed = host?.address?.text { triedAddresses.insert(failed) }
        let expected = expectedSecret ?? (rediscoveringLast ? recoverySecret : nil)
        guard let expected,
              let next = addresses.first(where: { !triedAddresses.contains($0.text) && secret(forPairing: $0.pairing) == expected }),
              let host = Self.host(for: next) else { return false }
        connect(to: host, automatic: rediscoveringLast, chosen: false, expecting: expected)
        return true
    }

    /// The pairing last connected to, whichever way it was reached.
    private static let lastPairingKey = "agentRemote.lastPairing"

    /// A Mac Bonjour hasn't shown in a moment tried where it was last reached
    /// by address: the one being found again, the one last connected to, or
    /// the only one kept where Bonjour finds none. Bonjour goes first, so a
    /// Mac on the same network is reached the way it always was. A Mac known
    /// at the address is expected there: another answering is turned away.
    private func armAddressFallback() {
        let attempt = UUID()
        addressFallback = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.addressFallbackWait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.addressFallback == attempt, self.connection == nil, !self.choosingHost,
                      !self.enteringAddress else { return }
                // Still looking, or told Bonjour isn't allowed, which an
                // address over Tailscale may not need.
                guard self.phase == .searching || self.phase == .unavailable(Self.localNetworkDenied) else { return }
                if self.rediscoveringLast {
                    let lost = self.host?.address?.text
                    guard let secret = self.recoverySecret,
                          let entry = self.addresses.first(where: { $0.text == lost && self.secret(forPairing: $0.pairing) == secret })
                            ?? self.addresses.first(where: { self.secret(forPairing: $0.pairing) == secret }),
                          let host = Self.host(for: entry) else { return }
                    self.connect(to: host, automatic: true, expecting: secret)
                    return
                }
                let lastPairing = UserDefaults.standard.string(forKey: Self.lastPairingKey)
                let lastID = UserDefaults.standard.string(forKey: Self.lastHostIDKey)
                let lastName = UserDefaults.standard.string(forKey: Self.lastHostKey)
                let entry = self.addresses.first { "address " + $0.text == lastID }
                    ?? self.addresses.first { lastPairing != nil && $0.pairing == lastPairing }
                    ?? (lastPairing == nil ? self.addresses.first { lastName != nil && $0.name == lastName } : nil)
                    ?? (self.bonjourHosts.isEmpty && self.addresses.count == 1 ? self.addresses.first : nil)
                guard let entry, let host = Self.host(for: entry) else { return }
                self.connect(to: host, chosen: false, expecting: self.secret(forPairing: entry.pairing))
            }
        }
    }

    /// The Mac chosen last time, or the only one there is: connected to
    /// without asking, since opening the chat panel is the asking. The last
    /// Mac, where it has an address and Bonjour doesn't show it, is left to
    /// be tried there, not passed over for another that does show.
    private func connectIfOneIsClear() {
        guard phase == .searching, connection == nil, !choosingHost, !enteringAddress else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastHostKey)
        if rediscoveringLast {
            if let match = bonjourHosts.first(where: { $0.name == recoveryTarget || $0.name == recoveryBonjourName }) {
                connect(to: match, automatic: true, expecting: recoverySecret)
                // Another answering under its name, or none: its address next.
                probingBonjour = recoverySecret.map { secret in
                    addresses.contains { self.secret(forPairing: $0.pairing) == secret }
                } ?? false
            } else if host?.address != nil, recoveryBonjourName == nil, let secret = recoverySecret,
                      bonjourHosts.count == 1, let only = bonjourHosts.first {
                // Reached at an address it was typed as, never seen here: the
                // only Mac shown may be it, proven so, its address after.
                connect(to: only, automatic: true, expecting: secret)
                probingBonjour = true
            }
            return
        }
        let lastPairing = UserDefaults.standard.string(forKey: Self.lastPairingKey)
        let lastAtAddresses = addresses.filter { lastPairing != nil && $0.pairing == lastPairing }
        let lastSecret = secret(forPairing: lastPairing)
        let bonjourNames = Set(lastAtAddresses.compactMap(\.bonjourName))
        if let match = bonjourHosts.first(where: { $0.name == last || bonjourNames.contains($0.name) }) {
            // Found under the last Mac's name: proven to be it, where its
            // pairing is known, and where it has an address, tried there if
            // it isn't, or doesn't answer.
            connect(to: match, chosen: false, expecting: lastSecret)
            probingBonjour = lastSecret != nil && !lastAtAddresses.isEmpty
        } else if lastAtAddresses.isEmpty, bonjourHosts.count == 1, let only = bonjourHosts.first {
            connect(to: only, chosen: false)
        } else if bonjourNames.isEmpty, lastSecret != nil, bonjourHosts.count == 1, let only = bonjourHosts.first {
            // Paired at an address and never seen here: the only Mac shown
            // may be it, and is tried, its address after if it isn't.
            connect(to: only, chosen: false, expecting: lastSecret)
            probingBonjour = true
        }
    }

    // MARK: - Connecting

    /// `automatic` for recovery's own connection; any other ends recovery,
    /// its deadline and its check of which Mac it is. `chosen` when the
    /// person picked the Mac: the one last proven under its name may not be
    /// it, so that proof goes; a connection made for them to the last Mac,
    /// as on opening the panel, keeps it.
    /// `expecting`: the secret of the Mac known at this address, when it's
    /// connected to without the person choosing: another that answers there
    /// is turned away.
    func connect(to host: Host, pendingCode: String? = nil, automatic: Bool = false, chosen: Bool = true, expecting: String? = nil) {
        if !automatic {
            rediscoveringLast = false
            recoverySecret = nil
            mustChooseHost = false
            if chosen {
                pinnedSecret = nil
                // No automatic deadline over the person's own attempt.
                recoveryAttempt = nil
            }
            // Another host chosen: the proof was another Mac's. The same one
            // chosen again keeps it, for recovering it later.
            if chosen, lastConnected?.hostID != host.id { lastConnected = nil }
        }
        closingReason = nil
        hostNamesRequests = false
        // This connection's own limit, if it has one, is armed below.
        connectDeadlineArmed = false
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
        if let expecting {
            expectedSecret = expecting
            expectedHostID = host.id
        } else if chosen || expectedHostID != host.id {
            expectedSecret = nil
            expectedHostID = nil
        }
        if expecting == nil || host.address != nil { probingBonjour = false }
        // Something answering at an address, or a Mac tried as the last one,
        // that never says hello isn't waited on for ever: the next route is.
        if host.address != nil || expecting != nil { armConnectDeadline() }
    }

    /// The code from the Mac's QR, or typed. If the connection it was meant
    /// for has closed while someone scanned, a new one answers with it.
    /// `addresses`: where the pairing code says the Mac can be reached, kept
    /// for it once the pairing is.
    func pair(code: String, addresses: [LampAgentRemoteAddress] = []) {
        guard LampPresentationRemotePairing.normalizedCode(code) != nil else { return }
        // A code entered is a pairing the person chose: recovery's over.
        recoveryAttempt = nil
        pinnedSecret = nil
        pinnedName = nil
        rediscoveringLast = false
        recoverySecret = nil
        // Pairing is the person's choice of this Mac, whatever was expected.
        expectedSecret = nil
        expectedHostID = nil
        probingBonjour = false
        if session?.isWaitingForCode == true, connection != nil {
            pairingAddresses = addresses
            perform(session?.pair(code: code) ?? [])
            if case .needsCode = phase, let host { phase = .connecting(host.name) }
        } else if let host {
            connect(to: host, pendingCode: code, chosen: false)
            // This attempt's, after the connection it's made on is begun:
            // ending that connection lets them go.
            pairingAddresses = addresses
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
        // A ping on this connection is no question of the next one's.
        probe = nil
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
        // A pairing ended unfinished: its code's addresses aren't another's.
        pairingAddresses = []
        chat?.sending = nil
        // A change of who answers that wasn't heard back about: the chat is
        // opened afresh on coming back, under whatever the Mac kept.
        choicesRequest = nil
        isChangingChoices = false
        // An answer not heard back about may or may not have been taken: the
        // chat's snapshot, on coming back, says what still waits, but a card
        // gone from it doesn't say whose answer took it.
        if let answer = approvalAnswer {
            tell(answer.unheard, inChat: answer.chatID, about: answer)
        }
        approvalDeadline?.cancel()
        lateApprovalAnswers = [:]
        // The chat's snapshot on coming back says what still waits: until it
        // comes, nothing the chat showed before is answered.
        lockedApprovals = [:]
        if let chat {
            // Any snapshot after coming back is fresh.
            for approval in chat.approvals { lockedApprovals[chat.digest(of: approval)] = (chat.id, nil) }
        }
        approvalAnswer = nil
        approvalProblem = nil
    }

    private func perform(_ effects: [LampAgentRemoteDeviceConnection.Effect]) {
        // A Mac found again by name that proves to be another: turned away
        // before anything of this device's goes to it, its opening requests
        // included.
        if effects.contains(where: { if case .connected = $0 { true } else { false } }), let secret = session?.hostSecret,
           (rediscoveringLast && recoverySecret != nil && secret != recoverySecret)
            || (expectedSecret != nil && secret != expectedSecret) {
            if probingBonjour, let expected = expectedSecret,
               let entry = addresses.first(where: { self.secret(forPairing: $0.pairing) == expected }),
               let atAddress = Self.host(for: entry) {
                // Not the last Mac after all: it's tried where it was paired.
                probingBonjour = false
                connect(to: atAddress, chosen: false, expecting: expected)
                return
            }
            rejectRecoveredMac()
            return
        }
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
                if probingBonjour, let expected = expectedSecret,
                   let entry = addresses.first(where: { self.secret(forPairing: $0.pairing) == expected }),
                   let atAddress = Self.host(for: entry) {
                    // A Mac that doesn't know this device isn't the last one:
                    // that one's tried where it was paired.
                    probingBonjour = false
                    connect(to: atAddress, chosen: false, expecting: expected)
                    return
                }
                phase = .needsCode(host: host?.name ?? "your Mac", notice: problem.map(AgentRemoteProblemText.text) ?? pendingNotice)
                pendingNotice = nil
            case let .remember(remembered):
                let earlier = memory.hosts.filter { $0.hostSecret == remembered.hostSecret && $0.id != remembered.id }.map(\.id)
                memory.remember(remembered)
                addressBook.repoint(from: earlier, to: remembered.id)
                refusedKeys.remove(remembered.id)
                rememberedHosts = memory.hosts
                for address in pairingAddresses {
                    addressBook.keep(address, name: remembered.name, pairing: remembered.id)
                }
                pairingAddresses = []
                refreshAddresses()
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
                connectDeadlineArmed = false
                guard let host else { break }
                // Found again by name, but proven to be another Mac: not
                // taken for the one that was lost, nor its chats dropped.
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
                            // Another Mac's providers.
                            setup = nil
                            newChatChoices = [:]
                            choicesProblem = nil
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
                if let secret = session?.hostSecret { lastConnected = (host.id, secret) }
                pinnedSecret = nil
                lostRecoverably = false
                rediscoveringLast = false
                UserDefaults.standard.set(host.name, forKey: Self.lastHostKey)
                UserDefaults.standard.set(host.address == nil ? nil : host.id, forKey: Self.lastHostIDKey)
                if let pairing = pairing(forSecret: session?.hostSecret) {
                    UserDefaults.standard.set(pairing, forKey: Self.lastPairingKey)
                    if let address = host.address {
                        // Reached at an address: it's this Mac's now, under its name.
                        addressBook.keep(address, name: memory.hosts.first { $0.id == pairing }?.name, pairing: pairing)
                    } else {
                        // Found by Bonjour: the name to look for it by, off Tailscale.
                        addressBook.found(pairing: pairing, bonjourName: host.name)
                    }
                    refreshAddresses()
                }
                rememberedHosts = memory.hosts
                // Back where this device was before the connection dropped.
                if let openChatID {
                    let request = LampAgentRemoteMessage.openChat(openChatID)
                    openRequest = request.requestID
                    seal(request)
                }
                // How the turns waited for went while it was down.
                if !awaited.isEmpty { seal(.listChats()) }
                // What its chats can run with. An older Mac doesn't answer.
                seal(.getSetup())
            case let .received(message):
                handle(message)
            case .pairAgain:
                pendingNotice = AgentRemoteProblemText.refused
                // Recovery's own retry stays recovery's: no one chose anew.
                // An attempt with a time limit keeps one: recovery's search
                // has its own, and a direct retry's is armed again for the
                // connection that pairs.
                let keepsDeadline = connectDeadlineArmed && !rediscoveringLast
                if let host {
                    connect(to: host, automatic: rediscoveringLast, chosen: false)
                    if keepsDeadline { armConnectDeadline() }
                } else {
                    teardown()
                    phase = .unavailable(AgentRemoteProblemText.refused)
                }
            case let .failed(problem):
                if case .unreachable = problem, tryNextAddress() { return }
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
            // A chat not running has nothing waiting: an alert of a request
            // there may be over.
            if chats.contains(where: { !$0.isRunning }) { AgentTurnPush.sweepWaitsSoon() }
        case .snapshot:
            guard let snapshot = message.snapshot else { return }
            let started = message.requestID != nil && message.requestID == startRequest?.id
            // The chat under another provider is that provider's side of the
            // conversation: what it holds says nothing of this device's
            // questions, which were asked of the other, so none is settled by
            // it. Nor is a snapshot sent because a window changed the chat.
            let movedProvider = chat?.id == snapshot.summary.id && chat?.summary.provider != snapshot.summary.provider
            if let requestID = message.requestID, requestID == choicesRequest {
                choicesRequest = nil
                isChangingChoices = false
                // The Mac now remembers this choice for new chats too.
                seal(.getSetup())
            }
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
                // Said about an answer given here while the chat was closed:
                // kept, until its answer is heard of or another turn begins.
                if let notice = approvalNotices[Self.noticeKey(host: chatsHostSecret, chat: snapshot.summary.id)] {
                    chat?.approvalNotice = notice.text
                    chat?.approvalNoticeDigest = notice.digest
                    chat?.approvalNoticeTurn = notice.turn
                }
            }
            if snapshot.approvals?.isEmpty ?? true { AgentTurnPush.sweepWaitsSoon() }
            chat?.dropNoticeFromAnotherTurn()
            if chat?.approvalNotice == nil {
                approvalNotices[Self.noticeKey(host: chatsHostSecret, chat: snapshot.summary.id)] = nil
            }
            // The chat as it stands now: what waits in it can be answered.
            // One sent before a timed-out answer could arrive after it: only
            // the snapshot asked for since unlocks that answer's request.
            lockedApprovals = lockedApprovals.filter {
                $0.value.chatID != snapshot.summary.id
                    || $0.value.refresh != nil && $0.value.refresh != message.requestID
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
            // By its words only on the same provider's side; what the Mac
            // names by request (`askedBy`, below) settles it on any.
            if !movedProvider {
                sendRequests = sendRequests.filter {
                    $0.value.chatID != id || !Self.holds(snapshot.messages, $0.value.words, known: $0.value.known)
                }
                if let kept = unsent[id], Self.holds(snapshot.messages, kept.words, known: kept.known) {
                    unsent[id] = nil
                }
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
            if event.kind == LampAgentRemoteChatEvent.turnEnded
                || (event.kind == LampAgentRemoteChatEvent.approvals && (event.approvals ?? []).isEmpty) {
                AgentTurnPush.sweepWaitsSoon()
            }
            // Another turn: what was said of the last turn's answers is done.
            if event.kind == LampAgentRemoteChatEvent.turnStarted
                || chat?.id == event.chatID && chat?.approvalNotice == nil {
                approvalNotices[Self.noticeKey(host: chatsHostSecret, chat: event.chatID)] = nil
            }
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
        case .setup:
            if let setup = message.setup { self.setup = setup }
        case .approvalAnswered:
            settleApprovalAnswer(message, answered: true)
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

    /// What's to be said about an answer given here that may not have been
    /// the one taken: in its chat, now if it's open, else when it's opened
    /// again. A card gone from the chat doesn't say whose answer took it.
    private func tell(_ notice: String, inChat chatID: String, about answer: AgentRemoteApprovalAnswer) {
        if let chat, chat.id == chatID {
            // A late word about an earlier turn's answer isn't this turn's,
            // and leaves what's said of this one.
            guard answer.turnID == chat.lastQuestion else { return }
            self.chat?.approvalNotice = notice
            self.chat?.approvalNoticeDigest = answer.digest
            self.chat?.approvalNoticeTurn = answer.turnID
        }
        // Kept too, the open chat's included: closing the last panel lets
        // the chat go before anyone has read it.
        approvalNotices[Self.noticeKey(host: chatsHostSecret, chat: chatID)] = (notice, answer.digest, answer.turnID)
    }

    /// By Mac and chat: two Macs may have a chat of the same id, the same
    /// writing's, and an answer went to one of them.
    private static func noticeKey(host: String?, chat: String) -> String {
        "\(host ?? "")|\(chat)"
    }

    /// The Mac's reply to an answer given here: taken, or no longer waiting
    /// as shown, the card goes; refused, it stays, saying why.
    private func settleApprovalAnswer(_ message: LampAgentRemoteMessage, answered: Bool) {
        let answer: AgentRemoteApprovalAnswer
        if let current = approvalAnswer, message.requestID == current.requestID {
            answer = current
            approvalAnswer = nil
            approvalDeadline?.cancel()
            releaseBackgroundTimeIfUnneeded()
        } else if let requestID = message.requestID, let late = lateApprovalAnswers.removeValue(forKey: requestID) {
            answer = late
            lockedApprovals[late.digest] = nil
        } else {
            return
        }
        switch answer.settle(answered: answered, errorCode: message.errorCode, message: message.errorMessage) {
        case .drop(let notice):
            chat?.drop(answered: answer)
            if let notice {
                // Said in the chat, where it stays once the card has gone.
                tell(notice, inChat: answer.chatID, about: answer)
            } else {
                // Taken: what was said of this request's answer, one sent
                // before a connection ended or not heard back about, is
                // settled now. Another request's stays.
                if chat?.id == answer.chatID, chat?.approvalNoticeDigest == answer.digest {
                    chat?.approvalNotice = nil
                    chat?.approvalNoticeDigest = nil
                }
                let key = Self.noticeKey(host: chatsHostSecret, chat: answer.chatID)
                if approvalNotices[key]?.digest == answer.digest { approvalNotices[key] = nil }
            }
        case .keep(let problem):
            approvalProblem = (answer.digest, problem)
        }
    }

    /// Asks again for a chat whose timed-out answer's request is locked, the
    /// refresh having failed or not come: the answer isn't sent again.
    func recheckLocked(inChat chatID: String) {
        guard chat?.id == chatID else { return }
        let refresh = LampAgentRemoteMessage.openChat(chatID)
        for (digest, lock) in lockedApprovals where lock.chatID == chatID {
            lockedApprovals[digest] = (chatID, refresh.requestID)
            approvalProblem = nil
        }
        seal(refresh)
    }

    private func failed(_ message: LampAgentRemoteMessage) {
        // The refresh a locked request waits for, refused: said on its card,
        // which offers to ask again; it stays locked meanwhile.
        if let requestID = message.requestID,
           let (digest, _) = lockedApprovals.first(where: { $0.value.refresh == requestID }) {
            approvalProblem = (digest, AgentRemoteFailureText.text(code: message.errorCode, message: message.errorMessage))
            return
        }
        if let requestID = message.requestID,
           requestID == approvalAnswer?.requestID || lateApprovalAnswers[requestID] != nil {
            settleApprovalAnswer(message, answered: false)
            return
        }
        let text = AgentRemoteFailureText.text(code: message.errorCode, message: message.errorMessage)
        if let requestID = message.requestID, requestID == choicesRequest {
            choicesRequest = nil
            isChangingChoices = false
            choicesProblem = text
            choicesProblemChatID = choicesRequestChatID
            return
        }
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
        choicesProblem = nil
        if let newChatKey { moveDraft(from: newChatKey, to: chatID) }
        openChatID = chatID
        chat = nil
        let request = LampAgentRemoteMessage.openChat(chatID)
        openRequest = request.requestID
        // Asked for afresh: its answer is the refresh a timed-out answer's
        // request waits for.
        for (digest, lock) in lockedApprovals where lock.chatID == chatID {
            lockedApprovals[digest] = (chatID, request.requestID)
        }
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
        choicesProblem = nil
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

    /// Answers the request a turn waits on, as shown: `shown` is its digest
    /// when its card was drawn (`AgentRemoteChat.digest`), so a card left
    /// over from an earlier turn, or a request changed since, answers
    /// nothing. Allow Once only where the Mac lets this device allow it. The
    /// first answer anywhere is the one taken; the Mac's reply settles it.
    func answer(_ approval: LampAgentRemoteApproval, shown: String, decision: String) {
        guard let chat, approvalAnswer == nil, lockedApprovals[shown] == nil,
              chat.approvals.contains(where: { $0 == approval && chat.digest(of: $0) == shown }) else { return }
        switch decision {
        case LampAgentRemoteApprovalAnswer.allowOnce:
            guard AgentRemoteApprovalAnswer.offersAllow(approval) else { return }
        case LampAgentRemoteApprovalAnswer.deny:
            break
        default:
            return
        }
        approvalProblem = nil
        let request = LampAgentRemoteMessage.answerApproval(approval, in: chat.id, turnID: chat.view.turnID, decision: decision)
        guard let requestID = request.requestID, sealAndSend(request) else {
            approvalProblem = (shown, Self.unsealable)
            return
        }
        approvalAnswer = AgentRemoteApprovalAnswer(
            requestID: requestID, chatID: chat.id, digest: shown, turnID: chat.view.turnID, decision: decision,
            label: AgentRemoteApprovalAnswer.label(of: approval)
        )
        approvalDeadline?.cancel()
        approvalDeadline = Task { [weak self] in
            try? await Task.sleep(for: Self.approvalReplyWait)
            guard !Task.isCancelled else { return }
            self?.approvalReplyTimedOut(requestID)
        }
    }

    /// No word from the Mac on an answer: neither taken nor refused, so
    /// it's said to be unknown, never resent, and the chat asked for afresh
    /// to show what still waits. The buttons are free again.
    private func approvalReplyTimedOut(_ requestID: UUID) {
        guard let answer = approvalAnswer, answer.requestID == requestID else { return }
        approvalAnswer = nil
        lateApprovalAnswers[requestID] = answer
        tell(answer.noReply, inChat: answer.chatID, about: answer)
        if chat?.id == answer.chatID {
            let refresh = LampAgentRemoteMessage.openChat(answer.chatID)
            lockedApprovals[answer.digest] = (answer.chatID, refresh.requestID)
            seal(refresh)
        } else {
            // Closed: opening it again asks for it afresh (`open(_:)`).
            lockedApprovals[answer.digest] = (answer.chatID, nil)
        }
        releaseBackgroundTimeIfUnneeded()
        stopIfUnneeded()
    }

    func cancel() {
        guard let chat else { return }
        // Stopped here: its reader was there, and isn't told.
        awaited[chat.id] = nil
        releaseBackgroundTimeIfUnneeded()
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
                provider: "claude", providerName: "Claude", model: "opus", effort: "high", updatedAt: now.addingTimeInterval(-600),
                preview: "Where sin increased, grace abounded all the more: Paul's word is a strong one.",
                isRunning: true, acceptsMessages: true
            ),
            LampAgentRemoteChatSummary(
                id: "demo-2", title: "Isaiah 53", subtitle: "Isaiah 53:5", kind: LampAgentRemoteChatSummary.reader,
                provider: "codex", providerName: "Codex", updatedAt: now.addingTimeInterval(-86_400 * 2),
                preview: "The servant is pierced for our transgressions.", acceptsMessages: true
            ),
        ]
        typealias C = LampAgentRemoteSetup.Connection
        setup = LampAgentRemoteSetup(
            providers: [
                .init(id: "codex", name: "OpenAI Codex", shortName: "Codex", systemImage: "terminal",
                      connection: C(state: demo == "signed-out" ? C.notConnected : C.connected),
                      modelHint: "A model name the Codex CLI accepts.",
                      effortHint: "A value your Codex accepts for model_reasoning_effort."),
                .init(id: "claude", name: "Claude Code", shortName: "Claude", systemImage: "sparkles",
                      connection: C(state: C.connected), models: ["opus", "sonnet", "haiku"],
                      modelHint: "An alias such as opus, or a full model name.",
                      efforts: ["low", "medium", "high", "xhigh", "max"],
                      effortHint: "A level such as high. Claude Code names low to max.",
                      defaultModel: "opus", defaultEffort: "high"),
                .init(id: "openCode", name: "OpenCode", shortName: "OpenCode",
                      systemImage: "chevron.left.forwardslash.chevron.right",
                      connection: C(state: C.notInstalled), modelHint: "provider/model, or provider/model#variant.",
                      effortIsOnTheModel: true),
            ],
            readerProvider: demo == "signed-out" ? "codex" : "claude",
            writingProvider: "claude",
            access: .init(modulesEnabled: true, allModules: false, personalStudy: true)
        )
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
        case "approval", "approval-long", "approval-deny":
            phase = .connected("Study Mac")
            let summary = LampAgentRemoteChatSummary(
                id: "demo-a", title: "Romans 5 commentaries", subtitle: "Romans 5:20", kind: LampAgentRemoteChatSummary.reader,
                provider: "codex", providerName: "Codex", updatedAt: now.addingTimeInterval(-60), isRunning: true, acceptsMessages: true
            )
            chats = summaries + [summary]
            openChatID = "demo-a"
            let long = (1...14).map { "  --include 'Sources/LampCore/File\($0).swift' \\" }.joined(separator: "\n")
            let first: LampAgentRemoteApproval = demo == "approval-deny"
                ? LampAgentRemoteApproval(
                    id: "claude-0", provider: "codex", kind: LampAgentRemoteApproval.tool, title: "Codex asks to edit a file",
                    command: "Edit Writings/John 10.md", folder: "~/Library/Application Support/Lamp Bible/Writings",
                    note: "Lamp sends you only part of this edit.", canAllow: false
                )
                : LampAgentRemoteApproval(
                    id: "codex-0", provider: "codex", kind: LampAgentRemoteApproval.command, title: "Codex asks to run a command",
                    command: demo == "approval-long"
                        ? "rg --line-number \\\n\(long)\n  'LampAgentRemoteApproval' ."
                        : "rg --count 'Rom(ans)? 5:20' ~/Library/Lamp/Commentaries",
                    folder: "~/Library/Lamp",
                    agentReason: "I need to search the commentary files to see which of them cite Romans 5:20.",
                    note: "It runs outside Codex's sandbox, with your access.", canAllow: true
                )
            chat = AgentRemoteChat(LampAgentRemoteChatSnapshot(
                summary: summary,
                messages: [
                    LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "Which commentaries in my library cite this verse?", date: now.addingTimeInterval(-90)),
                ],
                activity: LampAgentRemoteActivity(kind: LampAgentRemoteActivity.tool, name: "Waiting for your answer on the Mac"),
                approvals: [first, LampAgentRemoteApproval(
                    id: "codex-1", provider: "codex", kind: LampAgentRemoteApproval.command, title: "Codex asks to run a command",
                    command: "ls", canAllow: true
                )]
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

    // MARK: - Who answers

    /// Asks the Mac again what its chats can run with: on opening the setup,
    /// where a provider may have been signed in since.
    func refreshSetup() {
        guard case .connected = phase else { return }
        seal(.getSetup())
    }

    /// Moves the open chat to another provider, model or effort. The Mac
    /// answers with the chat under its new choices, or says why not.
    func setChoices(_ choices: LampAgentRemoteChoices) {
        guard !choices.isEmpty, let openChatID, !isChangingChoices,
              // A question not yet taken is the provider's it was asked of.
              unsent[openChatID] == nil, !sendRequests.values.contains(where: { $0.chatID == openChatID })
        else { return }
        choicesProblem = nil
        let request = LampAgentRemoteMessage.setChoices(choices, for: openChatID)
        guard sealAndSend(request) else {
            choicesProblem = Self.unsealable
            return
        }
        choicesRequest = request.requestID
        choicesRequestChatID = openChatID
        isChangingChoices = true
    }

    /// What a new chat of this kind begins with, as the setup row shows it:
    /// what was chosen here, else the Mac's defaults for its provider. Nil
    /// throughout from a Mac that sends no setup.
    func newChatShown(kind: String) -> LampAgentRemoteChoices {
        guard let setup else { return LampAgentRemoteChoices() }
        let chosen = newChatChoices[kind] ?? LampAgentRemoteChoices()
        let providerID = chosen.provider ?? setup.defaultProvider(forKind: kind)
        guard let provider = setup.provider(providerID) else { return chosen }
        let model = chosen.model ?? provider.defaultModel
        var effort = chosen.effort
        if effort == nil {
            // A model chosen here drops the effort carried on the old one,
            // unless it was typed with one of its own, which is sent as the
            // effort so the Mac writes it back on the model.
            if provider.effortIsOnTheModel, let typed = chosen.model {
                effort = typed.firstIndex(of: "#").map { String(typed[typed.index(after: $0)...]) } ?? ""
            } else {
                effort = provider.defaultEffort
            }
        }
        return LampAgentRemoteChoices(provider: providerID, model: model, effort: effort)
    }

    /// What a new chat of this kind starts with, as far as it's chosen here:
    /// a provider chosen anew starts on that provider's defaults. A model or
    /// effort is kept with the provider it was chosen for, so the Mac's
    /// default moving on doesn't pair it with another.
    func chooseForNewChat(_ change: LampAgentRemoteChoices, kind: String) {
        // The request already went with what was shown.
        guard !isStartingChat else { return }
        var chosen = newChatChoices[kind] ?? LampAgentRemoteChoices()
        if let provider = change.provider, provider != chosen.provider {
            chosen = LampAgentRemoteChoices(provider: provider)
        }
        if chosen.provider == nil { chosen.provider = setup?.defaultProvider(forKind: kind) }
        if let model = change.model {
            chosen.model = model
            // An effort carried on the model doesn't outlast it, as on the Mac.
            if setup?.provider(chosen.provider ?? setup?.defaultProvider(forKind: kind))?.effortIsOnTheModel == true {
                chosen.effort = nil
            }
        }
        if let effort = change.effort {
            chosen.effort = effort
            // An effort written on the model is that model's: kept with the
            // model it was chosen for, not whatever the Mac's default
            // becomes.
            if let provider = setup?.provider(chosen.provider), provider.effortIsOnTheModel, chosen.model == nil {
                chosen.model = provider.defaultModel
            }
        }
        newChatChoices[kind] = chosen
    }

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
        var begun = newChat(words)
        // What the setup row showed, named whole, so the chat begins on just
        // that: a Mac keeps a writing on whatever its pane pinned unless the
        // provider, model and effort are named.
        let shown = newChatShown(kind: begun.kind)
        begun.provider = shown.provider ?? begun.provider
        begun.model = shown.model ?? begun.model
        begun.effort = shown.effort ?? begun.effort
        let request = LampAgentRemoteMessage.startChat(begun)
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
