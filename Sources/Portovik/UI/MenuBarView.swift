import SwiftUI

/// Окошко из строки меню: быстрый список «порт — кто» с кнопкой «освободить».
struct MenuBarView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.showSystem) private var showSystem = true
    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let binding: PortBinding
        let entity: Entity
    }

    private var rows: [Row] {
        let snap = monitor.snapshot
        let m = VisibleModel.build(snap, .init(search: query, showSystem: showSystem, showClients: false, includeStopped: false))
        var out: [Row] = []
        for vg in m.groups {
            for e in vg.entities where e.isRunning {
                for b in e.publicPorts { out.append(Row(id: "\(e.id)|\(b.id)", binding: b, entity: e)) }
            }
        }
        return out.sorted { $0.binding.port < $1.binding.port }
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Порт или приложение", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)

            Divider()

            if rows.isEmpty {
                let free = VisibleModel.build(monitor.snapshot, .init(search: query)).freePort
                VStack(spacing: 6) {
                    if let free {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Palette.loopback)
                        Text("Порт \(String(free)) свободен").font(.headline)
                    } else {
                        Text(monitor.snapshot.scanned ? "Ничего не найдено" : "Загрузка…").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { r in MenuRow(binding: r.binding, entity: r.entity) }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(CGFloat(rows.count) * 40 + 8, 420))
            }

            Divider()

            HStack {
                Button("Открыть Портовик") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Toggle("macOS", isOn: $showSystem)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Показывать службы macOS")
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .onAppear { monitor.menuOpen = true }
        .onDisappear { monitor.menuOpen = false }
    }
}

private struct MenuRow: View {
    let binding: PortBinding
    let entity: Entity
    @Environment(Monitor.self) private var monitor
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.scope(binding.scope)).frame(width: 7, height: 7)
            Text(binding.label)
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .frame(width: 74, alignment: .leading)
            EntityIcon(icon: entity.icon, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(entity.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !entity.subtitle.isEmpty {
                    Text(entity.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if binding.proto == .tcp {
                IconButton(symbol: "safari", help: "Открыть в браузере") { monitor.openInBrowser(binding.port) }
            }
            if !entity.isDockerEngine {
                IconButton(symbol: entity.kind == .container ? "stop.circle" : "xmark.circle",
                           help: entity.kind == .container ? "Остановить контейнер" : "Завершить") {
                    monitor.terminate(entity)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(hover ? Color.primary.opacity(0.06) : .clear)
        .onHover { hover = $0 }
        .help(PortChip.tooltip(binding))
    }
}
