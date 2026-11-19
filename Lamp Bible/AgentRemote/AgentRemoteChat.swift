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
    /// The one problem line: this device's request, or the last turn's.
    var problem: String? { requestProblem ?? view.notice }

    mutating func apply(_ snapshot: LampAgentRemoteChatSnapshot) {
        view.apply(snapshot)
    }

    /// What the Mac's event says. The bubble for a message on its way is
    /// the client's to clear, since only it knows which request is this
    /// device's.
    mutating func apply(_ event: LampAgentRemoteChatEvent) {
        guard event.chatID == view.id else { return }
        view.apply(event)
        if event.kind == LampAgentRemoteChatEvent.turnStarted { requestProblem = nil }
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
            return "The AI provider needs setting up on your Mac. Open Lamp Bible there to finish."
        case LampAgentRemoteFailure.aiOff:
            return "AI features are turned off."
        case LampAgentRemoteFailure.notAllowed:
            return "Your Mac doesn’t allow that from this device."
        default:
            return message ?? "Your Mac couldn’t do that."
        }
    }
}
