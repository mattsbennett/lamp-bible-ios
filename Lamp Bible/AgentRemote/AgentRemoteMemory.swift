import Foundation
import LampCore

/// The Macs this device remembers for chats, kept as the slide remote keeps
/// its presenters: in the Keychain, on this device only, never synced.
///
/// Core's connection decides what to remember (`.remember`); this keeps it.
/// Nothing is forgotten but by the person's choice: a key a connection turned
/// away is only passed over (`.keyRefused`), since a replayed hello or a slow
/// network can look the same.
final class AgentRemoteMemory {
    static let shared = AgentRemoteMemory(
        storage: KeychainPresenterSecrets(service: "com.neus.Lamp-Bible.agent-remote")
    )

    private let storage: PresenterSecretStorage

    init(storage: PresenterSecretStorage) {
        self.storage = storage
    }

    var hosts: [LampAgentRemoteRememberedHost] {
        storage.load().values
            .compactMap { try? JSONDecoder().decode(LampAgentRemoteRememberedHost.self, from: $0) }
            .sorted { ($0.name, $0.pairedAt) < ($1.name, $1.pairedAt) }
    }

    /// Keeps a host the connection paired with, in place of anything kept
    /// for the same Mac, known by its secret: a key paired again after one was
    /// turned away replaces it rather than sitting beside it, to be offered
    /// again after a restart.
    func remember(_ host: LampAgentRemoteRememberedHost) {
        for earlier in hosts where earlier.hostSecret == host.hostSecret && earlier.id != host.id {
            storage.delete(earlier.id)
        }
        if let data = try? JSONEncoder().encode(host) {
            storage.save(data, for: host.id)
        }
    }

    func forget(_ id: String) {
        storage.delete(id)
    }
}

/// What the connection's problems mean to the person holding the phone.
enum AgentRemoteProblemText {
    static let refused = "This Mac no longer recognises this device. Choose Pair a Device… in Lamp Bible’s settings on the Mac, and scan its code to pair again."

    static func text(_ problem: LampAgentRemoteDeviceConnection.Problem) -> String {
        switch problem {
        case .refused:
            return refused
        case .codeRefused:
            return "The Mac didn’t accept that code. Check it and try again."
        case .otherVersion:
            return "This Mac has a different version of Lamp Bible. Update Lamp Bible on both."
        case .unreadable:
            return "The Mac’s reply couldn’t be read. Try again."
        case let .unreachable(reason):
            return reason ?? "The Mac couldn’t be reached. Try again."
        }
    }
}
