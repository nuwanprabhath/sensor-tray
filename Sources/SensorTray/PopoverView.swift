import CoreBluetooth
import SensorTrayCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("chartRange") private var range: ChartRange = .day
    @AppStorage("chartMetric") private var metric: ChartMetric = .temperature

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
                        SensorCard(sensor: sensor)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Metric", selection: $metric) {
                            ForEach(ChartMetric.allCases) { Image(systemName: $0.symbol).help($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 76)

                        Spacer()

                        Picker("Range", selection: $range) {
                            ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    HistoryChart(range: range, metric: metric)
                        .frame(height: 150)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }

            footer
        }
        .padding(12)
        .frame(width: 360)
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
