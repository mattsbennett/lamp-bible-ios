import Combine
import Foundation
import LampCore
import Network
import UIKit

final class PresentationRemoteClient: ObservableObject {
    enum Phase: Equatable {
        case stopped
        case browsing
        case connecting
        case awaitingPairing
        case pairing
        case presenting
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

    private let queue = DispatchQueue(label: "com.neus.lamp-bible.presentation-remote-client")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pairingChallenge: String?
    private var activePairingCode: String?

    func startBrowsing() {
        browser?.cancel()
        connection?.cancel()
        connection = nil
        pairingChallenge = nil
        activePairingCode = nil
        presentationState = nil
        pairingError = nil
        presenters = []
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
        pairingError = nil
        presentationState = nil
        pairingChallenge = nil
        activePairingCode = nil
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
                    self.phase = .failed(error.localizedDescription)
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
        sendSecure(.hello(clientName: UIDevice.current.name), over: connection)
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
                    DispatchQueue.main.async {
                        guard self.connection === connection else { return }
                        self.phase = .failed(
                            self.activePairingCode == nil
                                ? "The presenter sent an invalid response."
                                : "Pairing failed. Check the code and choose the presenter again."
                        )
                    }
                    connection.cancel()
                    return
                }
            }

            if isComplete || error != nil {
                DispatchQueue.main.async {
                    guard self.connection === connection else { return }
                    if case .failed = self.phase { return }
                    self.phase = .failed(
                        self.phase == .pairing
                            ? "Pairing failed. Check the code and choose the presenter again."
                            : "The presentation connection ended."
                    )
                }
            } else {
                self.receive(from: connection)
            }
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
            self.phase = .awaitingPairing
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
                self.pairingError = nil
                self.phase = .presenting
            }
        case .rejected:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === connection else { return }
                self.pairingError = message.errorMessage ?? "Pairing was rejected."
                self.phase = .awaitingPairing
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
