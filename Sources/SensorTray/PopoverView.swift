import CoreBluetooth
import SensorTrayCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let banner = bluetoothBanner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if model.sensors.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(model.sensors) { sensor in
                        if sensor.model.isAirPurifier {
                            PurifierCard(sensor: sensor)
                        } else {
                            SensorCard(sensor: sensor)
                        }
                    }
                }

                ChartPanel(charts: model.charts)
            }

            footer
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            // Each opening starts at the present.
            model.charts.goLive()
            model.charts.setSensors(model.sensors)
            model.charts.reload()
        }
        .onChange(of: model.sensors) { _, sensors in model.charts.setSensors(sensors) }
        .onChange(of: model.dataVersion) { _, _ in model.charts.reload() }
    }

    private var bluetoothBanner: String? {
        switch model.bluetoothState {
        case .poweredOff: return "Bluetooth is off."
        case .unauthorized: return "Allow Bluetooth for Sensor Tray in System Settings › Privacy & Security."
        case .unsupported: return "This Mac doesn't support Bluetooth LE."
        default: return nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No sensors yet")
                .font(.headline)
            Text("Add your Govee or ThermoPro sensors to start tracking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Sensors…") { showSensors() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showSensors()
            } label: {
                Label("Sensors", systemImage: "slider.horizontal.3")
            }

            Spacer()

            syncIndicator

            Spacer()

            if model.hasCalibrations {
                Toggle(isOn: Binding(get: { model.useCalibration }, set: { model.setUseCalibration($0) })) {
                    Text("Calibrated")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .help("On: readings, charts and the menu bar use your calibrations. Off: raw sensor readings.")
                Spacer()
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var syncIndicator: some View {
        if model.isSyncing {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(model.syncStatus ?? "Syncing…").lineLimit(1)
            }
        } else {
            Button {
                model.syncAll()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.lastSyncError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(model.lastSyncError == nil ? Color.secondary : Color.orange)
                    if let last = model.lastSync {
                        Text("Synced \(last, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
                            .lineLimit(1)
                    } else {
                        Text("Sync history")
                    }
                }
            }
            .help(model.lastSyncError ?? "Fill gaps from the sensors' onboard memory")
            .disabled(model.sensors.isEmpty)
        }
    }

    private func showSensors() {
        openWindow(id: "sensors")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Metric and range pickers, the time navigator, and the chart.
private struct ChartPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var charts: ChartModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Metric", selection: Binding(get: { charts.metric }, set: { charts.setMetric($0) })) {
                    ForEach(metrics) { Image(systemName: $0.symbol).help($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: CGFloat(metrics.count) * 32)

                Spacer(minLength: 6)

                Picker("Range", selection: Binding(get: { charts.window.range }, set: { charts.setRange($0) })) {
                    ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: metrics.count > 2 ? 212 : 236)
            }

            navigator

            Group {
                if let snapshot = charts.snapshot {
                    HistoryChart(snapshot: snapshot, metric: snapshot.metric, styles: styles, charts: charts)
                        .equatable()
                } else {
                    Color.clear
                }
            }
            .frame(height: 160)
            .help(charts.window.range == .all ? "" : "Drag or swipe sideways to move through time")

            if let focus = charts.snapshot?.focus {
                EventStrip(focus: focus, metric: charts.metric, styles: styles)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// PM2.5 is offered only when an air purifier is added.
    private var metrics: [ChartMetric] {
        model.hasPurifiers ? ChartMetric.allCases : [.temperature, .humidity]
    }

    private var styles: [SeriesStyle] {
        model.sensors.map { SeriesStyle(id: $0.id, name: $0.name, color: model.color(for: $0)) }
    }

    /// ‹  10 – 17 Oct 2026  ›            Now
    private var navigator: some View {
        HStack(spacing: 6) {
            let pannable = charts.window.range != .all
            if pannable {
                Button { charts.step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(!charts.canStepBack)
                    .help("Earlier")
            }
            Text(periodLabel)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .frame(minWidth: pannable ? 150 : nil, alignment: pannable ? .center : .leading)
            if pannable {
                Button { charts.step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!charts.canStepForward)
                    .help("Later")
            }
            Spacer()
            if !charts.window.isLive {
                Button("Now") { charts.goLive() }
                    .font(.system(size: 11, weight: .medium))
                    .help("Jump back to the latest readings")
            }
            Button { model.addEvent() } label: {
                Label("Mark", systemImage: "flag")
                    .font(.system(size: 11, weight: .medium))
            }
            .help("Mark this moment on the chart (e.g. windows opened) to see what changes afterwards")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private var periodLabel: String {
        let now = Int.nowMinute()
        let earliest = charts.snapshot?.earliest
        let span = charts.window.span(now: now, earliest: earliest)
        let start = HistoryChart.date(span.lowerBound)
        let end = HistoryChart.date(span.upperBound)
        switch charts.window.range {
        case .sixHours, .day:
            if charts.window.isLive { return charts.window.range == .day ? "Last 24 hours" : "Last 6 hours" }
            return (start..<end).formatted(.interval.day().month(.abbreviated).hour())
        case .week, .month:
            return (start..<end).formatted(.interval.day().month(.abbreviated).year())
        case .year:
            return (start..<end).formatted(.interval.month(.abbreviated).year())
        case .all:
            guard let earliest else { return "All history" }
            return "All history · since " + HistoryChart.date(earliest).formatted(.dateTime.month(.abbreviated).year())
        }
    }
}

/// The focused marker under the chart: an editable label with presets, when
/// it was, and how each sensor has changed since.
private struct EventStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var charts: ChartModel
    let focus: EventFocus
    let metric: ChartMetric
    let styles: [SeriesStyle]
    @StateObject private var label = ViewState("")

    static let presets = ["Windows opened", "Windows closed", "Heating on", "Heating off",
                          "Air con on", "Air con off", "Purifier on", "Cooking", "Shower"]

    var body: some View {
        let event = focus.event
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(HistoryChart.markerColor)
                TextField("What happened?", text: $label.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .onSubmit { save() }
                Menu {
                    ForEach(Self.presets, id: \.self) { preset in
                        Button(preset) {
                            label.value = preset
                            save()
                        }
                    }
                } label: {
                    Image(systemName: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick a label")
                Text(timeText(event))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Button { model.deleteEvent(event.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this marker")
            }
            if focus.changes.isEmpty {
                Text("Changes since the marker appear once new readings arrive.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(focus.changes, id: \.id) { change in
                        if let style = styles.first(where: { $0.id == change.id }) {
                            GridRow {
                                HStack(spacing: 4) {
                                    Circle().fill(style.color).frame(width: 6, height: 6)
                                    Text(style.name).lineLimit(1)
                                }
                                Text("\(metric.format(change.from)) → \(metric.format(change.to))")
                                    .foregroundStyle(.secondary)
                                Text(delta(change))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(deltaColor(change))
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                }
                .font(.system(size: 10).monospacedDigit())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(HistoryChart.markerColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { label.value = event.label }
        .onChange(of: event) { _, newEvent in label.value = newEvent.label }
        // Saves ~0.8 s after typing stops, like sensor renames.
        .task(id: label.value) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { save() }
        }
    }

    private func save() {
        guard label.value != focus.event.label else { return }
        model.renameEvent(focus.event.id, to: label.value)
    }

    /// "8:21 pm · 12 min ago", or the date for older markers.
    private func timeText(_ event: ChartEvent) -> String {
        let date = event.date
        let ago = Int(Date().timeIntervalSince(date) / 60)
        let clock = date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute()
                                                                     : .dateTime.day().month(.abbreviated).hour().minute())
        switch ago {
        case ..<1: return clock + " · just now"
        case ..<60: return clock + " · \(ago) min ago"
        case ..<(48 * 60): return clock + String(format: " · %.1f h ago", Double(ago) / 60)
        default: return clock
        }
    }

    private func delta(_ change: EventFocus.Change) -> String {
        let d = change.to - change.from
        switch metric {
        case .temperature: return SensorCard.signed(d, decimals: 1) + "°C"
        case .humidity: return SensorCard.signed(d, decimals: 0) + "%"
        case .pm25: return SensorCard.signed(d, decimals: 0) + " µg/m³"
        }
    }

    /// Temperature falling reads blue, rising red; other metrics stay neutral.
    private func deltaColor(_ change: EventFocus.Change) -> Color {
        // Rounded as displayed, so a shown "−0.1°C" is always coloured.
        let d = ((change.to - change.from) * 10).rounded() / 10
        guard metric == .temperature, d != 0 else { return .primary }
        return d < 0 ? .blue : .red
    }
}
