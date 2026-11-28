import Foundation
import LampCore
import UIKit
import UserNotifications

/// Where a finished turn's notification takes the reader when it's tapped.
enum AgentTurnRoute: Equatable, Sendable {
    /// A reader chat, by the Mac's id for it, in the reader's Chat panel.
    case readerChat(String)
    /// A writing's assistant, by the writing's id.
    case writing(String)

    private static let kindKey = "lampTurnRouteKind"
    private static let idKey = "lampTurnRouteID"

    var userInfo: [String: String] {
        switch self {
        case .readerChat(let id): [Self.kindKey: "readerChat", Self.idKey: id]
        case .writing(let id): [Self.kindKey: "writing", Self.idKey: id]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo[Self.kindKey] as? String,
              let id = userInfo[Self.idKey] as? String, !id.isEmpty else { return nil }
        switch kind {
        case "readerChat": self = .readerChat(id)
        case "writing": self = .writing(id)
        default: return nil
        }
    }

}

/// A notification when a turn this device asked the Mac for finishes while
/// its chat isn't on screen: the phone is the one who asked, so the Mac
/// leaves telling to it.
///
/// Off until it's turned on in Settings, and only while AI features are on.
/// The phone hears the Mac only while Lamp runs: in Lamp, or for the short
/// while iOS lets it finish after it's left. Not for a turn stopped from
/// this device, which its reader was there for.
@MainActor
enum AgentTurnNotifications {
    // The Mac's keys, for the same choices.
    nonisolated static let enabledKey = "agent.turnNotifications.enabled"
    nonisolated static let showsReplyKey = "agent.turnNotifications.showsReply"
    nonisolated static let categoryIdentifier = "lamp.agent-turn"

    /// How a turn ended, as the notification says it.
    enum Outcome: Equatable {
        case replied(String)
        case failed(String)
        /// Over, by the list's word, with how it ended not known here.
        case finished
    }

    /// What a turn's notification is shown under: one per chat, the newest
    /// turn's in place of the last.
    nonisolated static func identifier(chatID: String) -> String {
        "lamp.agent-turn.\(chatID)"
    }

    static var isEnabledNow: Bool {
        AIFeatures.shared.isEnabled && UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// On unless turned off: the start of the reply is the useful part.
    static var showsReplyNow: Bool {
        UserDefaults.standard.object(forKey: showsReplyKey) as? Bool ?? true
    }

    /// Asked when the setting is turned on, never at launch. Once the person
    /// has answered, the system returns that answer without asking.
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(
        _ outcome: Outcome, title: Title, route: AgentTurnRoute, chatID: String,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard isEnabledNow else {
            completion?()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title.title
        if let subtitle = title.subtitle { content.subtitle = subtitle }
        content.body = body(for: outcome, showsReply: showsReplyNow)
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = identifier(chatID: chatID)
        content.userInfo = route.userInfo
        let request = UNNotificationRequest(identifier: identifier(chatID: chatID), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in completion?() }
    }

    static func body(for outcome: Outcome, showsReply: Bool) -> String {
        switch outcome {
        case .replied(let reply):
            let excerpt = showsReply ? excerpt(of: reply) : ""
            return excerpt.isEmpty ? "Replied." : excerpt
        case .failed(let failure):
            return "Couldn\u{2019}t finish: \(failure)"
        case .finished:
            return "Finished."
        }
    }

    /// The reply's opening as plain words, as the Mac gives it: Markdown's
    /// marks taken off, links reduced to their text, whitespace run
    /// together, and cut at a word near `limit` characters.
    nonisolated static func excerpt(of markdown: String, limit: Int = 180) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: "```[\\s\\S]*?(```|$)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?m)^[ \\t]*(#{1,6}[ \\t]+|>[ \\t]?|[-*+][ \\t]+|\\d+[.)][ \\t]+)",
            with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "(\\*\\*|__|\\*|_|`)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)) + "\u{2026}"
    }

    struct Title: Equatable {
        var title: String
        var subtitle: String?
    }

    /// What the notification is headed: a writing's name; or a reader chat,
    /// under the Mac's title for it, which is its opening question.
    static func title(of summary: LampAgentRemoteChatSummary) -> Title {
        if summary.writingID != nil {
            return Title(title: summary.subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Writing Assistant")
        }
        let chat = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Title(title: "Reader Chat", subtitle: chat.isEmpty || chat == "New Chat" ? nil : chat)
    }

    static func route(of summary: LampAgentRemoteChatSummary) -> AgentTurnRoute {
        summary.writingID.map(AgentTurnRoute.writing) ?? .readerChat(summary.id)
    }
}

/// Lamp's notifications while it's open: a finished turn's shows even with
/// Lamp in front, since it's sent only when its chat is out of view; the
/// reading reminder keeps the system's default of not showing then. A tap on
/// a turn's leads back to its chat.
///
/// The completion-handler forms, each handler called on the main queue: the
/// system's completion of a tap updates the app's snapshot, which UIKit
/// asserts is on the main thread, and an `async` method returning on the
/// cooperative pool brought Lamp down there (2026-11-22, a tapped push).
final class AgentTurnNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentTurnNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                completionHandler(Self.presentation(of: content))
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if content.categoryIdentifier == AgentTurnNotifications.categoryIdentifier {
                    let pushed = AgentTurnPush.turn(fromPush: content.userInfo)
                    if let pushed, !pushed.isWait { AgentTurnPush.notePushSeen(from: pushed.deviceID) }
                    if let route = AgentTurnRoute(userInfo: content.userInfo) ?? pushed?.route {
                        DeepLinkManager.shared.show(route)
                    }
                }
                completionHandler()
            }
        }
    }

    /// iCloud's push: not shown here for another device's turn, one this
    /// device heard end, or one on screen; and, shown, it's heard, so the
    /// phone's own word of the same turn isn't given again.
    /// A request waiting is shown unless its chat is on screen, where its
    /// card is, and is never heard: the turn's end is still to tell.
    @MainActor
    private static func presentation(of content: UNNotificationContent) -> UNNotificationPresentationOptions {
        guard content.categoryIdentifier == AgentTurnNotifications.categoryIdentifier else { return [] }
        guard let pushed = AgentTurnPush.turn(fromPush: content.userInfo) else { return [.banner, .sound, .list] }
        // Only a turn's end says the Mac's push of an end will come.
        if !pushed.isWait { AgentTurnPush.notePushSeen(from: pushed.deviceID) }
        if pushed.isWait {
            guard AgentTurnNotifications.isEnabledNow, AgentTurnPush.belongsHere(pushed),
                  !AgentRemoteClient.shared.isWatching(chatID: pushed.chatID, deviceID: pushed.deviceID) else { return [] }
            return [.banner, .sound, .list]
        }
        guard AgentTurnNotifications.isEnabledNow, AgentTurnPush.belongsHere(pushed),
              !AgentRemoteClient.shared.hasHeard(chatID: pushed.chatID, turnID: pushed.turnID, deviceID: pushed.deviceID) else { return [] }
        AgentRemoteClient.shared.noteHeard(chatID: pushed.chatID, turnID: pushed.turnID)
        return [.banner, .sound, .list]
    }
}
