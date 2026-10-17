import SensorTrayCore
import ServiceManagement
import SwiftUI

/// Manage sensors: rename, choose the menu bar one, reorder, export, remove,
/// and add newly discovered ones.
struct SensorsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var launchAtLogin = ViewState(LoginItem.isEnabled)
    @StateObject private var confirmRemove = ViewState<SensorConfig?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Your sensors") {
                if model.sensors.isEmpty {
                    Text("Nothing added yet — pick a sensor below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(model.sensors.enumerated()), id: \.element.id) { index, sensor in
                        if index > 0 { Divider() }
                        ConfiguredRow(sensor: sensor, index: index, onRemove: { confirmRemove.value = sensor })
                    }
                }
            }

            section("Nearby") {
                let nearby = model.unconfiguredNearby
                if nearby.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Govee and ThermoPro sensors…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(Array(nearby.enumerated()), id: \.element.id) { index, sensor in
                        if index > 0 { Divider() }
                        NearbyRow(sensor: sensor)
                    }
                }
            }

            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin.value)
                    .onChange(of: launchAtLogin.value) { _, enabled in
                        launchAtLogin.value = LoginItem.set(enabled)
                    }
                Spacer()
                Text("Readings are stored on this Mac only.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 480)
        .alert("Remove \(confirmRemove.value?.name ?? "sensor")?", isPresented: Binding(
            get: { confirmRemove.value != nil }, set: { if !$0 { confirmRemove.value = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let sensor = confirmRemove.value { model.remove(sensor.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its stored history is deleted too.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct ConfiguredRow: View {
    @EnvironmentObject private var model: AppModel
    let sensor: SensorConfig
    let index: Int
    let onRemove: () -> Void
    @StateObject private var name = ViewState("")

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(model.color(for: sensor)).frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .onSubmit { model.rename(sensor.id, to: name.value) }
                    .onAppear { name.value = sensor.name }
                    .onChange(of: sensor.name) { _, newName in name.value = newName }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.setMain(sensor.id)
            } label: {
                Image(systemName: sensor.isMain ? "star.fill" : "star")
                    .foregroundStyle(sensor.isMain ? .yellow : .secondary)
            }
            .help(sensor.isMain ? "Shown in the menu bar" : "Show in the menu bar")

            Button { model.move(sensor.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move up")
            Button { model.move(sensor.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == model.sensors.count - 1)
                .help("Move down")
            Button { model.exportCSV(sensor.id) } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export history as CSV")
            Button(action: onRemove) { Image(systemName: "trash") }
                .help("Remove sensor")
        }
        .buttonStyle(.borderless)
        .onDisappear { model.rename(sensor.id, to: name.value) }
        // Saves ~0.8s after typing stops, so renames stick without Return.
        .task(id: name.value) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { model.rename(sensor.id, to: name.value) }
        }
    }

    private var subtitle: String {
        // The advertised name (e.g. "GVH5075_8D84") tells identical units apart.
        var parts = [model.nearby[sensor.id]?.advert.name ?? "\(sensor.model.brand.displayName) \(sensor.model.displayName)"]
        if let live = model.latest[sensor.id] {
            parts.append(String(format: "%.1f°C · %.0f%%", live.reading.tempC, live.reading.humidity))
        }
        return parts.joined(separator: " · ")
    }
}

private struct NearbyRow: View {
    @EnvironmentObject private var model: AppModel
    let sensor: NearbySensor

    var body: some View {
        HStack(spacing: 10) {
            SignalBars(rssi: sensor.advert.rssi)

            VStack(alignment: .leading, spacing: 2) {
                Text(sensor.advert.name)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Add") { model.add(sensor) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var subtitle: String {
        var parts = ["\(sensor.advert.model.brand.displayName) \(sensor.advert.model.displayName)"]
        if let r = sensor.advert.reading {
            parts.append(String(format: "%.1f°C · %.0f%%", r.tempC, r.humidity))
        }
        return parts.joined(separator: " · ")
    }
}

/// Four bars from RSSI so you can tell which sensor is the one next to you.
struct SignalBars: View {
    let rssi: Int

    private var level: Int {
        switch rssi {
        case (-60)...: return 4
        case (-70)...: return 3
        case (-80)...: return 2
        default: return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= level ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(3 + bar * 3))
            }
        }
        .frame(width: 20, height: 16, alignment: .bottom)
        .help("Signal \(rssi) dBm")
    }
}
