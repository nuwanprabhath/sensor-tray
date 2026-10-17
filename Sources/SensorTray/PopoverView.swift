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
                        Text("Synced \(last, format: .relative(presentation: .named))")
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
