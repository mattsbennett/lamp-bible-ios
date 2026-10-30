//
//  StrongsIndex.swift
//  Lamp Bible
//

import Foundation
import GRDB
import LampCore

/// A database a translation's verses are read from.
protocol TranslationVerseSource {
    func read<T>(_ block: (Database) throws -> T) throws -> T
    /// What changes whenever this database's verses may have, beyond what
    /// their count and row IDs show: part of each translation's fingerprint.
    var verseStamp: String { get }
}

extension BundledModuleDatabase: TranslationVerseSource {
    var verseStamp: String { "bundled:\(contentStamp)" }
}

extension ModuleDatabase: TranslationVerseSource {
    // A re-imported translation's verses are new rows, with new IDs.
    var verseStamp: String { "user" }
}

/// Which verses of each translation tag each Strong's key, so finding a
/// key's verses is a lookup rather than a reading of every verse's tags:
/// G25 in the KJV was 5,793 verses read to find 109.
///
/// Kept in a database of its own among the caches, since it can always be
/// built again: neither synced nor backed up. A translation is indexed in the
/// background, a book at a time, and again whenever its fingerprint (its
/// verse count, last row ID and its database's stamp) no longer matches.
/// Until then a lookup returns nil, and the caller reads the verses as before.
final class StrongsIndex: @unchecked Sendable {
    static let shared = StrongsIndex(dbQueue: StrongsIndex.openCache())

    private let dbQueue: DatabaseQueue?
    private let lock = NSLock()
    private var building: Set<String> = []
    private let buildQueue = DispatchQueue(label: "com.lampbible.strongsIndex", qos: .utility)

    init(dbQueue: DatabaseQueue?) {
        self.dbQueue = dbQueue
    }

    private static func openCache() -> DatabaseQueue? {
        guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StrongsIndex.sqlite") else { return nil }
        func open() throws -> DatabaseQueue {
            let queue = try DatabaseQueue(path: url.path)
            try migrator.migrate(queue)
            return queue
        }
        if let queue = try? open() { return queue }
        // A cache that can't be opened is started again.
        try? FileManager.default.removeItem(at: url)
        return try? open()
    }

    static func inMemory() throws -> StrongsIndex {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return StrongsIndex(dbQueue: queue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE indexed_translations (
                    translation_id TEXT PRIMARY KEY,
                    fingerprint TEXT NOT NULL
                );
                CREATE TABLE strongs_verses (
                    translation_id TEXT NOT NULL,
                    key TEXT NOT NULL,
                    ref INTEGER NOT NULL,
                    PRIMARY KEY (translation_id, key, ref)
                ) WITHOUT ROWID;
                """)
        }
        return migrator
    }

    // MARK: - Lookup

    /// The verses of `translationId` tagging `key`, in order, or nil while
    /// the translation has no index as it now stands, which is then started.
    func refs(
        translationId: String,
        key: String,
        bookRange: ClosedRange<Int>? = nil,
        source: TranslationVerseSource
    ) -> [Int]? {
        guard let dbQueue else { return nil }
        guard (try? isCurrent(translationId, source: source, in: dbQueue)) == true else {
            build(translationId, from: source)
            return nil
        }
        let keys = Self.lookupKeys(for: key)
        var sql = """
            SELECT DISTINCT ref FROM strongs_verses
            WHERE translation_id = ? AND key IN (\(keys.map { _ in "?" }.joined(separator: ", ")))
            """
        var arguments = StatementArguments([translationId] + keys)
        if let bookRange {
            sql += " AND ref BETWEEN ? AND ?"
            arguments += [bookRange.lowerBound * 1_000_000, bookRange.upperBound * 1_000_000 + 999_999]
        }
        sql += " ORDER BY ref"
        return try? dbQueue.read { try Int.fetchAll($0, sql: sql, arguments: arguments) }
    }

    /// The forms a verse's tag may take and still be `key`, as
    /// `LampStrongsKey.matches` has it: the key, and the bare number that
    /// matches a key of either letter.
    static func lookupKeys(for key: String) -> [String] {
        let normalized = LampStrongsKey.normalized(key)
        guard let first = normalized.first else { return [] }
        if first.isNumber { return [normalized, "G" + normalized, "H" + normalized] }
        let bare = String(normalized.dropFirst())
        guard first == "G" || first == "H", bare.first?.isNumber == true else { return [normalized] }
        return [normalized, bare]
    }

    private func isCurrent(_ translationId: String, source: TranslationVerseSource, in dbQueue: DatabaseQueue) throws -> Bool {
        let stored = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT fingerprint FROM indexed_translations WHERE translation_id = ?",
                arguments: [translationId]
            )
        }
        guard let stored else { return false }
        return stored == (try Self.fingerprint(of: translationId, in: source))
    }

    /// The translation's verse count and last row ID, read from an index in
    /// a millisecond or two, and its database's stamp.
    static func fingerprint(of translationId: String, in source: TranslationVerseSource) throws -> String {
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
    /// it ready.
    func prepare(readerTranslationId: String?) {
        buildQueue.async { [self] in
            let tagged = ((try? TranslationDatabase.shared.getAllTranslations()) ?? [])
                .filter { $0.features?.strongs == true }
                .sorted { ($0.id == readerTranslationId ? 0 : 1) < ($1.id == readerTranslationId ? 0 : 1) }
            for translation in tagged {
                guard let dbQueue,
                      let source = try? TranslationDatabase.shared.verseSource(for: translation.id),
                      (try? isCurrent(translation.id, source: source, in: dbQueue)) != true else { continue }
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
                print("[StrongsIndex] indexed \(translationId): \(count) tags in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } catch {
                print("[StrongsIndex] couldn't index \(translationId): \(error)")
            }
        }
    }

    /// Reads the translation a book at a time, so no read holds its
    /// database for long, and writes its index in one transaction. Returns
    /// how many verse–key pairs it holds.
    @discardableResult
    func rebuild(_ translationId: String, from source: TranslationVerseSource) throws -> Int {
        guard let dbQueue else { return 0 }
        let fingerprint = try Self.fingerprint(of: translationId, in: source)
        let books = try source.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT DISTINCT book FROM translation_verses WHERE translation_id = ? ORDER BY book",
                arguments: [translationId]
            )
        }
        var entries: [(key: String, ref: Int)] = []
        for book in books {
            let verses = try source.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT ref, annotations_json FROM translation_verses
                    WHERE translation_id = ? AND book = ? AND annotations_json IS NOT NULL
                    """, arguments: [translationId, book]
                ).map { row -> (ref: Int, json: String) in
                    let json: String? = row["annotations_json"]
                    return (row["ref"], json ?? "")
                }
            }
            for verse in verses {
                for key in Set(Self.keys(in: verse.json)) {
                    entries.append((key, verse.ref))
                }
            }
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM strongs_verses WHERE translation_id = ?", arguments: [translationId])
            let insert = try db.makeStatement(
                sql: "INSERT OR IGNORE INTO strongs_verses (translation_id, key, ref) VALUES (?, ?, ?)"
            )
            for entry in entries {
                try insert.execute(arguments: [translationId, entry.key, entry.ref])
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO indexed_translations (translation_id, fingerprint) VALUES (?, ?)",
                arguments: [translationId, fingerprint]
            )
        }
        return entries.count
    }

    private static let strongsValue = try! NSRegularExpression(pattern: #""strongs"\s*:\s*"((?:[^"\\]|\\.)*)""#)

    /// Each key a verse's annotations tag, normalized, read as core's tag
    /// reader reads them: every "strongs" value, split at commas,
    /// semicolons, bars and spaces.
    static func keys(in annotationsJSON: String) -> [String] {
        let range = NSRange(annotationsJSON.startIndex..., in: annotationsJSON)
        return strongsValue.matches(in: annotationsJSON, range: range).flatMap { match -> [String] in
            guard let value = Range(match.range(at: 1), in: annotationsJSON) else { return [] }
            return annotationsJSON[value]
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" || $0.isWhitespace })
                .map { LampStrongsKey.normalized(String($0)) }
                .filter { !$0.isEmpty }
        }
    }
}
