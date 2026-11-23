//
//  AgentRemoteTests.swift
//  Lamp BibleTests
//
//  The phone's own part of following a Mac's chats. The protocol, the
//  connection machine and the chat view are core's, tested there against the
//  Mac's host; these cover what the phone keeps on top: the paired Macs in its
//  memory as core's connection asks, the message on its way, and the words.
//

import CloudKit
import LampCore
import XCTest
@testable import Lamp_Bible

final class AgentRemoteTests: XCTestCase {
    private final class InMemorySecrets: PresenterSecretStorage {
        var items: [String: Data] = [:]
        func load() -> [String: Data] { items }
        func save(_ data: Data, for id: String) { items[id] = data }
        func delete(_ id: String) { items[id] = nil }
    }

    /// The Mac's side of one connection, made from core's handshake.
    private final class FakeHost {
        let secret = LampAgentRemoteHandshake.generateHostSecret()
        var paired: [LampAgentRemoteDeviceCredential] = []
        var pairingCode: String? = "ABCDEFGHJKLMNPQR"
        var start: LampAgentRemoteHandshake.HostStart!
        var channel: LampAgentRemoteSecureChannel?
        var buffer = Data()

        func open() throws -> Data {
            channel = nil
            buffer = Data()
            start = LampAgentRemoteHandshake.hostStart(hostSecret: secret)
            return try LampAgentRemoteFraming.encode(start.hello)
        }

        /// The reply to the device's bytes, or nil where the host would close.
        func take(_ data: Data) throws -> Data? {
            buffer.append(data)
            guard channel == nil else { return Data() }
            guard let auth = try LampAgentRemoteFraming.decode(LampAgentRemoteAuth.self, from: &buffer) else { return Data() }
            var candidates = paired.compactMap(LampAgentRemoteCredential.device)
            if let pairingCode, let pairing = LampAgentRemoteCredential.pairing(code: pairingCode) {
                candidates.append(pairing)
            }
            guard let (credential, channel) = try? LampAgentRemoteHandshake.accept(auth, start: start, candidates: candidates) else {
                return nil
            }
            self.channel = channel
            if credential.kind == .pairing {
                let minted = LampAgentRemoteDeviceCredential.generate()
                paired.append(minted)
                pairingCode = nil
                return try channel.seal(.accepted(pairing: minted, hostSecret: secret))
            }
            return try channel.seal(.accepted())
        }
    }

    private var memory: AgentRemoteMemory!
    private var host: FakeHost!

    override func setUp() {
        memory = AgentRemoteMemory(storage: InMemorySecrets())
        host = FakeHost()
    }

    private func connection() -> LampAgentRemoteDeviceConnection {
        LampAgentRemoteDeviceConnection(remembered: memory.hosts, hostName: "Study Mac", clientName: "iPhone")
    }

    private func sent(_ effects: [LampAgentRemoteDeviceConnection.Effect]) -> Data {
        effects.reduce(into: Data()) { data, effect in
            if case let .send(bytes) = effect { data.append(bytes) }
        }
    }

    /// What the client does with core's remember and forget.
    private func keep(_ effects: [LampAgentRemoteDeviceConnection.Effect]) {
        for effect in effects {
            if case let .remember(remembered) = effect { memory.remember(remembered) }

        }
    }

    private func pair() throws {
        var device = connection()
        keep(device.receive(try host.open()))
        let accepted = try XCTUnwrap(host.take(sent(device.pair(code: "ABCDEFGHJKLMNPQR"))))
        keep(device.receive(accepted))
    }

    // MARK: - Memory

    /// Addresses a Mac is reached at, as over Tailscale: kept on this
    /// device, tied to the Mac once it answers, and gone when it's forgotten.
    @MainActor
    func testAddressesAreKeptAndTiedToTheirMac() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agent-remote-addresses-\(UUID().uuidString)"))
        let book = AgentRemoteAddressBook(defaults: defaults)
        let tailnet = try XCTUnwrap(LampAgentRemoteAddress.parse("100.90.115.76"))
        let fallback = try XCTUnwrap(LampAgentRemoteAddress.parse("[fd7a:115c:a1e0::9c01:734c]:50192"))
        book.keep(tailnet)
        book.keep(fallback, name: "Study Mac", pairing: "pairing-a")
        book.keep(tailnet, name: "Study Mac", pairing: "pairing-a")
        XCTAssertEqual(book.entries.map(\.text), [tailnet.text, fallback.text])
        XCTAssertEqual(book.entries.first?.name, "Study Mac", "what's learned of an address is added to it")
        XCTAssertEqual(book.entries.map(\.address), [tailnet, fallback])

        // The client lists them after the Macs Bonjour finds, by the Mac's name.
        let client = AgentRemoteClient(memory: AgentRemoteMemory(storage: InMemorySecrets()), addressBook: book)
        XCTAssertEqual(client.hosts.map(\.name), ["Study Mac", "Study Mac"])
        XCTAssertEqual(client.hosts.compactMap(\.address), [tailnet, fallback])
        XCTAssertFalse(client.connect(toAddress: "https://example.com"), "not an address")

        // Bonjour's name for the Mac noted; a new pairing takes the addresses.
        book.found(pairing: "pairing-a", bonjourName: "Lamp Bible on Study Mac")
        XCTAssertEqual(book.entries.map(\.bonjourName), ["Lamp Bible on Study Mac", "Lamp Bible on Study Mac"])
        book.repoint(from: ["pairing-a"], to: "pairing-b")
        XCTAssertEqual(book.entries.map(\.pairing), ["pairing-b", "pairing-b"])
        // No secret kept in preferences.
        let stored = try XCTUnwrap(defaults.data(forKey: "agentRemote.addresses"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("ecret"))
        book.forget(pairing: "pairing-b")
        XCTAssertTrue(book.entries.isEmpty)
    }

    /// A pairing code carries the Mac's addresses, which the phone keeps.
    func testAPairingCodeCarriesItsMacsAddresses() throws {
        let tailnet = try XCTUnwrap(LampAgentRemoteAddress.parse("100.90.115.76"))
        let payload = try XCTUnwrap(LampAgentRemoteHandshake.qrPayload(for: "ABCDEFGHJKLMNPQR", addresses: [tailnet]))
        XCTAssertNotNil(LampAgentRemoteHandshake.code(fromQRPayload: payload))
        XCTAssertEqual(LampAgentRemoteHandshake.addresses(fromQRPayload: payload), [tailnet])
    }

    /// A reply is read as prose, as the writing's editor reads it: its
    /// blocks laid out, a soft wrap joined, and no Markdown left showing.
    func testAReplyIsLaidOutAsItsMarkdownSays() {
        let reply = "## Summary\nJohn 3 turns on a\nsingle word.\n\n- **born again**\n- born *from above*\n\n> Unless one is born\n\n```\nlet x = 1\n```\n\nSee [verse 3](lampbible://verse/43003003)."
        let drawn = AgentRemotePanel.reply(reply, toolText: LampToolText(size: 16, typeface: "sans", lineSpacing: 4)).string
        XCTAssertEqual(drawn, "Summary\n\nJohn 3 turns on a single word.\n\n•\tborn again\n•\tborn from above\n\nUnless one is born\n\nlet x = 1\n\nSee verse 3.")
    }

    /// A reply grows a piece at a time as it streams: each piece draws only
    /// its last block again, so a long reply costs no more per piece than a
    /// short one (the old reader read the whole reply again on every redraw).
    /// Timings printed, for reading; the count is what's held.
    func testAGrowingReplyDrawsOnlyItsEnd() {
        let paragraph = "The **wind** blows where it wishes, and you hear its sound, but you do not know where it comes from or where it goes.\n\n- one point\n- another point\n\n"
        let full = String(repeating: paragraph, count: 30)
        let toolText = LampToolText(size: 16, typeface: "serif", lineSpacing: 4.25)
        let pieces = stride(from: 200, through: full.count, by: 200).map { String(full.prefix($0)) }
        let longest = LampProse.pieces(of: full).map(\.utf8.count).max() ?? 0
        let readBefore = AgentRemotePanel.replyBytesDrawn
        let began = Date()
        for piece in pieces { for _ in 0..<3 { _ = AgentRemotePanel.reply(piece, toolText: toolText) } }
        let read = AgentRemotePanel.replyBytesDrawn - readBefore
        print("REPLYTIME \(full.utf8.count) bytes, \(pieces.count) pieces x 3, \(Int(Date().timeIntervalSince(began) * 1000)) ms, \(read) bytes read")
        // The reply once, plus at most each piece's unfinished end, never the
        // whole reply again at each piece.
        XCTAssertLessThanOrEqual(read, full.utf8.count + pieces.count * longest)
        // Kept whole where cutting would change what's read.
        XCTAssertEqual(LampProse.pieces(of: "1. one\n\n1. two").count, 1, "a list counts on across a blank line")
        XCTAssertEqual(LampProse.pieces(of: "See [it][ref].\n\nMore.\n\n[ref]: https://example.com").count, 1, "a link finds its target")
        XCTAssertEqual(LampProse.pieces(of: "```\na\n\nb\n```\n\nAfter").count, 2, "a fence isn't cut")
        XCTAssertEqual(LampProse.pieces(of: "```\na\n    ```\n\nstill code\n```").count, 1, "nor closed four spaces in")
        XCTAssertEqual(LampProse.pieces(of: "See [it][src].\n\n> [src]: https://example.com").count, 1)
        XCTAssertEqual(LampProse.pieces(of: "<pre>\na\n\n**b**\n</pre>").count, 1)
    }

    func testPairingIsKeptAndTheNextConnectionAnswersWithIt() throws {
        try pair()
        XCTAssertEqual(memory.hosts.map(\.name), ["Study Mac"])
        XCTAssertEqual(memory.hosts.first?.deviceID, host.paired.first?.deviceID)

        var device = connection()
        let effects = device.receive(try host.open())
        XCTAssertFalse(effects.contains { if case .needsCode = $0 { return true }; return false })
        let accepted = try XCTUnwrap(host.take(sent(effects)))
        XCTAssertTrue(device.receive(accepted).contains { if case .connected = $0 { return true }; return false })
        XCTAssertEqual(device.hostSecret, host.secret)
    }

    /// Turned away, a key is passed over next time rather than deleted: a
    /// replayed hello, or a slow network, mustn't undo a real pairing.
    func testAKeyTheMacTurnsAwayIsKeptButNotOffered() throws {
        try pair()
        host.paired = []
        host.pairingCode = nil
        var device = connection()
        let effects = device.receive(try host.open())
        XCTAssertNil(try host.take(sent(effects)))
        let closed = device.closed(byHost: true, reason: nil)
        keep(closed)
        XCTAssertTrue(closed.contains { if case .pairAgain = $0 { return true }; return false })
        XCTAssertTrue(closed.contains { if case .keyRefused = $0 { return true }; return false })
        XCTAssertEqual(memory.hosts.count, 1)
    }

    func testPairingAgainReplacesTheMacsEarlierKey() throws {
        try pair()
        let first = try XCTUnwrap(memory.hosts.first)
        // Paired again with the earlier key passed over, as after a refusal.
        host.paired = []
        host.pairingCode = "ABCDEFGHJKLMNPQR"
        var device = LampAgentRemoteDeviceConnection(remembered: [], hostName: "Study Mac", clientName: "iPhone")
        keep(device.receive(try host.open()))
        keep(device.receive(try XCTUnwrap(host.take(sent(device.pair(code: "ABCDEFGHJKLMNPQR"))))))
        XCTAssertEqual(memory.hosts.count, 1)
        XCTAssertNotEqual(memory.hosts.first?.deviceKey, first.deviceKey)
    }

    // MARK: - The open chat

    private func snapshot() -> LampAgentRemoteChatSnapshot {
        LampAgentRemoteChatSnapshot(
            summary: LampAgentRemoteChatSummary(
                id: "chat", title: "Romans 5", kind: LampAgentRemoteChatSummary.reader,
                provider: "claude", providerName: "Claude", acceptsMessages: true
            ),
            messages: [LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "Why abound?", date: Date())]
        )
    }

    func testATurnStartingClearsTheDevicesRequestProblem() {
        var chat = AgentRemoteChat(snapshot())
        chat.requestProblem = "A reply is still being written."
        chat.apply(LampAgentRemoteChatEvent(
            chatID: "chat", kind: LampAgentRemoteChatEvent.turnStarted,
            message: LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "And grace?", date: Date())
        ))
        XCTAssertNil(chat.problem)
        XCTAssertTrue(chat.isRunning)
    }

    // MARK: - Which message arrived

    private let asked = LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "And grace?", date: Date())

    private func pending(_ id: UUID = UUID(), words: String = "And grace?", known: Set<UUID> = []) -> AgentRemoteAcknowledgement.Pending {
        AgentRemoteAcknowledgement.Pending(id: id, chatID: "chat", words: words, known: known)
    }

    func testTheRequestTheMacNamesIsTheOneThatArrived() {
        let mine = pending()
        let other = pending(words: "And grace?")
        let arrived = AgentRemoteAcknowledgement.arrived(
            asked, in: "chat", requestID: mine.id, hostNamesRequests: true, pending: [mine, other]
        )
        XCTAssertEqual(arrived, [mine.id])
    }

    /// From a Mac that names requests, the same words asked on the Mac are
    /// someone else's question.
    func testTheSameWordsAskedElsewhereArentThisDevicesMessage() {
        let arrived = AgentRemoteAcknowledgement.arrived(
            asked, in: "chat", requestID: nil, hostNamesRequests: true, pending: [pending()]
        )
        XCTAssertTrue(arrived.isEmpty)
    }

    func testAMacFromBeforeRequestIDsIsMatchedByWords() {
        let mine = pending()
        let earlier = pending(known: [asked.id])
        let arrived = AgentRemoteAcknowledgement.arrived(
            asked, in: "chat", requestID: nil, hostNamesRequests: false, pending: [mine, earlier]
        )
        XCTAssertEqual(arrived, [mine.id])
    }

    func testTheProblemLineIsTheDevicesRequestOrElseTheLastTurns() {
        var chat = AgentRemoteChat(snapshot())
        chat.apply(LampAgentRemoteChatEvent(chatID: "chat", kind: LampAgentRemoteChatEvent.failed, text: "The provider stopped."))
        XCTAssertEqual(chat.problem, "The provider stopped.")
        chat.requestProblem = "Your Mac couldn’t do that."
        XCTAssertEqual(chat.problem, "Your Mac couldn’t do that.")
    }

    // MARK: - Words

    func testActivityReadsAsAShortLine() {
        XCTAssertEqual(AgentRemoteChat.describe(LampAgentRemoteActivity(kind: LampAgentRemoteActivity.thinking)), "Thinking…")
        XCTAssertEqual(
            AgentRemoteChat.describe(LampAgentRemoteActivity(kind: LampAgentRemoteActivity.tool, name: "read passage", summary: "Romans 5:20")),
            "Read passage: Romans 5:20"
        )
        XCTAssertEqual(AgentRemoteChat.describe(LampAgentRemoteActivity(kind: "later")), "Working…")
    }

    func testFailureCodesAndProblemsReadAsWhatToDo() {
        XCTAssertTrue(AgentRemoteFailureText.text(code: LampAgentRemoteFailure.busy, message: nil).contains("still being written"))
        XCTAssertEqual(AgentRemoteFailureText.text(code: "later", message: "Something new."), "Something new.")
        XCTAssertEqual(AgentRemoteProblemText.text(.refused), AgentRemoteProblemText.refused)
        XCTAssertEqual(AgentRemoteProblemText.text(.unreachable("No route.")), "No route.")
    }

    // MARK: - Turn notifications

    func testATurnRouteComesBackFromItsNotification() {
        for route in [AgentTurnRoute.readerChat("A1B2"), .writing("w-1")] {
            XCTAssertEqual(AgentTurnRoute(userInfo: route.userInfo), route)
        }
        XCTAssertNil(AgentTurnRoute(userInfo: ["lampTurnRouteKind": "later", "lampTurnRouteID": "x"]))
        XCTAssertNil(AgentTurnRoute(userInfo: ["lampTurnRouteKind": "writing", "lampTurnRouteID": ""]))
        // One notification per chat, the Mac's push of a turn in its place.
        XCTAssertEqual(AgentTurnNotifications.identifier(chatID: "writing:w1"), "lamp.agent-turn.writing:w1")
    }

    @MainActor
    func testANotificationSaysTheReplyAsPlainWords() {
        XCTAssertEqual(
            AgentTurnNotifications.excerpt(of: "## Grace\n\n**Grace** is [favour](https://x.org) shown.\n\n```\ncode\n```"),
            "Grace Grace is favour shown."
        )
        let long = String(repeating: "word ", count: 80)
        let cut = AgentTurnNotifications.excerpt(of: long)
        XCTAssertTrue(cut.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(cut.count, 181)
        XCTAssertEqual(AgentTurnNotifications.body(for: .replied("Yes."), showsReply: false), "Replied.")
        XCTAssertEqual(AgentTurnNotifications.body(for: .replied(""), showsReply: true), "Replied.")
        XCTAssertEqual(AgentTurnNotifications.body(for: .failed("Usage limit."), showsReply: true), "Couldn\u{2019}t finish: Usage limit.")
        XCTAssertEqual(AgentTurnNotifications.body(for: .finished, showsReply: true), "Finished.")
    }

    @MainActor
    func testANotificationIsNamedForItsChat() {
        let reader = LampAgentRemoteChatSummary(
            id: "c1", title: "What does born again mean?", kind: LampAgentRemoteChatSummary.reader,
            provider: "claude", providerName: "Claude", acceptsMessages: true
        )
        XCTAssertEqual(
            AgentTurnNotifications.title(of: reader),
            .init(title: "Reader Chat", subtitle: "What does born again mean?")
        )
        XCTAssertEqual(AgentTurnNotifications.route(of: reader), .readerChat("c1"))
        let writing = LampAgentRemoteChatSummary(
            id: "writing:w1", title: "Assistant", subtitle: "Walking by Faith", kind: LampAgentRemoteChatSummary.writing,
            writingID: "w1", provider: "claude", providerName: "Claude", acceptsMessages: true
        )
        XCTAssertEqual(AgentTurnNotifications.title(of: writing), .init(title: "Walking by Faith"))
        XCTAssertEqual(AgentTurnNotifications.route(of: writing), .writing("w1"))
    }

    /// The reply told is the one after the turn's own question, never an
    /// earlier answer or the question itself.
    @MainActor
    func testTheReplyToldAnswersTheTurnsQuestion() {
        func message(_ role: String, _ text: String) -> LampAgentRemoteChatMessage {
            LampAgentRemoteChatMessage(id: UUID(), role: role, text: text, date: Date())
        }
        let earlier = message(LampAgentRemoteChatMessage.user, "First?")
        let earlierReply = message(LampAgentRemoteChatMessage.assistant, "First answer.")
        let asked = message(LampAgentRemoteChatMessage.user, "Second?")
        let reply = message(LampAgentRemoteChatMessage.assistant, "Second answer.")
        XCTAssertEqual(AgentRemoteClient.reply(to: asked.id, in: [earlier, earlierReply, asked, reply]), "Second answer.")
        XCTAssertNil(AgentRemoteClient.reply(to: asked.id, in: [earlier, earlierReply, asked]), "Stopped before answering")
        XCTAssertNil(AgentRemoteClient.reply(to: UUID(), in: [earlier, earlierReply]))
        XCTAssertNil(AgentRemoteClient.reply(to: nil, in: [earlier, earlierReply]))
        let later = message(LampAgentRemoteChatMessage.user, "Third?")
        XCTAssertNil(AgentRemoteClient.reply(to: asked.id, in: [asked, later, reply]), "Not a later question's answer")
    }

    // MARK: - iCloud push

    func testTheSubscriptionAsksForThisDevicesTurnsAndSaysThemAsWritten() throws {
        let wanted = AgentTurnPush.Wanted(deviceIDs: ["d2", "d1"], showsReply: true)
        let subscription = AgentTurnPush.subscription(for: wanted, id: "agent-turn-ended.X")
        XCTAssertEqual(subscription.recordType, AgentTurnPush.recordType)
        XCTAssertEqual(subscription.querySubscriptionOptions, [.firesOnRecordCreation, .firesOnRecordUpdate])
        // CloudKit's copy of a predicate can't be evaluated here: read as written.
        let format = subscription.predicate.predicateFormat
        XCTAssertTrue(format.hasPrefix("deviceID IN"), format)
        XCTAssertTrue(format.contains("\"d1\"") && format.contains("\"d2\""), format)
        let info = try XCTUnwrap(subscription.notificationInfo)
        XCTAssertEqual(info.titleLocalizationArgs, ["title"])
        XCTAssertEqual(info.subtitleLocalizationArgs, ["subtitle"])
        XCTAssertEqual(info.alertLocalizationArgs, ["body"])
        XCTAssertEqual(info.category, AgentTurnNotifications.categoryIdentifier)
        // A collapse id is sent as it is, never read from the record: one for
        // every chat would fold different chats' alerts together.
        XCTAssertNil(info.collapseIDKey)
        // CloudKit sends three fields at most.
        XCTAssertEqual(Set(info.desiredKeys ?? []), ["chatID", "turnID", "deviceID"])
        // Without the reply, only the words that hold none of it.
        let quiet = AgentTurnPush.subscription(for: .init(deviceIDs: ["d1"], showsReply: false), id: "agent-turn-ended.X")
        XCTAssertEqual(quiet.notificationInfo?.alertLocalizationArgs, ["summary"])
        // The same wish, however its Macs are ordered, is saved once.
        XCTAssertEqual(wanted.fingerprint, AgentTurnPush.Wanted(deviceIDs: ["d1", "d2"], showsReply: true).fingerprint)
        XCTAssertNotEqual(wanted.fingerprint, AgentTurnPush.Wanted(deviceIDs: ["d1", "d2"], showsReply: false).fingerprint)
    }

    func testAPushLeadsBackToItsChat() throws {
        func push(_ fields: [String: Any], subscription: String = "agent-turn-ended.X") -> [AnyHashable: Any] {
            [
                "aps": ["alert": ["title": "Reader Chat", "body": "Replied."]],
                "ck": [
                    "ce": 2, "cid": AgentTurnPush.containerIdentifier, "nid": UUID().uuidString,
                    "qry": [
                        "dbs": 2, "fo": 2, "rid": "turn.d1.c1", "sid": subscription,
                        "zid": "_defaultZone", "zoid": "_defaultOwner", "af": fields,
                    ],
                ],
            ]
        }
        let reader = try XCTUnwrap(AgentTurnPush.turn(fromPush: push(["chatID": "c1", "turnID": "T1", "deviceID": "d1"])))
        XCTAssertEqual(reader.route, .readerChat("c1"))
        XCTAssertEqual(reader.turnID, "T1")
        XCTAssertEqual(reader.deviceID, "d1")
        let writing = try XCTUnwrap(AgentTurnPush.turn(fromPush: push(["chatID": "writing:w1"])))
        XCTAssertEqual(writing.route, .writing("w1"))
        XCTAssertNil(writing.turnID)
        XCTAssertEqual(writing.deviceID, "d1", "Named by the record when the field is left out")
        XCTAssertNil(AgentTurnPush.turn(fromPush: push(["chatID": "c1"], subscription: "someone-else")))
        // Fields left out of the push: the record's name says the chat.
        let pruned = try XCTUnwrap(AgentTurnPush.turn(fromPush: push([:])))
        XCTAssertEqual(pruned.route, .readerChat("c1"))
        XCTAssertEqual(pruned.deviceID, "d1")
        XCTAssertEqual(AgentTurnPush.parts(ofRecordName: "turn.d1.writing:w.1")?.chatID, "writing:w.1")
        XCTAssertNil(AgentTurnPush.parts(ofRecordName: "turn..c1"))
        XCTAssertNil(AgentTurnPush.parts(ofRecordName: "other.d1.c1"))
        XCTAssertNil(AgentTurnPush.turn(fromPush: ["aps": ["alert": "Reading time"]]))
    }

    /// A turn's events are matched by the turn they name, and a later
    /// question shows an earlier turn is over.
    func testATurnIsKnownByItsOwnQuestion() {
        let first = UUID(), second = UUID()
        XCTAssertTrue(AgentRemoteClient.isSameTurn(first, first))
        XCTAssertFalse(AgentRemoteClient.isSameTurn(first, second))
        XCTAssertTrue(AgentRemoteClient.isSameTurn(first, nil), "An older Mac names no turn")
        XCTAssertTrue(AgentRemoteClient.isSameTurn(nil, second))
        let asked = LampAgentRemoteChatMessage(id: first, role: LampAgentRemoteChatMessage.user, text: "A?", date: Date())
        let answer = LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.assistant, text: "A.", date: Date())
        let next = LampAgentRemoteChatMessage(id: second, role: LampAgentRemoteChatMessage.user, text: "B?", date: Date())
        XCTAssertFalse(AgentRemoteClient.isSuperseded(first, in: [asked, answer]))
        XCTAssertTrue(AgentRemoteClient.isSuperseded(first, in: [asked, answer, next]))
        XCTAssertFalse(AgentRemoteClient.isSuperseded(UUID(), in: [asked, answer, next]))
    }
}
