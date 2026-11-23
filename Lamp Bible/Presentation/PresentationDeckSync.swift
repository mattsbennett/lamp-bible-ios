import Foundation
import LampCore
import LampModuleKit

/// Brings Mac-authored presentation decks to this device, on either backend.
///
/// A deck sits at the same relative path — `Workspaces/Presentations` — whether
/// the Mac published a compressed sync archive or an expanded sync folder. That
/// is what makes parity cheap here: WebDAV reads decks out of the archive it
/// has already downloaded, and iCloud reads the same paths as loose files, and
/// both hand the result to the one merge decision in `LampCore`.
///
/// This pull never publishes. Decks are a read-only mirror on iOS.
enum PresentationDeckSync {
    /// Decks are the Mac's to publish, as files in the library's deck folder
    /// on either provider; this device mirrors them.
    @discardableResult
    static func pull(
        from storage: ModuleStorage,
        deletions bundleDeletions: Data? = nil,
        into decks: PresentationDeckStorage = .shared
    ) async throws -> Bool {
        let directory = LampPresentationDeckPortableLayout.directoryPath
        let listings = try await storage.listFiles(path: directory)

        var incoming: [LampPresentationDeckRevision] = []
        for listing in listings {
            let path = "\(directory)/\(listing.name)"
            guard LampPresentationDeckPortableLayout.isDeckPath(path) else { continue }
            // One unreadable deck must not stop the rest from arriving.
            guard let data = try? await storage.readFile(path: path),
                  let deck = try? LampPresentationDeckStore.decode(data)
            else { continue }
            incoming.append(
                LampPresentationDeckRevision(
                    deck: deck,
                    data: data,
                    modifiedAt: listing.modificationDate ?? .distantPast
                )
            )
        }

        // With the settings bundle in use, deck deletions travel in it.
        var deletions = LampPresentationDeckDeletionLedger()
        if let bundleDeletions {
            deletions = LampPresentationDeckDeletionLedger.decoded(from: bundleDeletions)
        } else if listings.contains(where: {
            $0.name == LampPresentationDeckPortableLayout.deletionsFilename
        }), let data = try? await storage.readFile(
            path: LampPresentationDeckPortableLayout.deletionsPath
        ) {
            deletions = LampPresentationDeckDeletionLedger.decoded(from: data)
        }

        var changed = false
        // A picture that can't be written here, a video too big for the disk
        // say, is reported once the decks it has nothing to do with are in.
        var assetFailure: Error?
        let assetsDirectory = LampPresentationDeckPortableLayout.assetsDirectoryPath
        for listing in (try? await storage.listFiles(path: assetsDirectory)) ?? [] {
            let path = "\(assetsDirectory)/\(listing.name)"
            guard LampPresentationDeckPortableLayout.isAssetPath(path) else { continue }
            // Images are merged newest-wins, so one held here newer than the
            // listed copy, or as new and the same size, would be kept anyway:
            // don't fetch it again. One only as new but of another size is
            // fetched, for the merge's tie rule to decide as the Mac's does.
            let local = decks.syncedStore.assetsDirectoryURL.appendingPathComponent(listing.name)
            if let listed = listing.modificationDate,
               let values = try? local.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let held = values.contentModificationDate,
               held > listed || (held == listed && listing.size != nil && values.fileSize.map(Int64.init) == listing.size) {
                continue
            }
            guard let data = try? await storage.readFile(path: path) else { continue }
            // Written as each arrives: a video can be 100 MB, and holding
            // every changed one until the last is read could cost the app
            // its memory.
            do {
                try decks.mergeSyncedAsset(
                    LampPresentationAssetRevision(
                        name: listing.name,
                        data: data,
                        modifiedAt: listing.modificationDate ?? .distantPast
                    )
                )
                changed = true
            } catch {
                assetFailure = assetFailure ?? error
            }
        }

        // Decks after their images, so a deck isn't shown before what it
        // draws has arrived.
        let plan = LampPresentationDeckPortablePull.plan(
            incoming: incoming,
            deletions: deletions,
            local: decks.revisions(in: decks.syncedStore)
        )
        if !plan.isEmpty {
            try decks.applySyncPlan(plan)
            changed = true
        }
        // Images are kept only for as long as a stored deck references them.
        // Pruned on every pull, so one left behind by a pull cut short goes on
        // the next; a deck that can't be read keeps them all. Only a pull that
        // changed something reports a failed prune, as it always has.
        if changed {
            try decks.pruneSyncedAssets()
        } else {
            try? decks.pruneSyncedAssets()
        }

        if changed {
            NotificationCenter.default.post(name: .presentationDecksDidChange, object: nil)
        }
        if let assetFailure { throw assetFailure }
        return changed
    }
}
