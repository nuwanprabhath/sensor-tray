import Charts
import SensorTrayCore
import SwiftUI

/// Calibrate one thermometer against another: list existing calibrations,
/// and add a period when the two sat side by side, with a live preview of
/// the fitted correction.
struct CalibrationView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var draft = ViewState(Draft())
    @StateObject private var preview = ViewState<Preview?>(nil)
    @StateObject private var previewMetric = ViewState(ChartMetric.temperature)

    struct Draft: Equatable {
        var sensor: UUID?
        var reference: UUID?
        var start = Date().addingTimeInterval(-3 * 3600)
        var end = Date()
        var settle = 30
    }

    struct Preview: Equatable {
        let pairs: [CalibrationPair]
        let fit: CalibrationFit?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two thermometers in the same spot should read the same, but different brands rarely do. Put them side by side for a few hours, then tell Sensor Tray when, and which one to correct. The other is left as it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            section("Calibrations") {
                let list = model.sensors.compactMap { model.calibrations[$0.id] }
                if list.isEmpty {
                    Text("None yet. Add a side-by-side session below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(list.enumerated()), id: \.element.sensor) { index, calibration in
                        if index > 0 { Divider() }
                        CalibrationRow(calibration: calibration)
                    }
                }
            }

            section("Add a side-by-side session") {
                editor
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: setDefaults)
        .task(id: draft.value) { refreshPreview() }
    }

    // MARK: Editor

    private var thermometers: [SensorConfig] { model.sensors.filter { !$0.model.isAirPurifier } }

    @ViewBuilder
    private var editor: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Correct")
                sensorPicker(selection: $draft.value.sensor, options: thermometers)
                    .help("The sensor you trust less. Its readings get the correction.")
            }
            GridRow {
                Text("to match")
                sensorPicker(selection: $draft.value.reference,
                             options: thermometers.filter { s in draft.value.sensor.map { model.canReference(s.id, for: $0) } ?? true })
                    .help("The sensor you trust more. Its readings stay as they are.")
            }
            GridRow {
                Text("Together from")
                DatePicker("From", selection: $draft.value.start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
            }
            GridRow {
                Text("until")
                HStack {
                    DatePicker("Until", selection: $draft.value.end, in: draft.value.start...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Button("Now") { draft.value.end = Date() }
                        .controlSize(.small)
                }
            }
            GridRow {
                Text("Skip first")
                Stepper("\(draft.value.settle) min while the moved sensor settles", value: $draft.value.settle, in: 0...120, step: 5)
            }
        }
        .font(.callout)

        if let sensor = draft.value.sensor, let reference = draft.value.reference,
           let existing = model.calibrations[sensor], existing.reference != reference {
            Label("\(name(sensor)) is calibrated against \(name(existing.reference)). Saving replaces that calibration.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        previewView

        HStack {
            Spacer()
            Button("Save session") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(preview.value?.fit == nil)
        }
    }

    private func sensorPicker(selection: Binding<UUID?>, options: [SensorConfig]) -> some View {
        Picker("", selection: selection) {
            Text("Choose…").tag(UUID?.none)
            ForEach(options) { sensor in
                Text(sensor.name).tag(UUID?.some(sensor.id))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private var previewView: some View {
        if draft.value.sensor == nil || draft.value.reference == nil {
            EmptyView()
        } else if let preview = preview.value, let fit = preview.fit {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(preview.pairs.count) ten-minute pairs, \(durationText(preview.pairs.count * 10)) side by side after settling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    resultRow("Temperature", fit.temperature, unit: "°C", decimals: 2,
                              error: fit.temperatureError, minimumSpan: Calibrator.minimumTemperatureSpan)
                    resultRow("Humidity", fit.humidity, unit: "%", decimals: 1,
                              error: fit.humidityError, minimumSpan: Calibrator.minimumHumiditySpan)
                }
                .font(.callout)
                differenceChart(preview)
            }
        } else {
            Text("Needs at least an hour (after settling) when both sensors have readings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resultRow(_ title: String, _ correction: LinearCorrection, unit: String, decimals: Int,
                           error: Double, minimumSpan: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Text(correction.describe(unit: unit, decimals: decimals))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Spacer()
                Text("±" + String(format: decimals == 2 ? "%.2f" : "%.1f", error) + unit + " left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Typical difference left after correcting (RMS)")
            }
            Text(correction.isConstant
                     ? String(format: "Constant: readings only covered %.1f–%.1f%@. A session at a different \(title.lowercased()) lets it vary with the reading.",
                              correction.low, correction.high, unit)
                     : String(format: "Varies with the reading across %.1f–%.1f%@, held at the edge values beyond.",
                              correction.low, correction.high, unit))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 98)
        }
    }

    /// The measured difference (reference − raw) over time, and the
    /// correction the fit would apply at each point.
    private func differenceChart(_ preview: Preview) -> some View {
        let isTemp = previewMetric.value == .temperature
        let fit = preview.fit
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Difference: \(name(draft.value.reference)) minus \(name(draft.value.sensor))")
                    .font(.caption.weight(.medium))
                Spacer()
                Picker("Metric", selection: $previewMetric.value) {
                    Image(systemName: ChartMetric.temperature.symbol).tag(ChartMetric.temperature)
                    Image(systemName: ChartMetric.humidity.symbol).tag(ChartMetric.humidity)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 64)
            }
            Chart {
                ForEach(preview.pairs, id: \.minute) { p in
                    let raw = isTemp ? p.rawTemp : p.rawHumidity
                    let diff = isTemp ? p.refTemp - p.rawTemp : p.refHumidity - p.rawHumidity
                    PointMark(x: .value("Time", HistoryChart.date(p.minute)), y: .value("Measured", diff))
                        .symbolSize(10)
                        .foregroundStyle(Color.secondary)
                    if let fit {
                        LineMark(x: .value("Time", HistoryChart.date(p.minute)),
                                 y: .value("Correction", (isTemp ? fit.temperature : fit.humidity).delta(at: raw)))
                            .foregroundStyle(HistoryChart.markerColor)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.primary.opacity(0.25))
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.15))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Self.axisLabel(v, unit: isTemp ? "°C" : "%")).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.15))
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9))
                }
            }
            .frame(height: 110)
            HStack(spacing: 12) {
                Label("Measured", systemImage: "circle.fill").foregroundStyle(.secondary)
                Label("Correction applied", systemImage: "line.diagonal").foregroundStyle(HistoryChart.markerColor)
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
    }

    // MARK: Actions

    private func setDefaults() {
        guard draft.value.sensor == nil else { return }
        let main = model.mainSensor?.id
        draft.value.reference = main
        draft.value.sensor = thermometers.first { $0.id != main && !$0.isOutdoor }?.id ?? thermometers.first { $0.id != main }?.id
    }

    private func refreshPreview() {
        guard let sensor = draft.value.sensor, let reference = draft.value.reference, sensor != reference else {
            preview.value = nil
            return
        }
        let pairs = model.calibrationPairs(sensor: sensor, reference: reference, start: Int.nowMinute(draft.value.start),
                                           end: Int.nowMinute(draft.value.end), settle: draft.value.settle)
        preview.value = Preview(pairs: pairs, fit: Calibrator.fit(pairs))
    }

    private func save() {
        guard let sensor = draft.value.sensor, let reference = draft.value.reference else { return }
        model.addCalibrationSession(sensor: sensor, reference: reference, start: Int.nowMinute(draft.value.start),
                                    end: Int.nowMinute(draft.value.end), settle: draft.value.settle)
    }

    // MARK: Helpers

    /// Enough decimals that neighbouring ticks never print the same
    /// (small differences put ticks at 0.05 or 0.02 steps).
    static func axisLabel(_ v: Double, unit: String) -> String {
        let decimals = (0...2).first { d in
            let scale = pow(10, Double(d))
            return abs(v * scale - (v * scale).rounded()) < 0.001
        } ?? 2
        return SensorCard.signed(v, decimals: decimals) + unit
    }

    private func name(_ id: UUID?) -> String {
        id.flatMap { id in model.sensors.first { $0.id == id }?.name } ?? "?"
    }

    private func durationText(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// One saved calibration: what it corrects, the fitted correction, its
/// sessions, an on/off switch and delete.
private struct CalibrationRow: View {
    @EnvironmentObject private var model: AppModel
    let calibration: SensorCalibration

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                dot(calibration.sensor)
                Text(name(calibration.sensor)).fontWeight(.semibold)
                Text("matches").foregroundStyle(.secondary)
                dot(calibration.reference)
                Text(name(calibration.reference))
                Spacer()
                Toggle("On", isOn: Binding(get: { calibration.enabled },
                                           set: { model.setCalibrationEnabled(sensor: calibration.sensor, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(calibration.enabled ? "Applied. Turn off to stop correcting this sensor." : "Not applied")
                Button { model.deleteCalibration(sensor: calibration.sensor) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this calibration and its sessions")
            }
            .font(.callout)

            if let fit = calibration.fit {
                Text(fit.summary.prefix(1).uppercased() + fit.summary.dropFirst())
                    .font(.callout.monospacedDigit())
                Text(String(format: "Fitted on %d ten-minute pairs · typical remaining difference ±%.2f°C, ±%.1f%%",
                            fit.pairs, fit.temperatureError, fit.humidityError))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not enough side-by-side data yet, so nothing is applied.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(calibration.sessions) { session in
                HStack(spacing: 6) {
                    Image(systemName: "calendar").foregroundStyle(.tertiary)
                    Text(HistoryChart.date(session.start)..<HistoryChart.date(session.end),
                         format: .interval.day().month(.abbreviated).hour().minute())
                    Text("· skip \(session.settle) min").foregroundStyle(.tertiary)
                    Spacer()
                    Button { model.deleteCalibrationSession(session.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove this session and refit")
                }
                .font(.caption)
            }
        }
    }

    private func dot(_ id: UUID) -> some View {
        Circle()
            .fill(model.sensors.first { $0.id == id }.map(model.color(for:)) ?? .gray)
            .frame(width: 7, height: 7)
    }

    private func name(_ id: UUID) -> String {
        model.sensors.first { $0.id == id }?.name ?? "Removed sensor"
    }
}
