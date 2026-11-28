import CloudKit
import Combine
import Foundation
import LampCore
import UIKit
import UserNotifications

/// The notification of a finished turn when Lamp isn't running to hear it:
/// a push through the person's own iCloud, with no server of ours.
///
/// When a turn this device asked for ends and the phone isn't there to hear
/// it, the Mac saves an `AgentTurnEnded` record to the private database. This
/// device holds a subscription to the records naming its own pairings, and
/// iOS shows the alert the subscription describes, from the record's fields,
/// with Lamp suspended or not running at all.
///
/// A subscription is the iCloud account's, not the device's: CloudKit pushes
/// it to every device signed in to the account with Lamp, and has no way to
/// send to one. Each device's subscription fires only for its own pairings'
/// turns, so a turn is pushed once, with the preview its own device chose;
/// another of the person's devices shows it too while Lamp isn't running
/// there, and hides it while Lamp is open (`belongsHere`). A push can't be
/// folded into the phone's own notification of the same turn, so only one of
/// them tells: the phone's while Lamp is open (dropping the push), and the
/// push once Lamp is left and that Mac's pushes are known to come.
///
/// The alert's words have to be plain fields for iCloud to put them in a
/// push: the title, and the reply's opening when both apps' "Show the start
/// of the reply" allow it. Best effort: a push can come late or not at all,
/// and the chat itself is what's true.
enum AgentTurnPush {
    static let containerIdentifier = "iCloud.com.neus.lamp-bible"
    static let recordType = "AgentTurnEnded"
    /// The subscription's id, with this install's own after it, so each
    /// device keeps one and changes only its own.
    static let subscriptionPrefix = "agent-turn-ended."

    /// The record's fields, as the Mac writes them.
    enum Field {
        static let deviceID = "deviceID"
        static let chatID = "chatID"
        static let kind = "kind"
        static let writingID = "writingID"
        static let turnID = "turnID"
        static let title = "title"
        static let subtitle = "subtitle"
        /// The alert without any of the reply: "Replied.", or why it stopped.
        static let summary = "summary"
        /// The reply's opening where the Mac's setting allows it; otherwise
        /// the same as `summary`.
        static let body = "body"
    }

    /// The localization key for a field shown as it is: no string table has
    /// it, so iOS takes the key itself as the format.
    static let asIs = "%@"

    /// What the subscription should be: nil for none.
    struct Wanted: Equatable, Sendable {
        var deviceIDs: [String]
        var showsReply: Bool

        var fingerprint: String {
            (deviceIDs.sorted() + [showsReply ? "reply" : "summary"]).joined(separator: "|")
        }
    }

    private static let installKey = "agent.turnPush.installID"
    private static let savedKey = "agent.turnPush.saved"
    /// Set when the iCloud account changes: whether this install has a
    /// subscription there isn't known, so none wanted means one deleted.
    private static let unconfirmedKey = "agent.turnPush.unconfirmed"

    static var subscriptionID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: installKey) { return subscriptionPrefix + id }
        let id = UUID().uuidString
        defaults.set(id, forKey: installKey)
        // A new install, perhaps over one whose subscription iCloud still
        // holds: looked for once, whatever is wanted.
        defaults.set(true, forKey: unconfirmedKey)
        return subscriptionPrefix + id
    }

    /// Whether this install's subscription is saved, so a push will tell of
    /// a turn the phone also hears.
    static var isSubscribed: Bool {
        UserDefaults.standard.string(forKey: savedKey) != nil
    }

    private static let pushSeenKey = "agent.turnPush.seenFrom"

    /// Whether a push of a turn asked under this pairing has ever reached
    /// this device: proof its Mac writes them, which a saved subscription
    /// alone isn't, nor another Mac's push. Until then the phone's own
    /// notification of that Mac's turns is never the quiet one.
    static func pushSeen(from deviceID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: pushSeenKey) ?? []).contains(deviceID)
    }

    static func notePushSeen(from deviceID: String?) {
        guard let deviceID, !pushSeen(from: deviceID) else { return }
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: pushSeenKey) ?? []) + [deviceID], forKey: pushSeenKey)
    }

    /// The subscription asked for by the settings and the Macs paired now.
    @MainActor
    static func wanted(hosts: [LampAgentRemoteRememberedHost] = AgentRemoteMemory.shared.hosts) -> Wanted? {
        guard AgentTurnNotifications.isEnabledNow else { return nil }
        let ids = Array(Set(hosts.map(\.deviceID).filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty else { return nil }
        return Wanted(deviceIDs: ids, showsReply: AgentTurnNotifications.showsReplyNow)
    }

    /// Brings the subscription in line with what's wanted now, when it isn't
    /// already: on launch and on returning to Lamp, when the settings change
    /// and when a Mac is paired or forgotten. One at a time; a failure is
    /// tried again at the next.
    @MainActor
    static func refresh() {
        observeAccount()
        let wanted = wanted()
        // For an earlier install's subscription, looked for whatever's wanted.
        let pairings = AgentRemoteMemory.shared.hosts.map(\.deviceID).filter { !$0.isEmpty }
        if wanted != nil { UIApplication.shared.registerForRemoteNotifications() }
        let id = subscriptionID
        Task { await Subscriber.shared.request(wanted, pairings: pairings, subscriptionID: id) }
    }

    @MainActor private static var accountObserver: NSObjectProtocol?
    @MainActor private static var aiObserver: AnyCancellable?

    /// Another iCloud account signed in: what was saved was the last one's,
    /// and this one may hold a subscription of this install's from before,
    /// which is looked for whatever is wanted now. And the AI features
    /// turned off or on: the subscription goes or comes with them, judged
    /// once the new choice is stored.
    @MainActor
    private static func observeAccount() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.removeObject(forKey: savedKey)
                UserDefaults.standard.set(true, forKey: unconfirmedKey)
                // Pushes seen came to the last account; this one's are yet to.
                UserDefaults.standard.removeObject(forKey: pushSeenKey)
                Task {
                    await Subscriber.shared.forgetCheck()
                    await MainActor.run { refresh() }
                }
            }
        }
        aiObserver = AIFeatures.shared.$isEnabled
            .dropFirst()
            .removeDuplicates()
            // `@Published` tells before it stores.
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { refresh() } }
    }

    static func subscription(for wanted: Wanted, id: String) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(format: "%K IN %@", Field.deviceID, wanted.deviceIDs),
            subscriptionID: id,
            // A chat's record is written over by its next turn's.
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = asIs
        info.titleLocalizationArgs = [Field.title]
        info.subtitleLocalizationKey = asIs
        info.subtitleLocalizationArgs = [Field.subtitle]
        info.alertLocalizationKey = asIs
        info.alertLocalizationArgs = [wanted.showsReply ? Field.body : Field.summary]
        info.soundName = "default"
        info.category = AgentTurnNotifications.categoryIdentifier
        // What a tap needs to lead back, to tell a turn already heard, and to
        // tell whose it is: three at most, as CloudKit allows. A writing's
        // chat is named `writing:<id>`, which says the writing.
        info.desiredKeys = [Field.chatID, Field.turnID, Field.deviceID]
        subscription.notificationInfo = info
        return subscription
    }

    struct PushedTurn: Equatable {
        var route: AgentTurnRoute
        var chatID: String
        var turnID: String?
        /// The pairing the turn was asked under: this device's, or another's
        /// signed in to the same iCloud.
        var deviceID: String?
        /// A request the turn waits on the person for, not its end
        /// (`decisions/0045`): named `wait.` where an end is `turn.`, with a
        /// `turnID` of its own, so it's never heard as the turn's end.
        var isWait = false
        /// The record it tells of, by name.
        var recordName: String?
    }

    /// A writing's chat is the Mac's `writing:<id>`.
    static let writingChatPrefix = "writing:"

    /// A push of a Lamp subscription, read: where it leads, which turn it
    /// tells of, and whose. Nil for anything else.
    static func turn(fromPush userInfo: [AnyHashable: Any]) -> PushedTurn? {
        guard userInfo["ck"] != nil,
              let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.subscriptionID?.hasPrefix(subscriptionPrefix) == true,
              notification.recordFields != nil || notification.recordID != nil else { return nil }
        let fields = notification.recordFields ?? [:]
        func text(_ key: String) -> String? { (fields[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        // CloudKit may leave fields out of a push; the record's name,
        // `turn.<deviceID>.<chatID>`, says the chat and the pairing too.
        let named = notification.recordID.flatMap { Self.parts(ofRecordName: $0.recordName) }
        guard let chatID = text(Field.chatID) ?? named?.chatID else { return nil }
        let writingID = chatID.hasPrefix(writingChatPrefix) ? String(chatID.dropFirst(writingChatPrefix.count)) : ""
        return PushedTurn(
            route: writingID.isEmpty ? .readerChat(chatID) : .writing(writingID),
            chatID: chatID, turnID: text(Field.turnID), deviceID: text(Field.deviceID) ?? named?.deviceID,
            isWait: named?.isWait ?? false, recordName: notification.recordID?.recordName
        )
    }

    private static let endPrefix = "turn."
    private static let waitPrefix = "wait."

    /// The pairing and the chat a record is named for, and whether it's of
    /// a request waiting rather than the turn's end.
    static func parts(ofRecordName name: String) -> (deviceID: String, chatID: String, isWait: Bool)? {
        let isWait = name.hasPrefix(waitPrefix)
        guard isWait || name.hasPrefix(endPrefix) else { return nil }
        let rest = name.dropFirst((isWait ? waitPrefix : endPrefix).count)
        guard let dot = rest.firstIndex(of: "."), dot != rest.startIndex else { return nil }
        let chatID = rest[rest.index(after: dot)...]
        guard !chatID.isEmpty else { return nil }
        return (String(rest[..<dot]), String(chatID), isWait)
    }

    @MainActor private static var sweep: Task<Void, Never>?

    /// Looks again, shortly, at the alerts of requests waiting: when the
    /// Mac says nothing waits in a chat, and on coming back to Lamp. Again
    /// a while later for any still standing, as the Mac's deletion of the
    /// record may land after its word to the phone.
    @MainActor
    static func sweepWaitsSoon() {
        sweep?.cancel()
        sweep = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, await sweepWaits() else { return }
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            _ = await sweepWaits()
        }
    }

    /// Takes away the alerts of requests no longer waiting. The Mac deletes
    /// a wait's record once nothing waits in its chat, or the turn ends, but
    /// can't recall an alert already shown: each is kept while its record
    /// stands as the same wait, by the `turnID` each wait has its own of. A
    /// record that can't be looked at keeps its alert. Whether any alert of
    /// a request waiting is left.
    static func sweepWaits() async -> Bool {
        let center = UNUserNotificationCenter.current()
        var shown: [String: [(id: String, wait: String?)]] = [:]
        for alert in await center.deliveredNotifications() {
            guard let pushed = turn(fromPush: alert.request.content.userInfo), pushed.isWait,
                  let name = pushed.recordName else { continue }
            shown[name, default: []].append((alert.request.identifier, pushed.turnID))
        }
        guard !shown.isEmpty else { return false }
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        guard let results = try? await database.records(
            for: shown.keys.map { CKRecord.ID(recordName: $0) }, desiredKeys: [Field.turnID]
        ) else { return true }
        var over: [String] = []
        var left = 0
        for (id, result) in results {
            let alerts = shown[id.recordName] ?? []
            switch result {
            case .success(let record):
                let current = record[Field.turnID] as? String
                let (stale, standing) = alerts.reduce(into: ([String](), 0)) { sorted, alert in
                    if Self.isOver(alert: alert.wait, current: current) { sorted.0.append(alert.id) } else { sorted.1 += 1 }
                }
                over += stale
                left += standing
            case .failure(let error as CKError) where error.code == .unknownItem:
                over += alerts.map(\.id)
            case .failure:
                left += alerts.count
            }
        }
        if !over.isEmpty { center.removeDeliveredNotifications(withIdentifiers: over) }
        return left > 0
    }

    /// Whether an alert of the wait `alert` is over, its record standing for
    /// the wait `current`: another wait's, a later request's, when both are
    /// known. One that names none is kept while the record stands.
    static func isOver(alert: String?, current: String?) -> Bool {
        guard let alert, let current else { return false }
        return alert.caseInsensitiveCompare(current) != .orderedSame
    }

    /// Whether a pushed turn was asked under one of this device's pairings.
    /// One with no device named is taken as this device's.
    @MainActor
    static func belongsHere(_ turn: PushedTurn, hosts: [LampAgentRemoteRememberedHost] = AgentRemoteMemory.shared.hosts) -> Bool {
        guard let deviceID = turn.deviceID else { return true }
        return hosts.contains { $0.deviceID == deviceID }
    }

    /// Saves and deletes the subscription, one change at a time, remembering
    /// what was saved so an unchanged one isn't saved again. A request made
    /// while one is being carried out waits, and only the latest is carried
    /// out after it.
    actor Subscriber {
        static let shared = Subscriber()
        private lazy var database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        /// Whether the saved subscription has been looked for in iCloud
        /// since launch: one deleted there, by a reset, is saved again.
        private var checkedThisLaunch = false
        private var latest: (wanted: Wanted?, pairings: [String], id: String)?
        private var working = false

        /// Moved on at each change of iCloud account, so a save for the last
        /// account finishing after it doesn't stand for the new one.
        private var generation = 0

        func forgetCheck() {
            checkedThisLaunch = false
            generation += 1
        }

        /// Deletes Lamp's subscriptions other than `id` whose predicate names
        /// one of these pairings, which are this device's alone.
        /// Whether none is left: false when they couldn't be looked for or
        /// deleted.
        private func removeEarlierInstalls(naming pairings: [String], except id: String) async -> Bool {
            guard !pairings.isEmpty else { return true }
            guard let all = try? await database.allSubscriptions() else { return false }
            let earlier = all.compactMap { $0 as? CKQuerySubscription }.filter { subscription in
                subscription.subscriptionID != id && subscription.subscriptionID.hasPrefix(subscriptionPrefix)
                    && pairings.contains { subscription.predicate.predicateFormat.contains("\"\($0)\"") }
            }.map(\.subscriptionID)
            guard !earlier.isEmpty else { return true }
            guard let results = try? await database.modifySubscriptions(saving: [], deleting: earlier) else { return false }
            return results.deleteResults.values.allSatisfy { result in
                if case .failure(let error as CKError) = result { return error.code == .unknownItem }
                if case .failure = result { return false }
                return true
            }
        }

        func request(_ wanted: Wanted?, pairings: [String], subscriptionID: String) async {
            latest = (wanted, pairings, subscriptionID)
            guard !working else { return }
            working = true
            defer { working = false }
            while let next = latest {
                latest = nil
                await reconcile(next.wanted, pairings: next.pairings, subscriptionID: next.id)
            }
        }

        private func reconcile(_ wanted: Wanted?, pairings: [String], subscriptionID: String) async {
            let defaults = UserDefaults.standard
            let generation = self.generation
            var saved = defaults.string(forKey: savedKey)
            let unconfirmed = defaults.bool(forKey: unconfirmedKey)
            if saved == wanted?.fingerprint, !unconfirmed, wanted == nil || checkedThisLaunch { return }
            // Not signed in to iCloud: nothing can be saved, and the next
            // look tries again.
            guard (try? await CKContainer(identifier: containerIdentifier).accountStatus()) == .available else { return }
            if saved != nil, saved == wanted?.fingerprint {
                do {
                    _ = try await database.subscription(for: subscriptionID)
                    checkedThisLaunch = true
                    // Kept, but an earlier install's still to look for first.
                    guard defaults.bool(forKey: unconfirmedKey) else { return }
                    if await removeEarlierInstalls(naming: pairings, except: subscriptionID), generation == self.generation {
                        defaults.removeObject(forKey: unconfirmedKey)
                    }
                    return
                } catch let error as CKError where error.code == .unknownItem {
                    saved = nil
                } catch {
                    return
                }
            }
            // Nothing saved here, as after a reinstall that kept the pairings
            // in the Keychain: an earlier install's subscription naming them
            // would go on telling of their turns, with its own preview, so
            // it goes before this one is made.
            // Not cleaned, the look stays owed and is made again next time.
            var cleaned = true
            if saved == nil || unconfirmed {
                cleaned = await removeEarlierInstalls(naming: pairings, except: subscriptionID)
                // With none wanted, this install's own id is deleted below too:
                // the account may hold it from before a switch.
                if cleaned, wanted != nil, saved == wanted?.fingerprint, generation == self.generation {
                    defaults.removeObject(forKey: unconfirmedKey)
                }
            }
            do {
                if let wanted {
                    // Saving under the same id replaces what was there.
                    let results = try await database.modifySubscriptions(
                        saving: [AgentTurnPush.subscription(for: wanted, id: subscriptionID)], deleting: []
                    )
                    _ = try results.saveResults[subscriptionID]?.get()
                    guard generation == self.generation else { return }
                    defaults.set(wanted.fingerprint, forKey: savedKey)
                    if cleaned { defaults.removeObject(forKey: unconfirmedKey) }
                    checkedThisLaunch = true
                } else {
                    let results = try await database.modifySubscriptions(saving: [], deleting: [subscriptionID])
                    do {
                        try results.deleteResults[subscriptionID]?.get()
                    } catch let error as CKError where error.code == .unknownItem {
                        // Gone already.
                    }
                    guard generation == self.generation else { return }
                    defaults.removeObject(forKey: savedKey)
                    if cleaned { defaults.removeObject(forKey: unconfirmedKey) }
                }
            } catch {
                print("[AgentTurnPush] subscription not changed: \(error.localizedDescription)")
            }
        }
    }
}
