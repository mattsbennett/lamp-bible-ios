//
//  MissingModuleMark.swift
//  Lamp Bible
//

import LampModuleKit
import SwiftUI

/// A module this device holds that the last sync did not find in the
/// library: its path there, and why (core's `LampSyncFilePlan.Missing`).
struct MissingModule: Equatable {
    /// The library, as the sync names it.
    var source = ""
    let path: String
    let cause: LampSyncFilePlan.Missing
    /// On iCloud a file can be missing here only because it hasn't arrived.
    let onICloud: Bool

    var fileName: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }

    /// The missing modules of the library at `source`, by
    /// `key(folder:moduleID:)`, as the Module Manager looks its rows up.
    nonisolated static func index(
        _ missing: [String: [String: LampSyncFilePlan.Missing]],
        moduleIDs: [String: [String: String]] = [:],
        storage: ModuleStorage?
    ) -> [String: MissingModule] {
        // iCloud's source is known without its container, which can't be
        // reached while signed out: the time its marks matter most.
        let source = storage is ICloudModuleStorage
            ? ICloudLibraryStorage.librarySource
            : storage.flatMap { libraryEndpoint(for: $0)?.librarySource }
        guard let storage, let source, let paths = missing[source] else { return [:] }
        let onICloud = !(storage is WebDAVModuleStorage)
        var index: [String: MissingModule] = [:]
        for (path, cause) in paths {
            let folder = (path as NSString).deletingLastPathComponent
            guard let id = moduleIDs[source]?[path] ?? LampSyncFolderLayout.remoteModuleID(of: path) else { continue }
            index[key(folder: folder, moduleID: id)] = MissingModule(source: source, path: path, cause: cause, onICloud: onICloud)
        }
        return index
    }

    nonisolated static func key(folder: String, moduleID: String) -> String {
        "\(folder)/\(moduleID)"
    }
}

/// The mark on a module the last sync did not find, and what it means.
/// Nothing deletes such a module for the person: the popover says whether
/// the library couldn't be checked or the file has gone from it, and offers
/// Delete only for the second, which then goes to every device as any
/// deletion does.
struct MissingModuleMark: View {
    let missing: MissingModule
    let name: String
    var onDelete: (() -> Void)? = nil

    @ObservedObject private var sync = SyncCoordinator.shared
    @State private var showing = false
    @State private var confirmingDelete = false

    /// The last sync didn't get as far as the library's files: not
    /// connected, signed out, the server down. What the mark says about the
    /// file is from the check before.
    private var isUnchecked: Bool { sync.uncheckedLibraries[missing.source] != nil }

    /// Known to be gone, the one state Delete is offered in: "couldn't look"
    /// is no reason to delete what may be the only copy.
    private var isGone: Bool { !isUnchecked && missing.cause == .notOnServer }

    // The Mac's wording, so the two apps say the same.
    private var title: String {
        if isUnchecked { return "Not Checked Just Now" }
        return missing.cause == .notOnServer ? "Not in Your Library" : "Could Not Be Checked"
    }

    private var message: String {
        if isUnchecked {
            let before = missing.cause == .notOnServer ? " It was not found when Lamp last managed to look." : ""
            return "Lamp could not reach your library the last time it tried, so it cannot say whether \(name) is still there." + before
        }
        switch missing.cause {
        case .folderNotListed:
            return "Lamp reached your library but could not list the folder \(name) is kept in, so whether it is still there is unknown. This usually clears itself on the next sync."
        case .notOnServer:
            return "Lamp looked in your library and \(name) was not there. Either it was removed, from another device or from the server itself, or, if your library is on iCloud, it may not have arrived yet. Your copy on this \(UIDevice.current.kindName) is untouched."
        }
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            // Weighted by what is known: filled red only for a file known to
            // be gone, so a flaky server doesn't paint the shelf red.
            Image(systemName: isGone ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                .font(.body)
                .foregroundStyle(isGone ? Color.red : Color.secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isGone, onDelete != nil {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete \(name)", systemImage: "trash")
                    }
                    .padding(.top, 2)
                    .confirmationDialog("Delete Module", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            showing = false
                            onDelete?()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Delete \"\(name)\" from this \(UIDevice.current.kindName) and your other devices? This cannot be undone.")
                    }
                }
            }
            .padding()
            // A phone's popover is narrower than the screen: sized to fit,
            // not clipped at its sides.
            .frame(width: 280, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}
