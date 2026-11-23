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

/// The addresses this device reaches Macs at where Bonjour can't find them,
/// as over Tailscale, whose network carries no Bonjour: from a Mac's
/// pairing code, or typed. On this device only. An address isn't a secret,
/// and proves nothing: the handshake over it is what says which Mac
/// answered, and the pairing it answered to, once it has, ties the address
/// to it, by the pairing's id. The Mac's secret stays in the Keychain.
final class AgentRemoteAddressBook {
    static let shared = AgentRemoteAddressBook(defaults: .standard)

    struct Entry: Codable, Equatable, Identifiable {
        /// The address as `LampAgentRemoteAddress.text` writes it.
        var text: String
        /// The Mac's name, once it's answered there.
        var name: String?
        /// The pairing the Mac answered there to (`LampAgentRemoteRememberedHost.id`).
        var pairing: String?
        /// The name Bonjour finds the same Mac by, on its own network.
        var bonjourName: String?
        var id: String { text }

        var address: LampAgentRemoteAddress? { LampAgentRemoteAddress.parse(text) }
    }

    private let defaults: UserDefaults
    private static let key = "agentRemote.addresses"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var entries: [Entry] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.filter { $0.address != nil }
    }

    /// Adds an address, or updates what's known of one already kept.
    func keep(_ address: LampAgentRemoteAddress, name: String? = nil, pairing: String? = nil) {
        var entries = entries
        let text = address.text
        if let index = entries.firstIndex(where: { $0.text == text }) {
            if let name { entries[index].name = name }
            if let pairing, entries[index].pairing != pairing {
                // Another Mac at this address now: the old one's Bonjour name
                // isn't this one's.
                entries[index].pairing = pairing
                entries[index].bonjourName = nil
            }
        } else {
            entries.append(Entry(text: text, name: name, pairing: pairing))
        }
        save(entries)
    }

    /// Notes the name Bonjour found a Mac by, on the addresses it answers at,
    /// to look for it by on its own network.
    func found(pairing: String, bonjourName: String) {
        var entries = entries
        guard entries.contains(where: { $0.pairing == pairing && $0.bonjourName != bonjourName }) else { return }
        for index in entries.indices where entries[index].pairing == pairing { entries[index].bonjourName = bonjourName }
        save(entries)
    }

    func forget(_ text: String) {
        save(entries.filter { $0.text != text })
    }

    /// Moves the addresses kept for a Mac's earlier pairings to its new one,
    /// when it's paired again.
    func repoint(from earlier: [String], to pairing: String) {
        var entries = entries
        guard entries.contains(where: { $0.pairing.map(earlier.contains) == true }) else { return }
        for index in entries.indices where entries[index].pairing.map(earlier.contains) == true { entries[index].pairing = pairing }
        save(entries)
    }

    /// Forgets every address a Mac answered at, when its pairing is forgotten.
    func forget(pairing: String) {
        save(entries.filter { $0.pairing != pairing })
    }

    private func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
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
