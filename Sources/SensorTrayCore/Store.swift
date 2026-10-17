import Foundation
import SQLite3

/// SQLite-backed persistence for configured sensors and their minute readings.
///
/// Readings are keyed by (sensor, minute) so live samples and history
/// backfills of the same minute never duplicate; a live sample always wins.
/// Not thread-safe: use from one actor (the app uses the main actor).
public final class Store {
    public enum StoreError: Error { case open(String), sql(String) }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private enum Source: Int { case live = 0, backfill = 1 }

    public init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        // The CLI tools may write while the app is running.
        sqlite3_busy_timeout(db, 3000)
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS sensors(
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                model TEXT NOT NULL,
                is_main INTEGER NOT NULL DEFAULT 0,
                sort INTEGER NOT NULL DEFAULT 0,
                synced_through INTEGER,
                added_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS readings(
                sensor_id TEXT NOT NULL,
                minute INTEGER NOT NULL,
                temp_c REAL NOT NULL,
                humidity REAL NOT NULL,
                source INTEGER NOT NULL,
                PRIMARY KEY(sensor_id, minute)
            ) WITHOUT ROWID;
            """)
    }

    /// `~/Library/Application Support/SensorTray/sensortray.sqlite`
    public static func defaultPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SensorTray/sensortray.sqlite").path
    }

    deinit { sqlite3_close(db) }

    // MARK: Sensors

    public func sensors() -> [SensorConfig] {
        query("SELECT id, name, model, is_main, sort FROM sensors ORDER BY sort, added_at") { s in
            guard let id = UUID(uuidString: text(s, 0)),
                  let model = SensorModel(rawValue: text(s, 2)) else { return nil }
            return SensorConfig(id: id, name: text(s, 1), model: model,
                                isMain: sqlite3_column_int(s, 3) != 0, sort: Int(sqlite3_column_int(s, 4)))
        }
    }

    /// Inserts or updates name/model/main/sort, keeping sync state.
    public func save(_ sensor: SensorConfig) {
        run("""
            INSERT INTO sensors(id, name, model, is_main, sort, added_at) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, model=excluded.model,
                is_main=excluded.is_main, sort=excluded.sort
            """, [sensor.id.uuidString, sensor.name, sensor.model.rawValue, sensor.isMain ? 1 : 0, sensor.sort, Int(Date().timeIntervalSince1970)])
    }

    public func setMain(id: UUID) {
        run("UPDATE sensors SET is_main = (id = ?)", [id.uuidString])
    }

    public func delete(id: UUID) {
        run("DELETE FROM readings WHERE sensor_id = ?", [id.uuidString])
        run("DELETE FROM sensors WHERE id = ?", [id.uuidString])
    }

    /// Marks history up to `minute` as already fetched from the device, so
    /// holes the device itself can't fill (e.g. after a battery swap) aren't
    /// re-requested on every sync.
    public func setSyncedThrough(_ id: UUID, minute: Int) {
        run("UPDATE sensors SET synced_through = ? WHERE id = ?", [minute, id.uuidString])
    }

    func syncedThrough(_ id: UUID) -> Int? {
        query("SELECT synced_through FROM sensors WHERE id = ?", [id.uuidString]) { s in
            sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, 0))
        }.first
    }

    // MARK: Readings

    public func insertLive(_ id: UUID, minute: Int, reading: Reading) {
        run("INSERT OR REPLACE INTO readings VALUES(?, ?, ?, ?, ?)",
            [id.uuidString, minute, reading.tempC, reading.humidity, Source.live.rawValue])
    }

    public func insertBackfill(_ id: UUID, points: [HistoryPoint]) {
        guard !points.isEmpty else { return }
        run("BEGIN")
        for p in points {
            run("INSERT OR IGNORE INTO readings VALUES(?, ?, ?, ?, ?)",
                [id.uuidString, p.minute, p.tempC, p.humidity, Source.backfill.rawValue])
        }
        run("COMMIT")
    }

    /// Averages per `bucketMinutes` bucket in [from, to]; each point is
    /// stamped with its bucket's first minute.
    public func series(_ id: UUID, from: Int, to: Int, bucketMinutes: Int) -> [HistoryPoint] {
        let bucket = max(1, bucketMinutes)
        return query("""
            SELECT (minute / ?) * ?, AVG(temp_c), AVG(humidity) FROM readings
            WHERE sensor_id = ? AND minute BETWEEN ? AND ?
            GROUP BY minute / ? ORDER BY 1
            """, [bucket, bucket, id.uuidString, from, to, bucket]) { s in
            HistoryPoint(minute: Int(sqlite3_column_int64(s, 0)),
                         tempC: sqlite3_column_double(s, 1), humidity: sqlite3_column_double(s, 2))
        }
    }

    public func lastMinute(_ id: UUID) -> Int? {
        query("SELECT MAX(minute) FROM readings WHERE sensor_id = ?", [id.uuidString]) { s in
            sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, 0))
        }.first
    }

    /// The first minute of the earliest run of at least `minGap` missing
    /// minutes within the last `windowMinutes` (and after `synced_through`),
    /// or nil when there's nothing worth downloading.
    public func oldestGapStart(_ id: UUID, now: Int, windowMinutes: Int, minGap: Int) -> Int? {
        var cursor = now - windowMinutes
        if let synced = syncedThrough(id) { cursor = max(cursor, synced) }
        let minutes: [Int] = query("SELECT minute FROM readings WHERE sensor_id = ? AND minute >= ? ORDER BY minute",
                                   [id.uuidString, cursor]) { s in Int(sqlite3_column_int64(s, 0)) }
        // `cursor` is the first minute not yet known to be covered.
        for m in minutes {
            if m - cursor >= minGap { return cursor }
            cursor = max(cursor, m + 1)
        }
        return now - cursor + 1 >= minGap ? cursor : nil
    }

    // MARK: SQLite plumbing

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(message)
        }
    }

    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("SensorTray SQL prepare failed: %@ — %@", sql, String(cString: sqlite3_errmsg(db)))
            return nil
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Store.transient)
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: [Any] = []) {
        guard let stmt = prepare(sql, args) else { return }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("SensorTray SQL failed: %@ — %@", sql, String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, _ args: [Any] = [], row: (OpaquePointer) -> T?) -> [T] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = row(stmt) { out.append(value) }
        }
        return out
    }
}

private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
}
