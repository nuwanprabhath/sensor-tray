import Foundation
import SensorTrayCore

/// Calibration: correcting one thermometer to match another, from periods
/// when the two sat side by side.
///
/// Stored readings are never changed. The fitted correction is applied when
/// readings are shown (cards, menu bar, comparisons, charts, markers), so the
/// popover's Calibrated toggle can switch everything back to raw instantly.
extension AppModel {
    /// The correction to show `id` with right now: nil when the toggle is
    /// off, the sensor has no calibration, or it's disabled.
    func correction(for id: UUID) -> CalibrationFit? {
        guard useCalibration, let calibration = calibrations[id], calibration.enabled else { return nil }
        return calibration.fit
    }

    /// The latest reading of `id` as it should be displayed.
    func displayReading(_ id: UUID) -> LiveReading? {
        guard var live = latest[id] else { return nil }
        if let fit = correction(for: id) { live.reading = fit.apply(live.reading) }
        return live
    }

    func calibrationReferenceName(_ id: UUID) -> String {
        calibrations[id].flatMap { cal in sensors.first { $0.id == cal.reference }?.name } ?? "its reference"
    }

    var hasCalibrations: Bool { calibrations.values.contains { $0.fit != nil } }

    func setUseCalibration(_ on: Bool) {
        useCalibration = on
        UserDefaults.standard.set(on, forKey: "useCalibration")
        pushCorrections()
    }

    func reloadCalibrations() {
        calibrations = Dictionary(uniqueKeysWithValues: store.calibrations().map { ($0.sensor, $0) })
        pushCorrections()
    }

    private func pushCorrections() {
        var active: [UUID: CalibrationFit] = [:]
        for id in calibrations.keys {
            if let fit = correction(for: id) { active[id] = fit }
        }
        charts.setCorrections(active)
    }

    // MARK: Editing

    func addCalibrationSession(sensor: UUID, reference: UUID, start: Int, end: Int, settle: Int) {
        store.addCalibrationSession(sensor: sensor, reference: reference, start: start, end: end, settle: settle)
        refitAll()
    }

    func deleteCalibrationSession(_ id: Int) {
        store.deleteCalibrationSession(id: id)
        refitAll()
    }

    func deleteCalibration(sensor: UUID) {
        store.deleteCalibration(sensor: sensor)
        refitAll()
    }

    func setCalibrationEnabled(sensor: UUID, _ enabled: Bool) {
        store.setCalibrationEnabled(sensor: sensor, enabled: enabled)
        // Sensors calibrated against this one were fitted to its corrected values.
        refitAll()
    }

    /// Whether `reference` may serve as the target for `sensor`: not itself,
    /// a thermometer, and not (via a chain) corrected against `sensor`.
    func canReference(_ reference: UUID, for sensor: UUID) -> Bool {
        guard reference != sensor,
              sensors.contains(where: { $0.id == reference && !$0.model.isAirPurifier }) else { return false }
        var next: UUID? = calibrations[reference]?.reference
        var seen: Set<UUID> = [reference]
        while let current = next, seen.insert(current).inserted {
            if current == sensor { return false }
            next = calibrations[current]?.reference
        }
        return true
    }

    /// Pairs for one side-by-side period, with the reference's own enabled
    /// calibration applied, so a chain (A matches B, B matches C) lines up.
    func calibrationPairs(sensor: UUID, reference: UUID, start: Int, end: Int, settle: Int) -> [CalibrationPair] {
        let pairs = store.calibrationPairs(sensor: sensor, reference: reference, from: start + settle, to: end)
        guard let referenceCalibration = calibrations[reference], referenceCalibration.enabled,
              let fit = referenceCalibration.fit else { return pairs }
        return pairs.map { p in
            let corrected = fit.apply(Reading(tempC: p.refTemp, humidity: p.refHumidity, battery: nil))
            return CalibrationPair(minute: p.minute, rawTemp: p.rawTemp, rawHumidity: p.rawHumidity,
                                   refTemp: corrected.tempC, refHumidity: corrected.humidity)
        }
    }

    /// Refits every calibration from all of its sessions, references first,
    /// so chained calibrations use their reference's latest correction.
    func refitAll() {
        calibrations = Dictionary(uniqueKeysWithValues: store.calibrations().map { ($0.sensor, $0) })
        var done: Set<UUID> = []
        var pending = Array(calibrations.keys)
        while !pending.isEmpty {
            let ready = pending.filter { id in
                guard let reference = calibrations[id]?.reference, calibrations[reference] != nil else { return true }
                return done.contains(reference) || !pending.contains(reference)
            }
            // A cycle can't be created from the UI; fit whatever is left rather than loop.
            for id in ready.isEmpty ? pending : ready {
                guard let calibration = calibrations[id] else { continue }
                let pairs = calibration.sessions.flatMap {
                    calibrationPairs(sensor: id, reference: calibration.reference, start: $0.start, end: $0.end, settle: $0.settle)
                }
                let fit = Calibrator.fit(pairs)
                store.setCalibrationFit(sensor: id, fit: fit)
                calibrations[id]?.fit = fit
                done.insert(id)
            }
            pending.removeAll { done.contains($0) }
        }
        pushCorrections()
    }
}

extension LinearCorrection {
    /// "−0.10°C", or "−0.3°C at 20°C to −0.5°C at 27°C" when it varies.
    func describe(unit: String, decimals: Int) -> String {
        func signed(_ v: Double) -> String { SensorCard.signed(v, decimals: decimals) + unit }
        func plain(_ v: Double) -> String { String(format: "%.0f", v) + unit }
        if isConstant { return signed(offset) }
        return "\(signed(delta(at: low))) at \(plain(low)) to \(signed(delta(at: high))) at \(plain(high))"
    }
}

extension CalibrationFit {
    /// "temperature −0.10°C, humidity +7.2%"
    var summary: String {
        "temperature \(temperature.describe(unit: "°C", decimals: 2)), humidity \(humidity.describe(unit: "%", decimals: 1))"
    }
}
