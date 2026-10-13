import SwiftUI

/// Вид «Список»: группы-разделы, в каждом — приложения и контейнеры со своими портами.
struct ListModeView: View {
    let model: VisibleModel
    let snapshot: Snapshot
    @Binding var selection: String?
    @State private var expanded: [String: Bool] = [:]

    private struct ListSection: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let icon: IconSource
        let group: EntityGroup?
        var rows: [Entity]
        let collapsedByDefault: Bool
    }

    private var sections: [ListSection] {
        var out: [ListSection] = []
        var appsIndex: Int?
        for vg in model.groups {
            let g = vg.group
            if g.kind.isMeaningful || vg.entities.count > 1 {
                out.append(ListSection(id: g.id, title: g.title, subtitle: g.subtitle, icon: g.icon, group: g,
                                       rows: vg.entities,
                                       collapsedByDefault: g.kind == .system || g.kind == .stoppedCompose))
            } else {
                if appsIndex == nil {
                    appsIndex = out.count
                    out.append(ListSection(id: "__apps", title: "Приложения и службы", subtitle: nil,
                                           icon: .symbol("square.grid.2x2.fill", 0.62), group: nil, rows: [],
                                           collapsedByDefault: false))
                }
                out[appsIndex!].rows += vg.entities
            }
        }
        if let i = appsIndex {
            out[i].rows.sort { a, b in
                (a.ports.first?.port ?? .max, a.title) < (b.ports.first?.port ?? .max, b.title)
            }
        }
        return out
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { sec in
                let isOpen = expanded[sec.id] ?? !(sec.collapsedByDefault && model.query.isEmpty)
                Section {
                    if isOpen {
                        ForEach(sec.rows) { e in
                            EntityRow(entity: e, snapshot: snapshot, showGroup: sec.group == nil)
                                .tag(e.id)
                                .contextMenu { EntityMenuItems(entity: e) }
                        }
                    }
                } header: {
                    SectionHeader(title: sec.title, subtitle: sec.subtitle, icon: sec.icon, group: sec.group,
                                  count: sec.rows.count, isOpen: isOpen,
                                  isSelected: sec.group.map { $0.id == selection } ?? false,
                                  toggle: { expanded[sec.id] = !isOpen },
                                  select: { if let g = sec.group { selection = g.id } })
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.visible)
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String?
    let icon: IconSource
    let group: EntityGroup?
    let count: Int
    let isOpen: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let select: () -> Void
    @Environment(Monitor.self) private var monitor

    var body: some View {
        HStack(spacing: 7) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            EntityIcon(icon: icon, size: 18)
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let kind = group?.kind, kind == .compose || kind == .stoppedCompose {
                Text("compose")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Palette.docker.opacity(0.15), in: Capsule())
                    .foregroundStyle(Palette.docker)
            }
            Spacer()
            if let g = group, let b = monitor.busy[g.id] {
                ProgressView().controlSize(.mini)
                Text(b).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("\(count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            if let g = group, g.kind != .single, g.kind != .service {
                Menu {
                    GroupMenuItems(group: g)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Действия с группой")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggle)
        .onTapGesture(perform: select)
        .contextMenu { if let g = group { GroupMenuItems(group: g) } }
    }
}

struct EntityRow: View {
    let entity: Entity
    let snapshot: Snapshot
    var showGroup = false
    @Environment(Monitor.self) private var monitor
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            EntityIcon(icon: entity.icon, size: 30)
                .opacity(entity.isRunning ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entity.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !entity.subtitle.isEmpty {
                        Text(entity.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let h = entity.health { HealthDot(health: h) }
                    if let b = monitor.busy[entity.id] {
                        ProgressView().controlSize(.mini)
                        Text(b).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    if !entity.isRunning {
                        Text("остановлен").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(entity.ports.prefix(8)) { PortChip(binding: $0) }
                    if entity.ports.count > 8 {
                        Text("+\(entity.ports.count - 8)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    LinkSummary(entity: entity, snapshot: snapshot)
                        .padding(.leading, entity.ports.isEmpty ? 0 : 4)
                }
            }
            Spacer(minLength: 8)
            meta
            buttons
                .opacity(hover ? 1 : 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder private var meta: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let pid = entity.pid {
                Text("PID \(String(pid))").font(.system(size: 11).monospacedDigit())
                let parts = [entity.cpu.map(Format.cpu), entity.memory.map(Format.bytes), entity.started.map { Format.age($0) }]
                    .compactMap { $0 }
                Text(parts.joined(separator: " · ")).font(.system(size: 10.5).monospacedDigit())
            } else if let cid = entity.containerID, let c = snapshot.containers[cid] {
                Text(c.name).font(.system(size: 11)).lineLimit(1)
                Text(c.status).font(.system(size: 10.5)).lineLimit(1)
            } else if entity.kind == .appClients {
                Text(entity.pids.count == 1 ? "1 процесс" : "\(entity.pids.count) процесса").font(.system(size: 11))
            }
        }
        .foregroundStyle(.secondary)
        .frame(minWidth: 90, alignment: .trailing)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 2) {
            if entity.isRunning, let p = entity.publicPorts.first(where: { $0.proto == .tcp }) {
                IconButton(symbol: "safari", help: "Открыть localhost:\(p.port)") { monitor.openInBrowser(p.port) }
            }
            if entity.kind == .container {
                if entity.isRunning {
                    IconButton(symbol: "stop.circle", help: "Остановить контейнер") { monitor.containerAction(entity, .stop) }
                } else {
                    IconButton(symbol: "play.circle", help: "Запустить контейнер") { monitor.containerAction(entity, .start) }
                }
            } else if !entity.isDockerEngine {
                IconButton(symbol: "xmark.circle", help: entity.kind == .appClients ? "Завершить приложение" : "Завершить процесс") {
                    monitor.terminate(entity)
                }
            }
        }
    }
}
