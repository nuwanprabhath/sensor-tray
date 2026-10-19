import Foundation
import SQLite3

/// SQLite-backed persistence for configured sensors and their minute readings,
/// kept forever.
///
/// Schema v2 is sized for years of minute data:
/// - `samples(sensor, minute, t, h, src)`: one row per sensor-minute, the
///   sensor as a small integer key and °C / %RH as integer tenths. That's
///   ~15 bytes a row, about 8 MB per sensor-year (v1 used ~95).
/// - `hourly(sensor, hour, n, sums, mins, maxes)`: a rollup kept current on
///   every write, so month/year/all-time charts read 8,760 rows per year
///   instead of 525,600.
///
/// - `air` / `air_hourly`: the same pair for air purifiers (PM2.5 in µg/m³ and
///   the 1–12 allergen index, both integers).
///
/// Live samples always win over backfilled ones for the same minute.
///
/// Each instance owns one connection and is not thread-safe; confine it to
/// one thread or queue. The app writes through a main-actor instance and
/// reads charts through a separate `readOnly` instance on a background
/// queue (WAL mode lets the two run concurrently).
public final class Store: @unchecked Sendable {
    public enum StoreError: Error { case open(String), sql(String) }

    public static let schemaVersion: Int32 = 4

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private enum Source: Int { case live = 0, backfill = 1 }

    /// SQL fragment resolving a sensor UUID (bound as text) to its integer key.
    private static let key = "(SELECT key FROM sensors WHERE id = ?)"

    public init(path: String, readOnly: Bool = false) throws {
        if !readOnly {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        // The app and the CLI tools may touch the database at the same time.
        sqlite3_busy_timeout(db, 3000)
        if !readOnly { try migrate() }
    }

    /// `~/Library/Application Support/SensorTray/sensortray.sqlite`, or
    /// `$SENSORTRAY_DB` when set (testing against a copy of real data).
    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["SENSORTRAY_DB"], !override.isEmpty { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SensorTray/sensortray.sqlite").path
    }

    deinit { sqlite3_close(db) }

    // MARK: Schema

    public var userVersion: Int32 {
        query("PRAGMA user_version") { s in sqlite3_column_int(s, 0) }.first ?? 0
    }

    private static let schemaV2 = """
        CREATE TABLE IF NOT EXISTS sensors(
            key INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            model TEXT NOT NULL,
            is_main INTEGER NOT NULL DEFAULT 0,
            sort INTEGER NOT NULL DEFAULT 0,
            synced_through INTEGER,
            color TEXT,
            added_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS samples(
            sensor INTEGER NOT NULL,
            minute INTEGER NOT NULL,
            t INTEGER NOT NULL,       -- °C × 10
            h INTEGER NOT NULL,       -- %RH × 10
            src INTEGER NOT NULL,     -- 0 live, 1 backfill
            PRIMARY KEY(sensor, minute)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS hourly(
            sensor INTEGER NOT NULL,
            hour INTEGER NOT NULL,    -- unix minutes / 60
            n INTEGER NOT NULL,
            t_sum INTEGER NOT NULL, t_min INTEGER NOT NULL, t_max INTEGER NOT NULL,
            h_sum INTEGER NOT NULL, h_min INTEGER NOT NULL, h_max INTEGER NOT NULL,
            PRIMARY KEY(sensor, hour)
        ) WITHOUT ROWID;
        """

    private static let schemaV3 = """
        CREATE TABLE IF NOT EXISTS air(
            sensor INTEGER NOT NULL,
            minute INTEGER NOT NULL,
            pm INTEGER NOT NULL,      -- PM2.5 µg/m³
            iai INTEGER NOT NULL,     -- allergen index 1–12
            PRIMARY KEY(sensor, minute)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS air_hourly(
            sensor INTEGER NOT NULL,
            hour INTEGER NOT NULL,
            n INTEGER NOT NULL,
            pm_sum INTEGER NOT NULL, pm_min INTEGER NOT NULL, pm_max INTEGER NOT NULL,
            iai_sum INTEGER NOT NULL, iai_min INTEGER NOT NULL, iai_max INTEGER NOT NULL,
            PRIMARY KEY(sensor, hour)
        ) WITHOUT ROWID;
        """

    /// Brings any database up to the current schema, one transaction:
    /// v1 (TEXT sensor ids, REAL values, no rollup) → v2 → v3 (air tables)
    /// → v4 (outdoor flag).
    private func migrate() throws {
        try exec("PRAGMA journal_mode=WAL")
        let version = userVersion
        guard version < Self.schemaVersion else { return }

        let fromV1 = tableExists("readings")
        try exec("BEGIN IMMEDIATE")
        do {
            if version < 2 { try migrateToV2(fromV1: fromV1) }
            try exec(Self.schemaV3)
            if version < 4 { try exec("ALTER TABLE sensors ADD COLUMN is_outdoor INTEGER NOT NULL DEFAULT 0") }
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        // Hand the space the bulkier v1 rows used back to the filesystem.
        if fromV1 { try? exec("VACUUM") }
    }

    private func migrateToV2(fromV1: Bool) throws {
        do {
            if tableExists("sensors") {
                // 0.1.0 databases predate the color column; ignore "duplicate column".
                try? exec("ALTER TABLE sensors ADD COLUMN color TEXT")
                try exec("ALTER TABLE sensors RENAME TO sensors_v1")
            }
            try exec(Self.schemaV2)
            if tableExists("sensors_v1") {
                try exec("""
                    INSERT INTO sensors(id, name, model, is_main, sort, synced_through, color, added_at)
                    SELECT id, name, model, is_main, sort, synced_through, color, added_at FROM sensors_v1;
                    DROP TABLE sensors_v1;
                    """)
            }
            if fromV1 {
                try exec("""
                    INSERT OR REPLACE INTO samples
                    SELECT s.key, r.minute, CAST(round(r.temp_c * 10) AS INTEGER),
                           CAST(round(r.humidity * 10) AS INTEGER), r.source
                    FROM readings r JOIN sensors s ON s.id = r.sensor_id;
                    DROP TABLE readings;
                    INSERT OR REPLACE INTO hourly
                    SELECT sensor, minute / 60, COUNT(*), SUM(t), MIN(t), MAX(t), SUM(h), MIN(h), MAX(h)
                    FROM samples GROUP BY sensor, minute / 60;
                    """)
            }
        }
    }

    private func tableExists(_ name: String) -> Bool {
        !query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]) { _ in true }.isEmpty
    }

    // MARK: Sensors

    public func sensors() -> [SensorConfig] {
        query("SELECT id, name, model, is_main, sort, color, is_outdoor FROM sensors ORDER BY sort, added_at") { s in
            guard let id = UUID(uuidString: text(s, 0)),
                  let model = SensorModel(rawValue: text(s, 2)) else { return nil }
            return SensorConfig(id: id, name: text(s, 1), model: model,
                                isMain: sqlite3_column_int(s, 3) != 0, sort: Int(sqlite3_column_int(s, 4)),
                                colorHex: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : text(s, 5),
                                isOutdoor: sqlite3_column_int(s, 6) != 0)
        }
    }

    /// Inserts or updates name/model/main/sort, keeping sync state, color and
    /// the outdoor flag.
    public func save(_ sensor: SensorConfig) {
        run("""
            INSERT INTO sensors(id, name, model, is_main, sort, added_at) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, model=excluded.model,
                is_main=excluded.is_main, sort=excluded.sort
            """, [sensor.id.uuidString, sensor.name, sensor.model.rawValue, sensor.isMain ? 1 : 0, sensor.sort, Int(Date().timeIntervalSince1970)])
    }

    public func setColor(id: UUID, hex: String?) {
        run("UPDATE sensors SET color = ? WHERE id = ?", [hex as Any, id.uuidString])
    }

    /// Makes `id` the main (indoor) sensor; it stops being the outdoor one.
    public func setMain(id: UUID) {
        run("UPDATE sensors SET is_main = (id = ?1), is_outdoor = is_outdoor AND id <> ?1", [id.uuidString])
    }

    /// Marks `id` as the outdoor sensor (clearing any other, and its main
    /// flag), or nil for none.
    public func setOutdoor(id: UUID?) {
        run("UPDATE sensors SET is_outdoor = (id = ?)", [id?.uuidString ?? ""])
        if let id { run("UPDATE sensors SET is_main = 0 WHERE id = ?", [id.uuidString]) }
    }

    public func delete(id: UUID) {
        run("DELETE FROM samples WHERE sensor = \(Self.key)", [id.uuidString])
        run("DELETE FROM hourly WHERE sensor = \(Self.key)", [id.uuidString])
        run("DELETE FROM air WHERE sensor = \(Self.key)", [id.uuidString])
        run("DELETE FROM air_hourly WHERE sensor = \(Self.key)", [id.uuidString])
        run("DELETE FROM sensors WHERE id = ?", [id.uuidString])
    }

    /// Marks history up to `minute` as already fetched from the device, so
    /// holes the device itself can't fill (e.g. after a battery swap) aren't
    /// re-requested on every sync.
    public func setSyncedThrough(_ id: UUID, minute: Int) {
        run("UPDATE sensors SET synced_through = ? WHERE id = ?", [minute, id.uuidString])
    }

    func syncedThrough(_ id: UUID) -> Int? {
        optionalInt("SELECT synced_through FROM sensors WHERE id = ?", [id.uuidString])
    }

    // MARK: Writing readings

    public func insertLive(_ id: UUID, minute: Int, reading: Reading) {
        run("INSERT OR REPLACE INTO samples VALUES(\(Self.key), ?, ?, ?, ?)",
            [id.uuidString, minute, tenths(reading.tempC), tenths(reading.humidity), Source.live.rawValue])
        refreshHourly(id, from: minute, to: minute)
    }

    /// One transaction, one prepared statement; then a single rollup pass
    /// over the affected hours.
    public func insertBackfill(_ id: UUID, points: [HistoryPoint]) {
        guard let first = points.first else { return }
        var low = first.minute, high = first.minute
        run("BEGIN")
        batch("INSERT OR IGNORE INTO samples VALUES(\(Self.key), ?, ?, ?, ?)", points) { p in
            low = min(low, p.minute)
            high = max(high, p.minute)
            return [id.uuidString, p.minute, tenths(p.tempC), tenths(p.humidity), Source.backfill.rawValue]
        }
        refreshHourly(id, from: low, to: high)
        run("COMMIT")
    }

    /// Recomputes the rollup rows for every hour touching [from, to].
    private func refreshHourly(_ id: UUID, from: Int, to: Int) {
        run("""
            INSERT OR REPLACE INTO hourly
            SELECT sensor, minute / 60, COUNT(*), SUM(t), MIN(t), MAX(t), SUM(h), MIN(h), MAX(h)
            FROM samples WHERE sensor = \(Self.key) AND minute BETWEEN ? AND ?
            GROUP BY minute / 60
            """, [id.uuidString, from / 60 * 60, to / 60 * 60 + 59])
    }

    // MARK: Reading

    /// History for CSV export and tools: per-minute rows, or bucket averages
    /// when `bucketMinutes` > 1. Each point carries its bucket's first minute.
    public func series(_ id: UUID, from: Int, to: Int, bucketMinutes: Int) -> [HistoryPoint] {
        let bucket = max(1, bucketMinutes)
        let sql = bucket == 1
            ? "SELECT minute, t, h FROM samples WHERE sensor = \(Self.key) AND minute BETWEEN ? AND ? ORDER BY minute"
            : """
              SELECT (minute / \(bucket)) * \(bucket), AVG(t), AVG(h) FROM samples
              WHERE sensor = \(Self.key) AND minute BETWEEN ? AND ?
              GROUP BY minute / \(bucket) ORDER BY 1
              """
        return query(sql, [id.uuidString, from, to]) { s in
            HistoryPoint(minute: Int(sqlite3_column_int64(s, 0)),
                         tempC: sqlite3_column_double(s, 1) / 10, humidity: sqlite3_column_double(s, 2) / 10)
        }
    }

    /// Chart data: average, min and max per bucket over [from, to].
    ///
    /// Buckets that are whole hours read the hourly rollup; finer ones read
    /// minute samples (only used for ranges up to 7 days, so ≤ 10,080 rows).
    /// `alignOffset` (minutes, e.g. the local UTC offset) shifts bucket
    /// boundaries so day buckets run midnight to midnight local time; with the
    /// rollup it's rounded to whole hours.
    public func aggregate(_ id: UUID, from: Int, to: Int, bucketMinutes: Int, alignOffset: Int = 0) -> [SeriesPoint] {
        bucketed(Self.climateTables, id, from: from, to: to, bucketMinutes: bucketMinutes, alignOffset: alignOffset) { s in
            SeriesPoint(minute: Int(sqlite3_column_int64(s, 0)), count: Int(sqlite3_column_int64(s, 1)),
                        tempAvg: sqlite3_column_double(s, 2) / 10, tempMin: sqlite3_column_double(s, 3) / 10,
                        tempMax: sqlite3_column_double(s, 4) / 10, humAvg: sqlite3_column_double(s, 5) / 10,
                        humMin: sqlite3_column_double(s, 6) / 10, humMax: sqlite3_column_double(s, 7) / 10)
        }
    }

    /// Air purifier counterpart of `aggregate`: PM2.5 and allergen index per bucket.
    public func aggregateAir(_ id: UUID, from: Int, to: Int, bucketMinutes: Int, alignOffset: Int = 0) -> [AirPoint] {
        bucketed(Self.airTables, id, from: from, to: to, bucketMinutes: bucketMinutes, alignOffset: alignOffset) { s in
            AirPoint(minute: Int(sqlite3_column_int64(s, 0)), count: Int(sqlite3_column_int64(s, 1)),
                     pmAvg: sqlite3_column_double(s, 2), pmMin: sqlite3_column_double(s, 3), pmMax: sqlite3_column_double(s, 4),
                     iaiAvg: sqlite3_column_double(s, 5), iaiMin: sqlite3_column_double(s, 6), iaiMax: sqlite3_column_double(s, 7))
        }
    }

    /// Table and column names of one "two values per minute + hourly rollup" family.
    private struct Tables {
        let samples: String, hourly: String, a: String, b: String
    }
    private static let climateTables = Tables(samples: "samples", hourly: "hourly", a: "t", b: "h")
    private static let airTables = Tables(samples: "air", hourly: "air_hourly", a: "pm", b: "iai")

    /// Rows of (bucket start, count, a avg/min/max, b avg/min/max).
    private func bucketed<T>(_ t: Tables, _ id: UUID, from: Int, to: Int, bucketMinutes: Int, alignOffset: Int,
                             row: (OpaquePointer) -> T?) -> [T] {
        let b = max(1, bucketMinutes)
        if b >= 60 && b % 60 == 0 {
            let offset = alignOffset - alignOffset % 60
            let sql = """
                SELECT ((hour * 60 + \(offset)) / \(b)) * \(b) - \(offset), SUM(n),
                       SUM(\(t.a)_sum) * 1.0 / SUM(n), MIN(\(t.a)_min), MAX(\(t.a)_max),
                       SUM(\(t.b)_sum) * 1.0 / SUM(n), MIN(\(t.b)_min), MAX(\(t.b)_max)
                FROM \(t.hourly) WHERE sensor = \(Self.key) AND hour BETWEEN ? AND ?
                GROUP BY (hour * 60 + \(offset)) / \(b) ORDER BY 1
                """
            return query(sql, [id.uuidString, from / 60, to / 60], row: row)
        }
        let sql = """
            SELECT ((minute + \(alignOffset)) / \(b)) * \(b) - \(alignOffset), COUNT(*),
                   AVG(\(t.a)), MIN(\(t.a)), MAX(\(t.a)), AVG(\(t.b)), MIN(\(t.b)), MAX(\(t.b))
            FROM \(t.samples) WHERE sensor = \(Self.key) AND minute BETWEEN ? AND ?
            GROUP BY (minute + \(alignOffset)) / \(b) ORDER BY 1
            """
        return query(sql, [id.uuidString, from, to], row: row)
    }

    // MARK: Air purifier readings

    /// One minute of purifier data (the app carries the last report forward
    /// each minute while the purifier is reachable, since it only reports changes).
    public func insertAir(_ id: UUID, minute: Int, pm25: Int, allergenIndex: Int) {
        run("INSERT OR REPLACE INTO air VALUES(\(Self.key), ?, ?, ?)", [id.uuidString, minute, pm25, allergenIndex])
        run("""
            INSERT OR REPLACE INTO air_hourly
            SELECT sensor, minute / 60, COUNT(*), SUM(pm), MIN(pm), MAX(pm), SUM(iai), MIN(iai), MAX(iai)
            FROM air WHERE sensor = \(Self.key) AND minute BETWEEN ? AND ?
            GROUP BY minute / 60
            """, [id.uuidString, minute / 60 * 60, minute / 60 * 60 + 59])
    }

    /// Most recent stored purifier minute: (minute, PM2.5, allergen index).
    public func lastAir(_ id: UUID) -> (minute: Int, pm25: Int, allergenIndex: Int)? {
        query("SELECT minute, pm, iai FROM air WHERE sensor = \(Self.key) ORDER BY minute DESC LIMIT 1", [id.uuidString]) { s in
            (Int(sqlite3_column_int64(s, 0)), Int(sqlite3_column_int64(s, 1)), Int(sqlite3_column_int64(s, 2)))
        }.first
    }

    public func firstMinute(_ id: UUID) -> Int? {
        optionalInt("SELECT MIN(minute) FROM samples WHERE sensor = \(Self.key)", [id.uuidString])
    }

    public func lastMinute(_ id: UUID) -> Int? {
        optionalInt("SELECT MAX(minute) FROM samples WHERE sensor = \(Self.key)", [id.uuidString])
    }

    /// Oldest reading of any configured sensor or purifier (each lookup uses a primary key).
    public func earliestMinute() -> Int? {
        optionalInt("""
            SELECT MIN(MIN(IFNULL((SELECT MIN(minute) FROM samples WHERE sensor = s.key), 9223372036854775807),
                           IFNULL((SELECT MIN(minute) FROM air WHERE sensor = s.key), 9223372036854775807)))
            FROM sensors s
            """).flatMap { $0 == Int.max ? nil : $0 }
    }

    public func sampleCount(_ id: UUID) -> Int {
        optionalInt("SELECT COUNT(*) FROM samples WHERE sensor = \(Self.key)", [id.uuidString]) ?? 0
    }

    /// The first minute of the earliest run of at least `minGap` missing
    /// minutes within the last `windowMinutes` (and after `synced_through`),
    /// or nil when there's nothing worth downloading.
    public func oldestGapStart(_ id: UUID, now: Int, windowMinutes: Int, minGap: Int) -> Int? {
        var cursor = now - windowMinutes
        if let synced = syncedThrough(id) { cursor = max(cursor, synced) }
        let minutes: [Int] = query("SELECT minute FROM samples WHERE sensor = \(Self.key) AND minute >= ? ORDER BY minute",
                                   [id.uuidString, cursor]) { s in Int(sqlite3_column_int64(s, 0)) }
        // `cursor` is the first minute not yet known to be covered.
        for m in minutes {
            if m - cursor >= minGap { return cursor }
            cursor = max(cursor, m + 1)
        }
        return now - cursor + 1 >= minGap ? cursor : nil
    }

    // MARK: SQLite plumbing

    private func tenths(_ value: Double) -> Int { Int((value * 10).rounded()) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(message)
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("SensorTray SQL prepare failed: %@ — %@", sql, String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ args: [Any]) {
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Store.transient)
            default: sqlite3_bind_null(stmt, index)
            }
        }
    }

    private func run(_ sql: String, _ args: [Any] = []) {
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("SensorTray SQL failed: %@ — %@", sql, String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Runs one statement per element, preparing it only once.
    private func batch<T>(_ sql: String, _ items: [T], args: (T) -> [Any]) {
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        for item in items {
            bind(stmt, args(item))
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("SensorTray SQL failed: %@ — %@", sql, String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
    }

    private func query<T>(_ sql: String, _ args: [Any] = [], row: (OpaquePointer) -> T?) -> [T] {
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = row(stmt) { out.append(value) }
        }
        return out
    }

    private func optionalInt(_ sql: String, _ args: [Any] = []) -> Int? {
        query(sql, args) { s in
            sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, 0))
        }.first
    }
}

private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
}
