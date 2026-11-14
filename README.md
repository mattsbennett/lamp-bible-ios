# Lamp Bible (iOS)

A Bible reading and study app for iPhone and iPad.

This repository holds the iOS and iPadOS app: its SwiftUI screens, lifecycle, and the platform code around them. Module formats, databases, search, sync, and the other shared domain logic live in the sibling [`lamp-bible-core`](https://github.com/mattsbennett/lamp-bible-core) Swift package, which the Mac app ([`lamp-bible-macos`](https://github.com/mattsbennett/lamp-bible-macos)) also uses.

## Features

- **Reading plans.** A daily plan screen with date navigation, plan selection, reading-time estimates from actual word counts, daily reminders, and a Today widget. Readings can open in the in-app reader or be handed to another Bible app.
- **Reader.** Book and chapter navigation, a split reader for two translations side by side, red-letter text, supplied-word italics, divine names, poetry layout, footnotes, and Read Aloud with verse follow-along.
- **Original languages.** Strong's-tagged Greek and Hebrew texts, the Septuagint shown under the verses, lexicon lookups, and a Strong's analysis of how a word is rendered across a translation.
- **Study tools.** A tool panel with commentaries, dictionaries, translation notes, and personal notes for the verse in view.
- **Search.** One search across translations, lexicons, commentaries, and your own notes and writings, with word-start matching by default, `"quoted"` exact phrases, and a leading `*` for matches inside words.
- **Notes and highlights.** Verse-range notes written in a TipTap editor, exact text-range highlights in named sets, and reusable highlight themes.
- **Devotionals.** Personal devotional writing with images, audio recording and playback, import, export, and sharing.
- **Library.** Bundled translations, lexicons, commentaries, and long-form books, plus `.lamp` modules the user installs. Bibles the user already owns (USFM, OSIS, Zefania, XML, or CrossWire SWORD modules, including locked ones opened with a purchased key) can be imported as translations.
- **Sync.** Modules, settings, notes, highlights, devotionals, media, and slide decks sync through iCloud Drive or a WebDAV server, in the same portable layout the Mac app reads and writes.
- **Slide decks and presentation remote.** Decks built in the Mac's Slide Studio can be viewed on the phone, and the phone can drive a presentation running on a Mac (see below).
- **Optional AI features.** Reading plans made from a description and Apple's Writing Tools in Lamp's text. They are off until the user turns them on in Settings.

## Repository layout

The app expects its sibling repositories to be cloned into the same parent folder:

```text
<parent folder>/
├── lamp-bible-core/      shared Swift package (local path dependency)
├── lamp-bible-ios/       this repository
├── lamp-bible-macos/     the Mac app
└── lamp-bible-modules/   module sources and the bundled database (private)
```

Inside this repository:

- `Lamp Bible/` — the app: `View/` (SwiftUI screens), `Data/` (storage, modules, sync), `Presentation/` (decks and the remote), `Utility/`, and `Resources/`.
- `LampBibleWidget/` — the Today readings widget. `Shared/` holds the models the app and widget share through the `group.com.neus.lampbible` app group.
- `tiptap-editor/` — source for the web-based notes editor, built into `Lamp Bible/Resources/TipTapEditor/index.html`.
- `Lamp BibleTests/`, `Lamp BibleUITests/` — unit and UI tests.
- `Documentation/` — file formats, such as the [notes and devotionals import/export format](Documentation/ImportExportFormats.md).
- `Resource Files/Third Party Licenses/` — notices for bundled code and content.

## Building

Requirements: a current Xcode, and iOS 18 or later on the device or simulator (the widget extension targets iOS 26.2).

1. Clone [`lamp-bible-core`](https://github.com/mattsbennett/lamp-bible-core) next to this repository. The project references it by the relative path `../lamp-bible-core`.
2. Open `Lamp Bible.xcworkspace` and build the `Lamp Bible` scheme. Xcode fetches the remote packages (GRDB and Realm) on first open.

### The bundled module database

The app bundles its translations, lexicons, commentaries, and books as one compressed SQLite file, `bundled_modules.db.zlib`, which the project reads from the working copy of [`lamp-bible-modules`](https://github.com/mattsbennett/lamp-bible-modules) at `../lamp-bible-modules/modules_db/bundled_modules.db.zlib`. A build bundles whatever file is there, so check it is the bundle you mean to ship before building for a device.

**`lamp-bible-modules` is a private repository.** Without access to it, the file is missing and Xcode cannot copy it. Remove `bundled_modules.db.zlib` from the app target's Copy Bundle Resources phase to build anyway; the app then starts with no bundled content, and modules can be added by installing `.lamp` files or importing a Bible you own.

### The notes editor

The notes editor is a single HTML page built with Vite. After changing anything in `tiptap-editor/src`, rebuild it:

```sh
cd tiptap-editor
npm install
npm run build        # writes ../Lamp Bible/Resources/TipTapEditor/index.html
npm test             # editor logic tests in Node
npm run test:webkit  # runs the built page in WebKit (macOS only)
```

The built `index.html` is committed, so building the app does not need Node.

## Testing

Run the unit and UI tests from the `Lamp Bible` scheme in Xcode, or with `xcodebuild test`. To run one test class, name the `XCTestCase` class itself, for example:

```sh
xcodebuild test -workspace "Lamp Bible.xcworkspace" -scheme "Lamp Bible" \
  -destination "platform=iOS Simulator,name=iPhone 15 Pro" \
  -only-testing:"Lamp BibleTests/SearchQueryGrammarTests"
```

Tests that read bundled translations need the bundled module database described above.

## Data storage

User data is stored with GRDB (SQLite). Earlier versions of the app used Realm; `Lamp Bible/Data/RealmMigrator.swift` copies an existing Realm store's plan and reader settings into GRDB once, on the first launch after upgrading, then deletes the Realm files. Realm remains a dependency only for that migration, and both can be removed once no user still has a Realm store.

## Slide decks

Decks are authored in Slide Studio on a Mac; iPhone and iPad read them. The plan screen's presentation menu opens the deck library, which lists every deck on the device and shows it full screen with swipe navigation, a slide grid, and presenter notes. Hidden slides are skipped, and slides render through the same `LampPresentationUI` canvas the Mac presents with, so a deck looks the same in the room and in your hand.

A widescreen slide wastes over half an upright phone screen, so the viewer takes landscape while it is open and gives the orientation back when it closes. The slide controls inset the slide rather than floating over it: in landscape a widescreen slide fills the height, so a floating bar would hide the slide's own title. iPad keeps whichever orientation it is in, since it has the room and may be sharing the screen with another app.

Decks arrive two ways:

- **Sync.** A Mac publishes decks to `Workspaces/Presentations` in its portable backup. That path is identical in a compressed `.lampsync` archive and in an expanded sync folder, so the WebDAV backend takes decks from the archive it already downloads, and the iCloud backend reads the same relative paths as loose files. For iCloud, point the Mac's folder sync at the app's container — `~/Library/Mobile Documents/iCloud~com~neus~lamp-bible/Documents`, which Files shows as "Lamp Bible" in iCloud Drive.
- **Import.** Opening a `.lampdeck` from Files, Mail, or AirDrop keeps it on the device, listed as "On this device".

Synced decks are a read-only mirror: the Mac owns them, including deletions, which travel in `deleted-decks.json`. Only imported decks can be removed here. iOS never publishes a deck, so it carries no deck merge or deletion bookkeeping of its own.

Image slides show their picture. Images live beside the decks in `Presentations/Assets` under generated filenames, travel with them over sync, and are kept for as long as some deck references one; an image a deck names but that has not arrived yet draws a labelled placeholder rather than an empty frame. A deck may only name files inside its own folder, so an `assetPath` that is absolute or climbs out with `..` fails validation and the deck is refused. The presentation remote still shows placeholders for image slides, since it receives slides over the wire without their files.

## Presentation remote

The plan screen's presentation button discovers a running Lamp Bible Mac presenter over Bonjour. Select the nearby Mac, then scan its pairing QR code or enter the 16-character fallback code. Pairing is bound to a fresh connection challenge, and all pairing proofs, slide content, notes, and controls travel in authenticated encrypted frames. After pairing, iPhone and iPad display the current and next semantic slides, presenter notes, elapsed time, a slide chooser, previous/next controls, and audience blackout state. The remote requires Local Network permission and does not receive deck content until pairing succeeds; QR scanning also requires Camera permission.

## License

[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/). Third-party code and content keep their own licenses, listed in `Resource Files/Third Party Licenses/`.
