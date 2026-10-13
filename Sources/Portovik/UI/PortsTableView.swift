import SwiftUI

/// Вид «Порты»: плоская таблица, сортируется по любому столбцу.
struct PortsTableView: View {
    let model: VisibleModel
    let snapshot: Snapshot
    @Binding var selection: String?
    @State private var sortOrder = [KeyPathComparator(\PortRow.port)]
    @State private var tableSelection: PortRow.ID?

    struct PortRow: Identifiable {
        let id: String
        let port: Int
        let portLabel: String
        let proto: String
        let access: String
        let accessRank: Int
        let entity: Entity
        let title: String
        let pid: Int
        let group: String
        let started: Double
        let binding: PortBinding
    }

    private var rows: [PortRow] {
        var out: [PortRow] = []
        for vg in model.groups {
            for e in vg.entities where e.isRunning {
                for b in e.ports {
                    let access: String
                    let rank: Int
                    if b.internalOnly { access = "Внутри Docker"; rank = 0 }
                    else { access = b.scope.title + (b.isDocker ? " · Docker" : ""); rank = b.scope.rawValue + 1 }
                    out.append(PortRow(
                        id: "\(e.id)|\(b.id)", port: Int(b.port), portLabel: b.label, proto: b.proto.rawValue,
                        access: access, accessRank: rank, entity: e, title: e.title,
                        pid: Int(e.pid ?? 0), group: vg.group.kind.isMeaningful || vg.entities.count > 1 ? vg.group.title : "",
                        started: e.started?.timeIntervalSince1970 ?? 0, binding: b))
                }
            }
        }
        return out.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        Table(rows, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("Порт", value: \.port) { r in
                HStack(spacing: 5) {
                    Circle()
                        .fill(r.binding.internalOnly ? Palette.internalPort : Palette.scope(r.binding.scope))
                        .frame(width: 7, height: 7)
                    Text(r.portLabel).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    if r.binding.conflict {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 10))
                    }
                }
                .help(PortChip.tooltip(r.binding))
            }
            .width(min: 70, ideal: 90, max: 130)

            TableColumn("Прот.", value: \.proto) { r in Text(r.proto).foregroundStyle(.secondary) }
                .width(min: 40, ideal: 46, max: 60)

            TableColumn("Доступ", value: \.accessRank) { r in Text(r.access).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 150)

            TableColumn("Приложение", value: \.title) { r in
                HStack(spacing: 6) {
                    EntityIcon(icon: r.entity.icon, size: 18)
                    Text(r.title).fontWeight(.medium)
                    if !r.entity.subtitle.isEmpty {
                        Text(r.entity.subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 160, ideal: 280)

            TableColumn("PID", value: \.pid) { r in
                Text(r.pid > 0 ? String(r.pid) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64, max: 90)

            TableColumn("Группа", value: \.group) { r in Text(r.group).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 150)

            TableColumn("Работает", value: \.started) { r in
                Text(r.started > 0 ? Format.age(Date(timeIntervalSince1970: r.started)) : "")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70, max: 100)
        }
        .contextMenu(forSelectionType: PortRow.ID.self) { ids in
            if let id = ids.first, let r = rows.first(where: { $0.id == id }) {
                EntityMenuItems(entity: r.entity)
            }
        } primaryAction: { ids in
            if let id = ids.first, let r = rows.first(where: { $0.id == id }), r.binding.proto == .tcp, !r.binding.internalOnly {
                Monitor.shared.openInBrowser(r.binding.port)
            }
        }
        .onChange(of: tableSelection) { _, new in
            if let new, let r = rows.first(where: { $0.id == new }) { selection = r.entity.id }
        }
    }
}
