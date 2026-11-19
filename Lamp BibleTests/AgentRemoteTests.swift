//
//  AgentRemoteTests.swift
//  Lamp BibleTests
//
//  The phone's own part of following a Mac's chats. The protocol, the
//  connection machine and the chat view are core's, tested there against the
//  Mac's host; these cover what the phone keeps on top: the paired Macs in its
//  memory as core's connection asks, the message on its way, and the words.
//

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
}
