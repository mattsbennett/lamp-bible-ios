//
//  StrongsIndex.swift
//  Lamp Bible
//

import Foundation
import GRDB
import LampCore

/// A database a translation's verses are read from.
protocol TranslationVerseSource {
    /// The app's own connection, for short reads.
    func read<T>(_ block: (Database) throws -> T) throws -> T
    /// A connection of the index's own, for reading a whole translation, so
    /// building and fingerprinting never hold the app's.
    func openIndexReader() throws -> DatabaseQueue
    /// What changes whenever this database's verses may have, beyond what
    /// their count and row IDs show.
    var verseStamp: String { get }
}

extension BundledModuleDatabase: TranslationVerseSource {
    var verseStamp: String { "bundled:\(contentStamp)" }

    func openIndexReader() throws -> DatabaseQueue {
        guard let databasePath else { throw BundledModuleDatabaseError.notAvailable }
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: databasePath, configuration: config)
    }
}

extension ModuleDatabase: TranslationVerseSource {
    // A re-imported translation's verses are new rows, with new IDs.
    var verseStamp: String { "user" }

    func openIndexReader() throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(10)
        return try DatabaseQueue(path: fileURL.path, configuration: config)
    }
}

/// Which verses of each translation tag each Strong's key, and what an
/// analysis measures a key against, in core's `LampStrongsIndex`: a key's
/// verses are a lookup rather than a reading of every verse's tags (G25 in
/// the KJV was 5,793 verses read to find 109), and an analysis reads only the
/// verses holding its key.
///
/// Kept in a database of its own among the caches, since it can always be
/// built again: neither synced nor backed up. A translation is indexed in the
/// background, a book at a time, and again when core's fingerprint of its
/// tags no longer matches. Until then a lookup returns nil, and the caller
/// reads the verses as before.
final class StrongsIndex: @unchecked Sendable {
    static let shared = StrongsIndex(dbQueue: StrongsIndex.openCache())

    private let dbQueue: DatabaseQueue?
    private let lock = NSLock()
    private var building: Set<String> = []
    /// Core's fingerprint reads every verse, so each is kept for the launch,
    /// against a stamp that is quick to read and changes with a reinstall.
    private var fingerprints: [String: (stamp: String, fingerprint: String)] = [:]
    private let buildQueue = DispatchQueue(label: "com.lampbible.strongsIndex", qos: .utility)

    init(dbQueue: DatabaseQueue?) {
        self.dbQueue = dbQueue
    }

    private static func openCache() -> DatabaseQueue? {
        guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StrongsIndex.sqlite") else { return nil }
        func open() throws -> DatabaseQueue {
            let queue = try DatabaseQueue(path: url.path)
            try prepareSchema(queue)
            return queue
        }
        if let queue = try? open() { return queue }
        // A cache that can't be opened is started again.
        try? FileManager.default.removeItem(at: url)
        return try? open()
    }

    static func inMemory() throws -> StrongsIndex {
        let queue = try DatabaseQueue()
        try prepareSchema(queue)
        return StrongsIndex(dbQueue: queue)
    }

    private static func prepareSchema(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { _ in }
        // The phone's own index gives way to core's, which keeps what an
        // analysis needs too; what it held is built again.
        migrator.registerMigration("v2-core") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS indexed_translations")
            try db.execute(sql: "DROP TABLE IF EXISTS strongs_verses")
        }
        try migrator.migrate(queue)
        // Every open, so tables a newer core adds are there.
        try queue.write { try LampStrongsIndex.createTables(in: $0) }
    }

    // MARK: - Lookup

    /// The verses of `translationId` tagging `key`, in order, or nil while
    /// the translation has no index as it now stands, which is then started.
    func refs(
        translationId: String,
        key: String,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int? = nil,
        source: TranslationVerseSource
    ) -> [Int]? {
        current(translationId, source: source) { db in
            try LampStrongsIndex.references(of: key, translationID: translationId, bookRange: bookRange, limit: limit, in: db)
        }
    }

    /// How many verses of `translationId` tag `key`, or nil while it has no
    /// index as it now stands.
    func count(translationId: String, key: String, bookRange: ClosedRange<Int>? = nil, source: TranslationVerseSource) -> Int? {
        current(translationId, source: source) { db in
            try LampStrongsIndex.count(of: key, translationID: translationId, bookRange: bookRange, in: db)
        }
    }

    /// The analysis of `key` from the index, reading only the verses that
    /// hold it, or nil while the translation has no index as it now stands.
    func analysis(
        key: String,
        translation: TranslationModule,
        includingVerseText: Bool,
        source: TranslationVerseSource
    ) throws -> LampStrongsAnalysis? {
        guard let dbQueue,
              let indexed = current(translation.id, source: source, { db in
                  (
                      try LampStrongsIndex.corpus(for: key, translationID: translation.id, in: db),
                      try LampStrongsIndex.references(of: key, translationID: translation.id, in: db)
                  )
              }) else { return nil }
        let (corpus, references) = indexed
        var analyzer = LampStrongsAnalyzer(
            key: key,
            translationID: translation.id,
            translationName: translation.name,
            translationAbbreviation: translation.abbreviation,
            language: translation.language,
            includingVerseText: includingVerseText,
            corpus: corpus
        )
        try source.read { db in
            for start in stride(from: 0, to: references.count, by: 500) {
                let batch = Array(references[start..<min(start + 500, references.count)])
                for row in try Row.fetchAll(db, sql: """
                    SELECT ref, text, annotations_json FROM translation_verses
                    WHERE translation_id = ? AND ref IN (\(batch.map { _ in "?" }.joined(separator: ", ")))
                    """, arguments: StatementArguments([translation.id] + batch)) {
                    let text: String? = row["text"]
                    analyzer.add(reference: row["ref"], text: text ?? "", annotationsJSON: row["annotations_json"])
                }
            }
        }
        return try analyzer.analysis { keys in
            try dbQueue.read { try LampStrongsIndex.verseCounts(of: keys, translationID: translation.id, in: $0) }
        }
    }

    /// `body`'s answer from the index when it holds the translation as it
    /// now stands; otherwise nil, and the index is started.
    private func current<T>(_ translationId: String, source: TranslationVerseSource, _ body: (Database) throws -> T) -> T? {
        guard let dbQueue else { return nil }
        guard let digest = try? fingerprint(of: translationId, source: source),
              let answer = try? dbQueue.read({ db -> T? in
                  guard try LampStrongsIndex.isCurrent(translationID: translationId, fingerprint: digest, in: db) else {
                      return nil
                  }
                  return try body(db)
              }) else {
            build(translationId, from: source)
            return nil
        }
        return answer
    }

    /// Core's fingerprint of the translation's tags, kept while its quick
    /// stamp, its verse count and last row ID, stays the same.
    func fingerprint(of translationId: String, source: TranslationVerseSource) throws -> String {
        let stamp = try Self.stamp(of: translationId, in: source)
        lock.lock()
        let kept = fingerprints[translationId]
        lock.unlock()
        if let kept, kept.stamp == stamp { return kept.fingerprint }
        let digest = try source.openIndexReader().read { db in
            try LampStrongsIndex.fingerprint(table: "translation_verses", translationID: translationId, in: db)
        }
        lock.lock()
        fingerprints[translationId] = (stamp, digest)
        lock.unlock()
        return digest
    }

    /// Read from an index in a millisecond or two.
    static func stamp(of translationId: String, in source: TranslationVerseSource) throws -> String {
        let row = try source.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS verses, MAX(rowid) AS last FROM translation_verses WHERE translation_id = ?",
                arguments: [translationId]
            )
        }
        let verses: Int? = row?["verses"]
        let last: Int64? = row?["last"]
        return "\(source.verseStamp)|\(verses ?? 0)|\(last ?? 0)"
    }

    // MARK: - Building

    /// Indexes, in the background, every translation with Strong's tags that
    /// has no index as it now stands, the reader's first, so a search finds
    /// it ready, and drops any translation no longer installed.
    func prepare(readerTranslationId: String?) {
        buildQueue.async { [self] in
            guard let dbQueue else { return }
            let tagged = ((try? TranslationDatabase.shared.getAllTranslations()) ?? [])
                .filter { $0.features?.strongs == true }
                .sorted { ($0.id == readerTranslationId ? 0 : 1) < ($1.id == readerTranslationId ? 0 : 1) }
            let installed = Set(tagged.map(\.id))
            try? dbQueue.write { db in
                let indexed = try String.fetchAll(db, sql: "SELECT DISTINCT translation_id FROM strongs_index_translations")
                for gone in indexed where !installed.contains(gone) {
                    try LampStrongsIndex.remove(translationID: gone, in: db)
                }
            }
            for translation in tagged {
                guard let source = try? TranslationDatabase.shared.verseSource(for: translation.id),
                      let digest = try? fingerprint(of: translation.id, source: source),
                      (try? dbQueue.read({
                          try LampStrongsIndex.isCurrent(translationID: translation.id, fingerprint: digest, in: $0)
                      })) != true else { continue }
                build(translation.id, from: source)
            }
        }
    }

    /// Queues the translation's index to be built, unless it already is.
    func build(_ translationId: String, from source: TranslationVerseSource) {
        lock.lock()
        let started = building.insert(translationId).inserted
        lock.unlock()
        guard started else { return }
        buildQueue.async { [self] in
            defer {
                lock.lock()
                building.remove(translationId)
                lock.unlock()
            }
            do {
                let started = Date()
                let count = try rebuild(translationId, from: source)
                print("[StrongsIndex] indexed \(translationId): \(count) verses in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } catch {
                print("[StrongsIndex] couldn't index \(translationId): \(error)")
            }
        }
    }

    /// Builds the translation's index now, after any build already queued:
    /// one at a time, or two would add each chapter's tags twice.
    @discardableResult
    func buildAndWait(_ translationId: String, from source: TranslationVerseSource) throws -> Int {
        try buildQueue.sync { try rebuild(translationId, from: source) }
    }

    /// Builds the translation's index through core, a book per transaction,
    /// read on a connection of its own; marked whole only at the end, so an
    /// index half built is never read. Returns how many verses it read. Only
    /// ever on the build queue.
    private func rebuild(_ translationId: String, from source: TranslationVerseSource) throws -> Int {
        guard let dbQueue else { return 0 }
        let digest = try fingerprint(of: translationId, source: source)
        let reader = try source.openIndexReader()
        try dbQueue.write { try LampStrongsIndex.remove(translationID: translationId, in: $0) }
        let books = try reader.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT DISTINCT book FROM translation_verses WHERE translation_id = ? ORDER BY book",
                arguments: [translationId]
            )
        }
        var count = 0
        for book in books {
            let verses = try reader.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT ref, annotations_json FROM translation_verses
                    WHERE translation_id = ? AND book = ? AND annotations_json IS NOT NULL
                    """, arguments: [translationId, book]
                ).map { row -> (ref: Int, json: String?) in (row["ref"], row["annotations_json"]) }
            }
            try dbQueue.write { db in
                for verse in verses {
                    try LampStrongsIndex.add(reference: verse.ref, annotationsJSON: verse.json, translationID: translationId, in: db)
                }
            }
            count += verses.count
        }
        try dbQueue.write { try LampStrongsIndex.finish(translationID: translationId, fingerprint: digest, in: $0) }
        return count
    }
}
