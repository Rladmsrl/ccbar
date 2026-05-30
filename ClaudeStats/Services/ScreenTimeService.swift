import Foundation
import SQLite3
import os

/// Reads macOS Screen Time's `knowledgeC.db` to recover app-focus intervals.
///
/// The database lives under `~/Library/Application Support/Knowledge/` — a
/// TCC-protected path, so the app needs **Full Disk Access** to open it. The
/// store is in WAL mode and the system writes to it constantly, so we work on
/// a private copy (db + `-wal` + `-shm`) rather than risk a stale read.
///
/// The service is non-isolated; its work runs off the main actor.
struct ScreenTimeService: Sendable {
    enum Failure: Error, Sendable {
        /// Couldn't read the DB — almost always means Full Disk Access is off.
        case noFullDiskAccess
        /// Read the DB, but a query failed.
        case queryFailed(String)
    }

    /// `~/Library/Application Support/Knowledge/knowledgeC.db`
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Knowledge/knowledgeC.db")
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.rladmsrl.ClaudeStats",
        category: "screentime")

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Screen Time streams that record per-app usage with start/end dates and a
    /// bundle id in `ZVALUESTRING`. `/app/usage` is the one present on current
    /// macOS; `/app/inFocus` shows up on some versions — query both and union.
    private static let usageStreams = ["/app/usage", "/app/inFocus"]
    /// Coalesce same-app usage runs separated by less than this.
    private static let mergeGap: TimeInterval = 60

    // MARK: Permission probe

    /// Whether the Knowledge DB can actually be read right now. (`sqlite3_open`
    /// alone lies — it opens lazily — so this runs a trivial query.)
    static func canRead() -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return false
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM ZOBJECT LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_ROW || rc == SQLITE_DONE
    }

    // MARK: Query

    /// App-focus intervals for `range`, restricted to `bundleIDs`, with
    /// adjacent same-app runs coalesced. Sorted by start.
    func focusIntervals(in range: DateInterval,
                        bundleIDs: Set<String>) -> Result<[AppFocusInterval], Failure> {
        guard !bundleIDs.isEmpty else { return .success([]) }

        guard let copy = Self.makeReadableCopy() else { return .failure(.noFullDiskAccess) }
        defer { try? FileManager.default.removeItem(at: copy.directory) }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        // Open the *copy* read-write so SQLite can replay the WAL into it.
        guard sqlite3_open_v2(copy.database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            return .failure(.queryFailed("could not open knowledgeC.db copy"))
        }

        let lower = range.start.timeIntervalSinceReferenceDate
        let upper = range.end.timeIntervalSinceReferenceDate
        let ids = bundleIDs.sorted()
        let idPlaceholders = ids.map { _ in "?" }.joined(separator: ",")
        let streamPlaceholders = Self.usageStreams.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT ZVALUESTRING, ZSTARTDATE, ZENDDATE
        FROM ZOBJECT
        WHERE ZSTREAMNAME IN (\(streamPlaceholders))
          AND ZVALUESTRING IN (\(idPlaceholders))
          AND ZENDDATE >= ? AND ZSTARTDATE <= ?
        ORDER BY ZVALUESTRING, ZSTARTDATE
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failure(.queryFailed(String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(stmt) }

        var i: Int32 = 1
        for stream in Self.usageStreams { sqlite3_bind_text(stmt, i, stream, -1, Self.SQLITE_TRANSIENT); i += 1 }
        for id in ids { sqlite3_bind_text(stmt, i, id, -1, Self.SQLITE_TRANSIENT); i += 1 }
        sqlite3_bind_double(stmt, i, lower); i += 1
        sqlite3_bind_double(stmt, i, upper)

        var raw: [AppFocusInterval] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                return .failure(.queryFailed(String(cString: sqlite3_errmsg(db))))
            }
            guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
            let bundleID = String(cString: cstr)
            let start = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            let end = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            guard end > start,
                  let clipped = clip(DateInterval(start: start, end: end), to: range) else { continue }
            raw.append(AppFocusInterval(bundleID: bundleID, interval: clipped))
        }

        if raw.isEmpty {
            // Nothing matched — log which bundle ids *do* appear in the window so
            // a mis-guessed app bundle id is easy to spot.
            let seen = Self.distinctUsageBundleIDs(db: db, range: range)
            Self.log.notice("No app-usage rows for \(ids, privacy: .public) in \(range.start, privacy: .public)…\(range.end, privacy: .public). Bundle ids present in that window: \(seen, privacy: .public)")
        }

        return .success(Self.coalesce(raw))
    }

    // MARK: Helpers

    private func clip(_ interval: DateInterval, to bounds: DateInterval) -> DateInterval? {
        let lo = max(interval.start, bounds.start)
        let hi = min(interval.end, bounds.end)
        return hi > lo ? DateInterval(start: lo, end: hi) : nil
    }

    /// Copy `knowledgeC.db` (and its `-wal`/`-shm` siblings) to a throwaway temp
    /// directory. Returns `nil` if the source can't be read (no Full Disk Access).
    private static func makeReadableCopy() -> (directory: URL, database: URL)? {
        let fm = FileManager.default
        let src = databaseURL
        let dir = fm.temporaryDirectory.appending(path: "claude-stats-knowledge-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appending(path: "knowledgeC.db")
            try fm.copyItem(at: src, to: dst)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: src.path + suffix)
                if fm.fileExists(atPath: sidecar.path) {
                    try? fm.copyItem(at: sidecar, to: URL(fileURLWithPath: dst.path + suffix))
                }
            }
            return (dir, dst)
        } catch {
            try? fm.removeItem(at: dir)
            log.notice("knowledgeC.db copy failed (assuming no Full Disk Access): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Distinct app bundle ids recorded in `range` — for diagnostics.
    private static func distinctUsageBundleIDs(db: OpaquePointer, range: DateInterval) -> [String] {
        let streamPlaceholders = usageStreams.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT DISTINCT ZVALUESTRING FROM ZOBJECT
        WHERE ZSTREAMNAME IN (\(streamPlaceholders)) AND ZVALUESTRING IS NOT NULL
          AND ZENDDATE >= ? AND ZSTARTDATE <= ?
        ORDER BY ZVALUESTRING
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var i: Int32 = 1
        for stream in usageStreams { sqlite3_bind_text(stmt, i, stream, -1, SQLITE_TRANSIENT); i += 1 }
        sqlite3_bind_double(stmt, i, range.start.timeIntervalSinceReferenceDate); i += 1
        sqlite3_bind_double(stmt, i, range.end.timeIntervalSinceReferenceDate)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// Merge adjacent (and overlapping) runs of the *same* bundle id.
    private static func coalesce(_ intervals: [AppFocusInterval]) -> [AppFocusInterval] {
        let sorted = intervals.sorted {
            $0.bundleID == $1.bundleID ? $0.interval.start < $1.interval.start : $0.bundleID < $1.bundleID
        }
        var out: [AppFocusInterval] = []
        for item in sorted {
            if let last = out.last, last.bundleID == item.bundleID,
               item.interval.start <= last.interval.end.addingTimeInterval(mergeGap) {
                let end = max(last.interval.end, item.interval.end)
                out[out.count - 1] = AppFocusInterval(
                    bundleID: last.bundleID,
                    interval: DateInterval(start: last.interval.start, end: end))
            } else {
                out.append(item)
            }
        }
        return out.sorted { $0.interval.start < $1.interval.start }
    }
}
