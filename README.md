# Lamp Bible (iOS)

A Bible reading companion app.

## Build

Keep `lamp-bible-core` beside this repository, add the latest `{version}.realm` to `./Lamp Bible`, and build in Xcode.

## Slide Decks

Decks are authored in Slide Studio on a Mac; iPhone and iPad read them. The plan screen's presentation menu opens the deck library, which lists every deck on the device and shows it full screen with swipe navigation, a slide grid, and presenter notes. Hidden slides are skipped, and slides render through the same `LampPresentationUI` canvas the Mac presents with, so a deck looks the same in the room and in your hand.

A widescreen slide wastes over half an upright phone screen, so the viewer takes landscape while it is open and gives the orientation back when it closes. iPad keeps whichever orientation it is in, since it has the room and may be sharing the screen with another app.

Decks arrive two ways:

- **Sync.** A Mac publishes decks to `Workspaces/Presentations` in its portable backup. That path is identical in a compressed `.lampsync` archive and in an expanded sync folder, so the WebDAV backend takes decks from the archive it already downloads, and the iCloud backend reads the same relative paths as loose files. For iCloud, point the Mac's folder sync at the app's container — `~/Library/Mobile Documents/iCloud~com~neus~lamp-bible/Documents`, which Files shows as "Lamp Bible" in iCloud Drive.
- **Import.** Opening a `.lampdeck` from Files, Mail, or AirDrop keeps it on the device, listed as "On this device".

Synced decks are a read-only mirror: the Mac owns them, including deletions, which travel in `deleted-decks.json`. Only imported decks can be removed here. iOS never publishes a deck, so it carries no deck merge or deletion bookkeeping of its own.

Image blocks render as a placeholder on every platform — deck assets are not yet resolved or synced anywhere, including in Slide Studio.

## Presentation Remote

The plan screen's presentation button discovers a running Lamp Bible Mac presenter over Bonjour. Select the nearby Mac, then scan its pairing QR code or enter the 16-character fallback code. Pairing is bound to a fresh connection challenge, and all pairing proofs, slide content, notes, and controls travel in authenticated encrypted frames. After pairing, iPhone and iPad display the current and next semantic slides, presenter notes, elapsed time, a slide chooser, previous/next controls, and audience blackout state. The remote requires Local Network permission and does not receive deck content until pairing succeeds; QR scanning also requires Camera permission.

### Updating Bundled Realm Database

1. Update realm database by copying DataModel changes to Lamp_Realm_Create project, making any updates to seed data JSON files, and running the project to create the `{version}.realm` file (see [`Lamp_Realm_Create/README.md`](https://github.com/mattsbennett/lamp-realm-create) for more details on this process).
2. Copy the updated `{version}.realm` file `./Lamp Bible`.
3. Add migration code to `./Lamp Bible/RealmManager.swift`.
    - When adding new properties to existing models, or adding new objects, simply increment the schema version - Realm will handle the rest.
    - Other changes will require also migration block to be added to `./Lamp Bible/RealmManager.swift`.
    - For changes to the bundled realm (via changes to the seed data), migration code (not via schema migration block) is also required to copy the user object data to the new realm, and to delete the old realm.
        - This is slightly onerous as there is no deep copy method for realm objects, so nested objects must be copied manually via iteration.
4. Once the migration code is added and the migration fully tested, the previous realm file can be deleted from the project, and only the new realm file shipped (the previous version was copied to existing user's devices already, so we don't need to ship it anymore).

## License

[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)
