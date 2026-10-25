import Combine
import Foundation
import LampCore
import Network
import Security
import UIKit

/// A presenter this device has paired with, remembered so that it need not
/// be paired again: the code the presenter minted for this device, which is
/// its key for every frame on a later connection, and the presenter's secret,
/// by which this device recognises it.
struct RememberedPresenter: Codable, Equatable, Identifiable {
    var id: String
    /// What the presenter was called on the network when it was paired: a
    /// label to forget it by, never something to decide anything by.
    var name: String
    var deviceCode: String
    var presenterSecret: String
    var pairedAt: Date
}

/// Where remembered presenters are kept, each as data under an id.
protocol PresenterSecretStorage: AnyObject {
    func load() -> [String: Data]
    func save(_ data: Data, for id: String)
    func delete(_ id: String)
}

/// The Keychain, on this device only: a device code is that device's
/// long-lived key to the presenter, so it is not synced through iCloud
/// Keychain, nor restored to another device from a backup. It can be used
/// once the device has been unlocked after starting up.
final class KeychainPresenterSecrets: PresenterSecretStorage {
    private let service: String

    init(service: String = "com.neus.Lamp-Bible.presentation-remote") {
        self.service = service
    }

    func load() -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [:] }
        var found: [String: Data] = [:]
        for item in items {
            if let id = item[kSecAttrAccount as String] as? String,
               let data = item[kSecValueData as String] as? Data {
                found[id] = data
            }
        }
        return found
    }

    func save(_ data: Data, for id: String) {
        delete(id)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete(_ id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The presenters this device remembers, and which of them a presenter's
/// public challenge says it is.
final class PresentationRemoteMemory {
    static let shared = PresentationRemoteMemory(storage: KeychainPresenterSecrets())

    private let storage: PresenterSecretStorage

    init(storage: PresenterSecretStorage) {
        self.storage = storage
    }

    var presenters: [RememberedPresenter] {
        storage.load().values
            .compactMap { try? JSONDecoder().decode(RememberedPresenter.self, from: $0) }
            .sorted { ($0.name, $0.pairedAt) < ($1.name, $1.pairedAt) }
    }

    /// The remembered presenter whose secret made `hint` for this challenge.
    ///
    /// Recognition only: it says which saved code to offer. What admits this
    /// device is still the presenter accepting the pairing proof sealed
    /// under that code.
    func recognising(hint: String?, challenge: String) -> RememberedPresenter? {
        guard let hint, !hint.isEmpty else { return nil }
        return presenters.first {
            LampPresentationRemotePairing.presenterMatches(
                secret: $0.presenterSecret,
                hint: hint,
                challenge: challenge
            )
        }
    }

    /// Keeps what a presenter sent on accepting this device, in place of
    /// what was kept for the same presenter before.
    @discardableResult
    func remember(name: String, deviceCode: String, presenterSecret: String) -> RememberedPresenter {
        let earlier = presenters.first { $0.presenterSecret == presenterSecret }
        let presenter = RememberedPresenter(
            id: earlier?.id ?? UUID().uuidString,
            name: name,
            deviceCode: deviceCode,
            presenterSecret: presenterSecret,
            pairedAt: Date()
        )
        if let data = try? JSONEncoder().encode(presenter) {
            storage.save(data, for: presenter.id)
        }
        return presenter
    }

    func forget(_ id: String) {
        storage.delete(id)
    }
}

/// The turns of pairing with a presenter, and what the remote does at each:
/// offer a saved code where the presenter is recognised, ask for the QR code
/// where it is not, and keep what the presenter sends on accepting.
///
/// A saved code the presenter turns away is forgotten, and the remote pairs
/// again by QR code, saying why. The presenter turning it away is what
/// forgetting a remote on the Mac comes to, so without that a forgotten
/// remote would be refused at every connection, silently. A connection lost
/// to the network is not a refusal, and leaves the code kept.
struct PresentationRemotePairingFlow {
    enum Step: Equatable {
        /// Pair now, with this presenter's saved code.
        case offer(RememberedPresenter)
        /// Show the pairing screen, with this to say, if anything.
        case askForCode(notice: String?)
        case presenting
        /// The saved code was turned away and is forgotten: connect again,
        /// to pair by QR code, and say this.
        case pairAgain(notice: String)
        case failed(String)
    }

    static let refusedNotice = "This Mac no longer recognises this device. Scan its pairing code to pair again."
    static let pairingFailed = "Pairing failed. Check the code and choose the presenter again."

    let memory: PresentationRemoteMemory
    /// The remembered presenter whose code is on offer, until it is accepted
    /// or turned away.
    private(set) var offered: RememberedPresenter?

    init(memory: PresentationRemoteMemory) {
        self.memory = memory
    }

    mutating func challenge(hint: String?, challenge: String, notice: String? = nil) -> Step {
        offered = memory.recognising(hint: hint, challenge: challenge)
        if let offered { return .offer(offered) }
        return .askForCode(notice: notice)
    }

    /// The presenter accepted this device. A code and secret sent with it
    /// are kept for next time, under the name the presenter goes by.
    mutating func accepted(deviceCode: String?, presenterSecret: String?, presenterName: String) -> Step {
        offered = nil
        if let deviceCode = deviceCode.flatMap(LampPresentationRemotePairing.normalizedCode),
           let presenterSecret, !presenterSecret.isEmpty {
            memory.remember(name: presenterName, deviceCode: deviceCode, presenterSecret: presenterSecret)
        }
        return .presenting
    }

    mutating func rejected(_ message: String?) -> Step {
        if let refused = takeOffered() { return refused }
        return .askForCode(notice: message ?? "Pairing was rejected.")
    }

    /// No answer to the saved code offered, on a connection that carried
    /// the presenter's challenge, so is plainly up: a presenter that cannot
    /// open what was sent under a code it no longer knows waits, saying
    /// nothing, rather than answer a device it cannot tell from anyone.
    mutating func savedCodeUnanswered() -> Step {
        takeOffered() ?? .failed(Self.pairingFailed)
    }

    /// A reply that would not open under the code offered.
    mutating func unreadableReply() -> Step {
        if let refused = takeOffered() { return refused }
        return .failed(Self.pairingFailed)
    }

    /// The connection ended before the presenter accepted this device:
    /// closed by the presenter, or lost.
    mutating func closedBeforeAccepted(byPresenter: Bool, reason: String?) -> Step {
        if byPresenter, let refused = takeOffered() { return refused }
        if offered != nil {
            offered = nil
            return .failed(reason ?? "The Mac could not be reached. Try again.")
        }
        return .failed(Self.pairingFailed)
    }

    private mutating func takeOffered() -> Step? {
        guard let refused = offered else { return nil }
        offered = nil
        memory.forget(refused.id)
        return .pairAgain(notice: Self.refusedNotice)
    }
}

final class PresentationRemoteClient: ObservableObject {
    enum Phase: Equatable {
        case stopped
        case browsing
        case connecting
        case awaitingPairing
        case pairing
        case presenting
        /// The Mac closed the connection mid-presentation: it quit, or ended the
        /// presentation. Distinct from `failed`, which leaves something to retry.
        case ended
        case failed(String)
    }

    struct Presenter: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint

        static func == (lhs: Presenter, rhs: Presenter) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var presenters: [Presenter] = []
    @Published private(set) var selectedPresenterName = "Presentation"
    @Published private(set) var presentationState: LampPresentationRemoteState?
    @Published private(set) var pairingError: String?
    /// The presenters this device will be let in by without pairing again.
    @Published private(set) var rememberedPresenters: [RememberedPresenter] = []
    /// Whether a saved code is on offer to the presenter, awaiting its answer.
    @Published private(set) var isOfferingSavedCode = false

    private let queue = DispatchQueue(label: "com.neus.lamp-bible.presentation-remote-client")
    private let memory: PresentationRemoteMemory
    private var flow: PresentationRemotePairingFlow
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pairingChallenge: String?
    /// The code this connection's frames are sealed under: the session's
    /// pairing code, or the saved code offered in its place.
    private var activePairingCode: String?
    /// The presenter last chosen, to connect to again to pair by QR code
    /// when its saved code is turned away.
    private var lastPresenter: Presenter?
    /// What the pairing screen is to say when it next opens.
    private var pendingNotice: String?
    /// How long a presenter has to answer a saved code before it is taken
    /// as turned away: its answer is immediate where it knows the code.
    static let savedCodeWait: TimeInterval = 6

    /// What this device calls itself to the presenter, which the Mac shows
    /// in its list of remembered remotes. Since iOS 16 that is the model,
    /// "iPhone" or "iPad", rather than the name the owner gave the device,
    /// which an app reads only with Apple's device-name entitlement: two
    /// iPhones are told apart on the Mac by when they were paired.
    static var clientName: String { UIDevice.current.name }

    init(memory: PresentationRemoteMemory = .shared) {
        self.memory = memory
        flow = PresentationRemotePairingFlow(memory: memory)
        rememberedPresenters = memory.presenters
    }

    func forget(_ presenter: RememberedPresenter) {
        memory.forget(presenter.id)
        rememberedPresenters = memory.presenters
    }

    func startBrowsing() {
        browser?.cancel()
        connection?.cancel()
        connection = nil
        pairingChallenge = nil
        activePairingCode = nil
        presentationState = nil
        pairingError = nil
        presenters = []
        rememberedPresenters = memory.presenters
        phase = .browsing

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(
                type: LampPresentationRemoteProtocol.bonjourServiceType,
                domain: nil
            ),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    guard self.browser === browser else { return }
                    self.phase = .browsing
                }
            case let .failed(error):
                DispatchQueue.main.async {
                    guard self.browser === browser else { return }
                    self.phase = .failed(error.localizedDescription)
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser else { return }
            let presenters = results.compactMap { result -> Presenter? in
                guard case let .service(name, type, domain, interface) = result.endpoint else {
                    return nil
                }
                let endpoint = NWEndpoint.service(
                    name: name,
                    type: type,
                    domain: domain,
                    interface: interface
                )
                return Presenter(id: endpoint.debugDescription, name: name, endpoint: endpoint)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                guard self.browser === browser else { return }
                self.presenters = presenters
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func connect(to presenter: Presenter) {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        pairingError = nil
        presentationState = nil
        pairingChallenge = nil
        activePairingCode = nil
        isOfferingSavedCode = false
        flow = PresentationRemotePairingFlow(memory: memory)
        lastPresenter = presenter
        selectedPresenterName = presenter.name
        phase = .connecting
        receiveBuffer = Data()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: presenter.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                break
            case let .failed(error):
                DispatchQueue.main.async {
                    guard self.connection === connection else { return }
                    self.connectionClosed(error: error)
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
        receive(from: connection)
    }

    func pair(code: String) {
        guard let connection,
              let pairingChallenge,
              let normalized = LampPresentationRemotePairing.normalizedCode(code) else { return }
        pairingError = nil
        activePairingCode = normalized
        phase = .pairing
        sendSecure(.hello(clientName: Self.clientName), over: connection)
        sendSecure(.pair(code: normalized, challenge: pairingChallenge), over: connection)
    }

    func send(_ command: LampPresentationRemoteCommand) {
        guard phase == .presenting, let connection else { return }
        sendSecure(.command(command), over: connection)
    }

    func stop() {
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        receiveBuffer = Data()
        pairingChallenge = nil
        activePairingCode = nil
        isOfferingSavedCode = false
        pendingNotice = nil
        flow = PresentationRemotePairingFlow(memory: memory)
        presenters = []
        presentationState = nil
        pairingError = nil
        phase = .stopped
    }

    private func receive(from connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                do {
                    if let pairingCode = self.activePairingCode {
                        let messages = try LampPresentationRemoteSecureFrameCodec.decodeFrames(
                            from: &self.receiveBuffer,
                            pairingCode: pairingCode
                        )
                        messages.forEach { self.handle($0, from: connection) }
                    } else {
                        let messages = try LampPresentationRemoteFrameCodec.decodeFrames(
                            from: &self.receiveBuffer
                        )
                        messages.forEach { self.handlePairingChallenge($0, from: connection) }
                    }
                } catch {
                    let sealed = self.activePairingCode != nil
                    DispatchQueue.main.async {
                        guard self.connection === connection else { return }
                        if sealed {
                            self.apply(self.flow.unreadableReply(), on: connection)
                        } else {
                            self.phase = .failed("The presenter sent an invalid response.")
                        }
                    }
                    connection.cancel()
                    return
                }
            }

            if isComplete || error != nil {
                DispatchQueue.main.async {
                    guard self.connection === connection else { return }
                    self.connectionClosed(error: error)
                }
            } else {
                self.receive(from: connection)
            }
        }
    }

    /// The connection is over. A presenter that closed it while presenting —
    /// cleanly, or by its process going away (a reset) — has ended the session;
    /// anything else is a failure worth showing.
    private func connectionClosed(error: NWError?) {
        switch phase {
        case .failed, .ended, .stopped:
            return
        case .presenting:
            if error == nil || error == .posix(.ECONNRESET) {
                phase = .ended
                return
            }
            phase = .failed(error?.localizedDescription ?? "The presentation connection ended.")
        case .pairing:
            // Closed by the presenter, cleanly or by a reset, rather than
            // lost: for a saved code on offer, the presenter turning it away.
            let byPresenter = error == nil || error == .posix(.ECONNRESET)
            apply(
                flow.closedBeforeAccepted(byPresenter: byPresenter, reason: error?.localizedDescription),
                on: nil
            )
        default:
            phase = .failed(error?.localizedDescription ?? "The presentation connection ended.")
        }
    }

    private func handlePairingChallenge(
        _ message: LampPresentationRemoteMessage,
        from connection: NWConnection
    ) {
        guard message.protocolVersion == LampPresentationRemoteProtocol.currentVersion else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === connection else { return }
                self.phase = .failed("This presenter uses an incompatible remote version.")
            }
            return
        }

        guard message.kind == .hello,
              let challenge = message.pairingChallenge,
              !challenge.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === connection else { return }
                self.phase = .failed("The presenter did not provide a valid pairing challenge.")
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            self.pairingChallenge = challenge
            let notice = self.pendingNotice
            self.pendingNotice = nil
            self.apply(
                self.flow.challenge(hint: message.presenterHint, challenge: challenge, notice: notice),
                on: connection
            )
        }
    }

    /// Does what the pairing flow says to next.
    private func apply(_ step: PresentationRemotePairingFlow.Step, on connection: NWConnection?) {
        switch step {
        case let .offer(saved):
            guard let connection, let pairingChallenge else { return }
            isOfferingSavedCode = true
            // Everything on this connection is sealed under the saved code
            // from here, as the presenter seals it under whichever code the
            // proof opened under.
            activePairingCode = saved.deviceCode
            phase = .pairing
            sendSecure(.hello(clientName: Self.clientName), over: connection)
            sendSecure(.pair(code: saved.deviceCode, challenge: pairingChallenge), over: connection)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.savedCodeWait) { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection,
                      self.flow.offered?.id == saved.id, self.phase == .pairing else { return }
                connection.cancel()
                self.apply(self.flow.savedCodeUnanswered(), on: nil)
            }
        case let .askForCode(notice):
            isOfferingSavedCode = false
            pairingError = notice
            phase = .awaitingPairing
        case .presenting:
            isOfferingSavedCode = false
            pairingError = nil
            rememberedPresenters = memory.presenters
            phase = .presenting
        case let .pairAgain(notice):
            isOfferingSavedCode = false
            rememberedPresenters = memory.presenters
            pendingNotice = notice
            if let lastPresenter {
                connect(to: lastPresenter)
            } else {
                phase = .failed(notice)
            }
        case let .failed(message):
            isOfferingSavedCode = false
            phase = .failed(message)
        }
    }

    private func handle(_ message: LampPresentationRemoteMessage, from connection: NWConnection) {
        guard message.protocolVersion == LampPresentationRemoteProtocol.currentVersion else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === connection else { return }
                self.phase = .failed("This presenter uses an incompatible remote version.")
            }
            return
        }

        switch message.kind {
        case .accepted:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === connection else { return }
                self.apply(
                    self.flow.accepted(
                        deviceCode: message.deviceCode,
                        presenterSecret: message.presenterSecret,
                        presenterName: self.selectedPresenterName
                    ),
                    on: connection
                )
            }
        case .rejected:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === connection else { return }
                self.apply(self.flow.rejected(message.errorMessage), on: connection)
            }
        case .state:
            guard let state = message.state else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === connection else { return }
                self.presentationState = state
            }
        case .ping:
            sendSecure(.init(kind: .pong), over: connection)
        case .hello, .pair, .command, .pong:
            break
        }
    }

    private func sendSecure(_ message: LampPresentationRemoteMessage, over connection: NWConnection) {
        guard let activePairingCode,
              let frame = try? LampPresentationRemoteSecureFrameCodec.encode(
                message,
                pairingCode: activePairingCode
              ) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}
