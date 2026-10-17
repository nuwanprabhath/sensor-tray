import Foundation

public enum Brand: String, Codable, Sendable {
    case govee
    case thermopro

    public var displayName: String {
        switch self {
        case .govee: return "Govee"
        case .thermopro: return "ThermoPro"
        }
    }
}

public enum SensorModel: String, Codable, Sendable, CaseIterable {
    case h5075
    case tp357
    case tp357s

    public var brand: Brand {
        switch self {
        case .h5075: return .govee
        case .tp357, .tp357s: return .thermopro
        }
    }

    public var displayName: String {
        switch self {
        case .h5075: return "H5075"
        case .tp357: return "TP357"
        case .tp357s: return "TP357S"
        }
    }

    /// How far back the device's onboard memory reaches, i.e. the furthest a
    /// history backfill can usefully ask for.
    public var historyRetentionMinutes: Int {
        switch self {
        case .h5075: return 20 * 1440
        case .tp357: return 7 * 1440    // minute data for 24h, hourly for the week
        case .tp357s: return 20 * 1440
        }
    }

    /// Resolves a model from an advertised local name, across all brands.
    public static func from(advertisedName name: String) -> SensorModel? {
        GoveeProtocol.model(forName: name) ?? ThermoProProtocol.model(forName: name)
    }
}

public struct Reading: Equatable, Sendable {
    public var tempC: Double
    public var humidity: Double
    /// Percent 0-100. ThermoPro only reports three coarse levels (10/50/100).
    public var battery: Int?

    public init(tempC: Double, humidity: Double, battery: Int?) {
        self.tempC = tempC
        self.humidity = humidity
        self.battery = battery
    }
}

public struct HistoryPoint: Equatable, Sendable {
    /// Unix time in whole minutes (seconds / 60).
    public var minute: Int
    public var tempC: Double
    public var humidity: Double

    public init(minute: Int, tempC: Double, humidity: Double) {
        self.minute = minute
        self.tempC = tempC
        self.humidity = humidity
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }
}

public struct Advert: Sendable {
    public var id: UUID
    public var name: String
    public var model: SensorModel
    public var reading: Reading?
    public var rssi: Int

    public init(id: UUID, name: String, model: SensorModel, reading: Reading?, rssi: Int) {
        self.id = id
        self.name = name
        self.model = model
        self.reading = reading
        self.rssi = rssi
    }
}

public struct SensorConfig: Identifiable, Equatable, Sendable {
    /// CoreBluetooth peripheral identifier (stable per Mac, not the MAC address).
    public var id: UUID
    public var name: String
    public var model: SensorModel
    public var isMain: Bool
    public var sort: Int

    public init(id: UUID, name: String, model: SensorModel, isMain: Bool, sort: Int) {
        self.id = id
        self.name = name
        self.model = model
        self.isMain = isMain
        self.sort = sort
    }
}

public extension Int {
    /// Current unix time in whole minutes.
    static func nowMinute(_ date: Date = Date()) -> Int { Int(date.timeIntervalSince1970) / 60 }
}
