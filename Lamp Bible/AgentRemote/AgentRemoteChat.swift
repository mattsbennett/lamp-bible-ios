import Foundation
import LampCore

/// The chat this device has open: core's view of it, as the Mac's snapshot
/// and events leave it (`LampAgentRemoteChatView`, which both apps keep the
/// same way), and what only the phone knows besides.
struct AgentRemoteChat: Equatable {
    /// What the Mac's snapshot and events say.
    var view: LampAgentRemoteChatView
    /// What this device sent, shown until the Mac's turn begins with it.
    /// The client clears it, since only it knows which messages were there
    /// before the send.
    var sending: String?
    /// What went wrong with a request this device made in the chat, as
    /// opposed to the Mac's own account of the last turn (`view.notice`).
    var requestProblem: String?

    init(_ snapshot: LampAgentRemoteChatSnapshot) {
        view = LampAgentRemoteChatView(snapshot)
    }

    var id: String { view.id }
    var summary: LampAgentRemoteChatSummary { view.summary }
    var messages: [LampAgentRemoteChatMessage] { view.messages }
    var partialReply: String? { view.partialReply }
    var activity: LampAgentRemoteActivity? { view.activity }
    var isRunning: Bool { view.isRunning }
    /// What's said about an answer given here to a request the turn waited
    /// on, when it may not have been the one taken: a line of its own, so
    /// it hides neither this device's request problem nor the Mac's account
    /// of the turn.
    var approvalNotice: String?
    /// The request it's about, as shown (`digest(of:)`): an answer taken to
    /// that request, and no other, settles it.
    var approvalNoticeDigest: String?
    /// The turn it's about, by its question: a later one's requests aren't
    /// what it speaks of.
    var approvalNoticeTurn: UUID?

    /// The question the latest turn answers, running or not.
    var lastQuestion: UUID? {
        messages.last { $0.role == LampAgentRemoteChatMessage.user }?.id
    }

    /// A notice about an earlier turn's answer goes once another turn has
    /// begun, however that's learned: an event, or a snapshot on coming back.
    mutating func dropNoticeFromAnotherTurn() {
        guard approvalNotice != nil, approvalNoticeTurn != lastQuestion else { return }
        approvalNotice = nil
        approvalNoticeDigest = nil
        approvalNoticeTurn = nil
    }
    /// The one problem line: this device's request, or the last turn's.
    var problem: String? { requestProblem ?? view.notice }
    /// What the running turn waits on the person for, oldest first: none
    /// from a Mac older than this, which takes no answer from a device.
    var approvals: [LampAgentRemoteApproval] { view.approvals }

    /// What a request is answered by, as shown in this chat's running turn
    /// (`LampAgentRemoteApproval.digest`): its every field byte for byte,
    /// which `==` isn't (it takes two spellings of an accent as one), with
    /// the chat and the turn, so the same request in a later turn is another.
    func digest(of approval: LampAgentRemoteApproval) -> String {
        LampAgentRemoteApproval.digest(chatID: id, turnID: view.turnID, approval: approval)
    }

    /// Takes a request answered here out of the list, as the Mac's reply
    /// says it's no longer waiting: the one shown, exactly, in the turn it
    /// was shown in. A request the Mac has changed meanwhile under the same
    /// id stays, and so does the same request in a later turn: Codex numbers
    /// its requests afresh each turn, and a reply can arrive after the next
    /// turn has begun.
    mutating func drop(answered answer: AgentRemoteApprovalAnswer) {
        guard answer.chatID == id else { return }
        let (chatID, turnID) = (id, view.turnID)
        view.approvals.removeAll {
            LampAgentRemoteApproval.digest(chatID: chatID, turnID: turnID, approval: $0) == answer.digest
        }
    }

    mutating func apply(_ snapshot: LampAgentRemoteChatSnapshot) {
        view.apply(snapshot)
    }

    /// What the Mac's event says. The bubble for a message on its way is
    /// the client's to clear, since only it knows which request is this
    /// device's.
    mutating func apply(_ event: LampAgentRemoteChatEvent) {
        guard event.chatID == view.id else { return }
        view.apply(event)
        // A question can arrive as a `reply`, a turn stopped before it began.
        dropNoticeFromAnotherTurn()
        if event.kind == LampAgentRemoteChatEvent.turnStarted {
            requestProblem = nil
            approvalNotice = nil
            approvalNoticeDigest = nil
            approvalNoticeTurn = nil
        }
    }

    /// What a running turn is doing, in a few words.
    static func describe(_ activity: LampAgentRemoteActivity?) -> String {
        guard let activity else { return "Working…" }
        switch activity.kind {
        case LampAgentRemoteActivity.thinking:
            return "Thinking…"
        case LampAgentRemoteActivity.toolStarted, LampAgentRemoteActivity.tool:
            let name = activity.name.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Using a tool"
            if let summary = activity.summary, !summary.isEmpty { return "\(name): \(summary)" }
            return "\(name)…"
        case LampAgentRemoteActivity.writing:
            return "Writing…"
        default:
            return "Working…"
        }
    }
}

/// A writing's revision and body digest as stored here now, which the Mac
/// checks its own copy against before the assistant works on it. Read at
/// the moment of sending, so a copy sync brought since counts.
///
/// Nil when the writing can't be read here: nothing is sent then, since a
/// message without a stamp reads to the Mac as one from an older phone,
/// which it doesn't check.
enum AgentRemoteWritingStamp {
    static let unreadable = "This writing couldn’t be read on this device. Try again."

    static func current(writingID: String) async -> (revision: Int?, digest: String)? {
        await Task.detached(priority: .userInitiated) {
            // A writing's id isn't spelled alike on every platform: the Mac's
            // chat may name it in another case than it's kept in here.
            let spellings = [writingID, writingID.uppercased(), writingID.lowercased()]
            guard let entry = spellings.lazy.compactMap({ (try? ModuleDatabase.shared.getDevotionalEntry(id: $0)).flatMap({ $0 }) }).first else {
                return nil
            }
            let revision = entry.lastModified.map {
                LampAgentRemoteWritingRevision.of(lastModified: Date(timeIntervalSince1970: TimeInterval($0)))
            }
            return (revision, LampAgentRemoteWritingRevision.digest(of: entry.writingFileRow(moduleID: entry.moduleId)))
        }.value
    }
}

/// Which of this device's messages a question arriving from the Mac is.
enum AgentRemoteAcknowledgement {
    struct Pending: Equatable {
        let id: UUID
        let chatID: String
        let words: String
        /// The chat's messages when it was sent.
        let known: Set<UUID>
    }

    /// The pending messages `asked` is: the one its request names; or, from a
    /// Mac that has never named one, by its words and an id not seen when it
    /// was sent. From a Mac that names requests, a question without one was
    /// asked on the Mac or by another device, and is none of them.
    static func arrived(
        _ asked: LampAgentRemoteChatMessage,
        in chatID: String,
        requestID: UUID?,
        hostNamesRequests: Bool,
        pending: [Pending]
    ) -> Set<UUID> {
        if let requestID {
            return pending.contains { $0.id == requestID } ? [requestID] : []
        }
        guard !hostNamesRequests else { return [] }
        return Set(pending.filter {
            $0.chatID == chatID && $0.words == asked.text && !$0.known.contains(asked.id)
        }.map(\.id))
    }
}

/// What a refusal's code means to the person holding the phone.
enum AgentRemoteFailureText {
    static func text(code: String?, message: String?) -> String {
        switch code {
        case LampAgentRemoteFailure.busy:
            return "A reply is still being written on your Mac. Send again when it finishes."
        case LampAgentRemoteFailure.notFound:
            return "That chat is no longer on your Mac."
        case LampAgentRemoteFailure.needsSetup:
            // The Mac's words are a failed preparation's own, not written for
            // a phone: told after, as what went wrong there.
            let setUp = "The AI provider needs setting up on your Mac. Open Lamp Bible there to finish."
            guard let said = message?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty else { return setUp }
            return "\(setUp) Your Mac said: \u{201C}\(said)\u{201D}"
        case LampAgentRemoteFailure.writingBehind:
            // The Mac says why, as when the writing is open there.
            return message ?? "Your Mac doesn’t have your latest edits to this writing yet. Try again once it has synced."
        case LampAgentRemoteFailure.aiOff:
            return "AI features are turned off."
        case LampAgentRemoteFailure.notAllowed:
            return "Your Mac doesn’t allow that from this device."
        default:
            return message ?? "Your Mac couldn’t do that."
        }
    }
}

/// This device's answer to a request a turn waits on (`decisions/0040`):
/// Allow Once or Deny, never a remembered rule, and Allow only for what the
/// Mac says can be shown whole here.
struct AgentRemoteApprovalAnswer: Equatable {
    let requestID: UUID
    let chatID: String
    /// The request as shown, in its chat and turn (`AgentRemoteChat.digest`).
    let digest: String
    /// That turn, by its question.
    let turnID: UUID?
    let decision: String
    /// The request in a few words, for what's said of the answer: two
    /// requests waiting, a notice must say which answer it's about.
    let label: String

    /// A short name for a request: its command's first line, cut short, or
    /// its title.
    static func label(of approval: LampAgentRemoteApproval) -> String {
        let line = approval.command?.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let words = line.isEmpty ? approval.title : line
        return words.count > 40 ? String(words.prefix(40)) + "…" : words
    }

    /// The answer, as its button named it.
    var decisionName: String {
        decision == LampAgentRemoteApprovalAnswer.allowOnce ? "Allow Once" : "Deny"
    }

    var unheard: String {
        "The connection ended before your Mac said whether it took your \(decisionName) of “\(label)”. Check the chat on your Mac."
    }

    var notTaken: String {
        "Your \(decisionName) of “\(label)” wasn’t taken: the request had already been answered on your Mac or another device, had changed since it was shown here, or had ended."
    }

    var noReply: String {
        "Your Mac hasn’t said whether it took your \(decisionName) of “\(label)”. Check the chat on your Mac."
    }

    /// Whether a request can be allowed from this device: the Mac says so
    /// (`canAllow`) of a command it sent whole, and only then.
    static func offersAllow(_ approval: LampAgentRemoteApproval) -> Bool {
        // The Mac's word, and this device's own check of what it was sent:
        // the command and the folder its relative paths are read from, both
        // there and both drawable whole. An earlier Mac could say yes to a
        // command with no folder.
        approval.canAllow && approval.kind == LampAgentRemoteApproval.command
            && LampAgentRemoteApproval.mayAllow(command: approval.command, folder: approval.folder)
    }

    /// What the Mac's reply to an answer means for the card.
    enum Settled: Equatable {
        /// Taken, or no longer waiting as shown (answered on the Mac or by
        /// another device, ended, timed out): the card goes. One not taken
        /// says so, since the first answer anywhere is the one taken and it
        /// may have been the other: a command denied here may be running.
        case drop(notice: String?)
        /// Not taken, and still waiting: the card stays, saying why.
        case keep(problem: String)
    }

    /// `answered` for an `approval-answered`; else the failure's code and
    /// words.
    func settle(answered: Bool, errorCode: String?, message: String?) -> Settled {
        if answered { return .drop(notice: nil) }
        if errorCode == LampAgentRemoteFailure.approvalGone { return .drop(notice: notTaken) }
        if errorCode == LampAgentRemoteFailure.notAllowed { return .keep(problem: Self.onlyOnTheMac) }
        return .keep(problem: AgentRemoteFailureText.text(code: errorCode, message: message))
    }

    static let onlyOnTheMac = "This can only be allowed on your Mac."
}
