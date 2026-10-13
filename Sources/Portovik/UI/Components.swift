import AppKit
import SwiftUI

enum Palette {
    static let loopback = Color(red: 0.20, green: 0.68, blue: 0.40)
    static let network = Color(red: 0.95, green: 0.55, blue: 0.10)
    static let specific = Color(red: 0.62, green: 0.40, blue: 0.86)
    static let docker = Color(red: 0.13, green: 0.55, blue: 0.93)
    static let internalPort = Color.gray

    static func scope(_ s: BindScope) -> Color {
        switch s {
        case .loopback: return loopback
        case .specific: return specific
        case .any: return network
        }
    }

    static func link(_ k: LinkKind) -> Color {
        switch k {
        case .local: return Color(red: 0.36, green: 0.42, blue: 0.95)
        case .toContainer: return docker
        case .betweenContainers: return Color(red: 0.10, green: 0.66, blue: 0.62)
        case .fromContainer: return Color(red: 0.70, green: 0.36, blue: 0.86)
        }
    }

    static func health(_ h: String) -> Color {
        switch h {
        case "healthy": return loopback
        case "unhealthy": return .red
        default: return .yellow
        }
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

struct EntityIcon: View {
    let icon: IconSource
    var size: CGFloat = 28

    var body: some View {
        switch icon {
        case .app(let path):
            Image(nsImage: IconCache.shared.icon(for: path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .badge(let text, let hue):
            tile(hue) {
                Text(text)
                    .font(.system(size: size * (text.count > 2 ? 0.33 : 0.42), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
        case .symbol(let name, let hue):
            tile(hue) {
                Image(systemName: name)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func tile<C: View>(_ hue: Double, @ViewBuilder _ content: () -> C) -> some View {
        let top = hue < 0 ? Color(white: 0.62) : Color(hue: hue, saturation: 0.55, brightness: 0.88)
        let bottom = hue < 0 ? Color(white: 0.42) : Color(hue: hue, saturation: 0.78, brightness: 0.64)
        return RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            .overlay(content())
            .frame(width: size * 0.86, height: size * 0.86)
            .frame(width: size, height: size)
    }
}

struct PortChip: View {
    let binding: PortBinding
    var compact = false

    private var dot: Color { binding.internalOnly ? Palette.internalPort : Palette.scope(binding.scope) }
    private var tint: Color { binding.internalOnly ? Palette.internalPort : binding.isDocker ? Palette.docker : dot }

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(dot).frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(binding.label)
                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(binding.internalOnly ? .secondary : .primary)
            if binding.proto == .udp {
                Text("udp").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            if binding.conflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 1.5 : 2.5)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(
            Capsule().strokeBorder(binding.conflict ? Color.red.opacity(0.8) : tint.opacity(0.35),
                                   style: StrokeStyle(lineWidth: binding.conflict ? 1.3 : 0.8,
                                                      dash: binding.internalOnly ? [3, 2] : []))
        )
        .fixedSize()
        .help(Self.tooltip(binding))
    }

    static func tooltip(_ b: PortBinding) -> String {
        var s: String
        if b.internalOnly {
            s = "\(b.proto.rawValue) \(b.port) — только внутри сети Docker, на Mac не опубликован"
        } else if let inner = b.innerPort {
            s = "\(b.proto.rawValue) \(b.port) на Mac → \(inner) в контейнере · \(b.scope.title)"
        } else {
            s = "\(b.proto.rawValue) \(b.port) · \(b.scope.title)"
        }
        if !b.addresses.isEmpty { s += " (\(b.addresses.joined(separator: ", ")))" }
        if b.conflict { s += "\n⚠︎ Этот порт слушает ещё кто-то — соединения могут уходить не туда" }
        return s
    }
}

struct HealthDot: View {
    let health: String

    var body: some View {
        Circle()
            .fill(Palette.health(health))
            .frame(width: 7, height: 7)
            .help(health == "healthy" ? "healthcheck: здоров" : health == "unhealthy" ? "healthcheck: проблемы" : "healthcheck: запускается")
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

struct InfoRow<Trailing: View>: View {
    let label: String
    let value: String
    var mono = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

extension InfoRow where Trailing == EmptyView {
    init(label: String, value: String, mono: Bool = false) {
        self.init(label: label, value: value, mono: mono) { EmptyView() }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Пункты меню для карточки — одинаковые в списке, таблице и на схеме.
struct EntityMenuItems: View {
    let entity: Entity
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let snap = monitor.snapshot
        if entity.isRunning, let p = entity.publicPorts.first(where: { $0.proto == .tcp }) {
            Button("Открыть localhost:\(p.port) в браузере") { monitor.openInBrowser(p.port) }
        }
        switch entity.kind {
        case .process:
            Button(entity.isDockerEngine ? "Это движок Docker…" : "Завершить…") { monitor.terminate(entity) }
            if entity.launchdLabel != nil {
                Button("Остановить службу launchd") { monitor.stopService(entity) }
            }
        case .appClients:
            Button("Завершить приложение…") { monitor.terminate(entity) }
        case .container:
            if entity.isRunning {
                Button("Остановить контейнер…") { monitor.containerAction(entity, .stop) }
                Button("Перезапустить контейнер…") { monitor.containerAction(entity, .restart) }
            } else {
                Button("Запустить контейнер") { monitor.containerAction(entity, .start) }
            }
            Button("Логи контейнера") { monitor.showLogs(entity) }
        }
        Divider()
        if let dir = entity.projectDir {
            Button("Открыть папку проекта") { monitor.reveal(dir) }
            Button("Терминал в папке проекта") { monitor.openTerminal(dir) }
        }
        if let pid = entity.pid, let path = snap.processes[pid]?.path {
            Button("Показать программу в Finder") { monitor.reveal(path) }
        }
        if let pid = entity.pid {
            Button("Скопировать PID \(pid)") { monitor.copy(String(pid)) }
            if let cmd = snap.processes[pid]?.commandLine {
                Button("Скопировать команду запуска") { monitor.copy(cmd) }
            }
        }
        if let cid = entity.containerID, let c = snap.containers[cid] {
            Button("Скопировать имя контейнера") { monitor.copy(c.name) }
        }
    }
}

struct GroupMenuItems: View {
    let group: EntityGroup
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let members = group.entityIDs.compactMap { monitor.snapshot.entities[$0] }
        let containers = members.filter { $0.kind == .container }
        if !containers.isEmpty {
            if containers.contains(where: \.isRunning) {
                Button("Остановить проект…") { monitor.composeAction(group, .stop) }
                Button("Перезапустить проект…") { monitor.composeAction(group, .restart) }
            }
            if containers.contains(where: { !$0.isRunning }) {
                Button("Запустить остановленные контейнеры") { monitor.composeAction(group, .start) }
            }
        }
        if members.contains(where: { $0.kind == .process && !$0.isDockerEngine }) && group.kind != .system {
            Button(containers.isEmpty ? "Завершить все процессы…" : "Остановить всё (процессы и контейнеры)…") {
                monitor.terminateGroup(group)
            }
        }
        if let dir = group.directory {
            Divider()
            Button("Открыть папку") { monitor.reveal(dir) }
            Button("Терминал в папке") { monitor.openTerminal(dir) }
        }
    }
}

/// Короткая сводка связей: «→ db :5432 · ← Chrome, Telegram».
struct LinkSummary: View {
    let entity: Entity
    let snapshot: Snapshot

    var body: some View {
        let out = snapshot.outgoing(entity.id).filter(\.live)
        let inc = snapshot.incoming(entity.id).filter(\.live)
        HStack(spacing: 8) {
            if !out.isEmpty {
                Label {
                    Text(summary(out.map { "\(name($0.to)) :\($0.port)" }))
                } icon: {
                    Image(systemName: "arrow.right")
                }
            }
            if !inc.isEmpty {
                Label {
                    Text(summary(Array(Set(inc.map { name($0.from) })).sorted()))
                } icon: {
                    Image(systemName: "arrow.left")
                }
            }
        }
        .labelStyle(CompactLabel())
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func name(_ id: String) -> String { snapshot.entities[id]?.title ?? "?" }

    private func summary(_ items: [String]) -> String {
        let uniq = items.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if uniq.count <= 2 { return uniq.joined(separator: ", ") }
        return uniq.prefix(2).joined(separator: ", ") + " +\(uniq.count - 2)"
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}
