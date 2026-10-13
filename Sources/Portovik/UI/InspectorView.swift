import SwiftUI

/// Правая панель: всё, что известно о выбранном приложении, контейнере или группе.
struct InspectorView: View {
    @Binding var selection: String?
    let model: VisibleModel
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let snap = monitor.snapshot
        ScrollView {
            Group {
                if let id = selection, let e = snap.entities[id] {
                    EntityDetail(entity: e, snapshot: snap, selection: $selection)
                } else if let id = selection, let g = snap.group(id) {
                    GroupDetail(group: g, snapshot: snap, selection: $selection)
                } else {
                    Overview(snapshot: snap, model: model)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Приложение / контейнер

private struct EntityDetail: View {
    let entity: Entity
    let snapshot: Snapshot
    @Binding var selection: String?
    @Environment(Monitor.self) private var monitor

    private var proc: ProcInfo? { entity.pid.flatMap { snapshot.processes[$0] } }
    private var container: DockerContainer? { entity.containerID.flatMap { snapshot.containers[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            actions
            if let hint = entity.hint { hintBox(hint) }
            if entity.ports.contains(where: \.conflict) { conflictBox }
            if !entity.ports.isEmpty { portsSection }
            linksSection
            if let c = container { dockerSection(c) }
            if entity.kind == .process { launchSection; processSection }
            if entity.kind == .appClients { clientsSection }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            EntityIcon(icon: entity.icon, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(entity.title).font(.system(size: 17, weight: .bold)).textSelection(.enabled)
                if !entity.subtitle.isEmpty {
                    Text(entity.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(spacing: 5) {
                    ForEach(badges, id: \.0) { b in
                        Text(b.0)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(b.1.opacity(0.15), in: Capsule())
                            .foregroundStyle(b.1)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var badges: [(String, Color)] {
        var out: [(String, Color)] = []
        switch entity.kind {
        case .container:
            out.append((entity.isRunning ? "контейнер" : "остановлен", entity.isRunning ? Palette.docker : .gray))
            if let h = entity.health {
                out.append((h == "healthy" ? "здоров" : h == "unhealthy" ? "нездоров" : "запускается", Palette.health(h)))
            }
        case .appClients:
            out.append(("клиент", .secondary))
        case .process:
            if entity.launchdLabel != nil { out.append(("служба launchd", .purple)) }
            if entity.isSystem { out.append(("macOS", .gray)) }
            if entity.isDockerEngine { out.append(("движок Docker", Palette.docker)) }
            if entity.ports.contains(where: { $0.scope == .any }) { out.append(("виден из сети", Palette.network)) }
        }
        if let b = monitor.busy[entity.id] { out.append((b, .orange)) }
        return out
    }

    @ViewBuilder private var actions: some View {
        let tcp = entity.publicPorts.first { $0.proto == .tcp }
        FlowRow(spacing: 8) {
            switch entity.kind {
            case .process:
                if !entity.isDockerEngine {
                    Button(role: .destructive) { monitor.terminate(entity) } label: {
                        Label("Завершить", systemImage: "xmark.circle")
                    }
                }
                if entity.launchdLabel != nil {
                    Button { monitor.stopService(entity) } label: { Label("Остановить службу", systemImage: "stop.circle") }
                }
            case .appClients:
                Button(role: .destructive) { monitor.terminate(entity) } label: {
                    Label("Завершить приложение", systemImage: "xmark.circle")
                }
            case .container:
                if entity.isRunning {
                    Button { monitor.containerAction(entity, .stop) } label: { Label("Остановить", systemImage: "stop.fill") }
                    Button { monitor.containerAction(entity, .restart) } label: { Label("Перезапустить", systemImage: "arrow.clockwise") }
                } else {
                    Button { monitor.containerAction(entity, .start) } label: { Label("Запустить", systemImage: "play.fill") }
                }
                Button { monitor.showLogs(entity) } label: { Label("Логи", systemImage: "text.alignleft") }
            }
            if entity.isRunning, let tcp {
                Button { monitor.openInBrowser(tcp.port) } label: { Label("Открыть", systemImage: "safari") }
                    .help("Открыть http://localhost:\(tcp.port)")
            }
        }
        .controlSize(.regular)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(monitor.busy[entity.id] != nil)
    }

    private func hintBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb").foregroundStyle(.yellow)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var conflictBox: some View {
        let others = entity.ports.filter(\.conflict).flatMap { b in
            snapshot.entities.values.filter { o in
                o.id != entity.id && o.isRunning && o.ports.contains { $0.port == b.port && $0.proto == b.proto && !$0.internalOnly }
            }.map { "\($0.title) (\(b.port))" }
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("Тот же порт слушает ещё: \(Array(Set(others)).sorted().joined(separator: ", ")). Подключения на localhost могут попадать не туда, куда вы ждёте.")
                .font(.system(size: 12))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var portsSection: some View {
        InfoSection(title: "Порты") {
            ForEach(entity.ports) { b in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle().fill(b.internalOnly ? Palette.internalPort : Palette.scope(b.scope)).frame(width: 8, height: 8)
                        Text(verbatim: b.internalOnly ? String(b.port) : ":" + String(b.port))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        Text(b.proto.rawValue).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        if b.proto == .tcp, !b.internalOnly, entity.isRunning {
                            IconButton(symbol: "safari", help: "Открыть http://localhost:\(b.port)") { monitor.openInBrowser(b.port) }
                            IconButton(symbol: "doc.on.doc", help: "Скопировать localhost:\(b.port)") { monitor.copy("localhost:\(b.port)") }
                        }
                    }
                    Group {
                        if b.internalOnly {
                            Text("Только внутри сети Docker — с Mac напрямую недоступен")
                        } else if let inner = b.innerPort {
                            Text("На Mac \(String(b.port)) → в контейнере \(String(inner)) · \(b.scope.title) (\(b.addresses.joined(separator: ", ")))")
                        } else {
                            Text("\(b.scope.title) · \(b.addresses.joined(separator: ", "))")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                }
            }
        }
    }

    @ViewBuilder private var linksSection: some View {
        let inc = snapshot.incoming(entity.id)
        let out = snapshot.outgoing(entity.id)
        let ext = snapshot.external[entity.id] ?? []
        if !inc.isEmpty || !out.isEmpty || !ext.isEmpty {
            InfoSection(title: "Связи") {
                if !inc.isEmpty {
                    Text("Подключаются сюда").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(inc) { l in linkRow(l, other: l.from, incoming: true) }
                }
                if !out.isEmpty {
                    Text("Подключается к").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, inc.isEmpty ? 0 : 4)
                    ForEach(out) { l in linkRow(l, other: l.to, incoming: false) }
                }
                if !ext.isEmpty {
                    let total = ext.reduce(0) { $0 + $1.count }
                    Text("Внешние соединения: \(total)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, inc.isEmpty && out.isEmpty ? 0 : 4)
                    ForEach(Array(ext.prefix(8).enumerated()), id: \.offset) { _, p in
                        HStack(spacing: 6) {
                            Image(systemName: p.inbound ? "arrow.down.left" : "arrow.up.right")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            Text(p.remote.display).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            if p.inbound { Text(verbatim: "→ :" + String(p.localPort)).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer()
                            if p.count > 1 { Text("×\(p.count)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                    }
                    if ext.count > 8 {
                        Text("и ещё \(ext.count - 8)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func linkRow(_ l: Link, other: String, incoming: Bool) -> some View {
        let o = snapshot.entities[other]
        return Button { selection = other } label: {
            HStack(spacing: 7) {
                Capsule().fill(Palette.link(l.kind).opacity(l.live ? 1 : 0.4)).frame(width: 3, height: 18)
                if let o { EntityIcon(icon: o.icon, size: 18) }
                Text(o?.title ?? "?").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(verbatim: ":" + String(l.port)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if !l.live {
                    Text("недавно").font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    if l.bytesPerSec >= 1 { Text(Format.rate(l.bytesPerSec)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary) }
                    if l.connections > 1 { Text("×\(l.connections)").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(incoming ? "\(o?.title ?? "") подключается к порту \(l.port)" : "Подключение к порту \(l.port)")
    }

    private func dockerSection(_ c: DockerContainer) -> some View {
        InfoSection(title: "Docker") {
            InfoRow(label: "Контейнер", value: c.name)
            InfoRow(label: "ID", value: c.shortID, mono: true)
            InfoRow(label: "Образ", value: c.image)
            InfoRow(label: "Состояние", value: c.status.isEmpty ? c.state : c.status)
            if let p = c.composeProject {
                InfoRow(label: "Compose", value: "проект \(p)" + (c.composeService.map { ", сервис \($0)" } ?? ""))
            }
            if let dir = c.composeDir {
                InfoRow(label: "Папка", value: Classifier.abbreviate(dir)) {
                    IconButton(symbol: "folder", help: "Открыть в Finder") { monitor.reveal(dir) }
                    IconButton(symbol: "terminal", help: "Терминал в этой папке") { monitor.openTerminal(dir) }
                }
            }
            if let files = c.composeFiles {
                InfoRow(label: "Файл", value: files.split(separator: ",").map { Classifier.abbreviate(String($0)) }.joined(separator: "\n"))
            }
            ForEach(c.networks, id: \.name) { n in
                InfoRow(label: "Сеть", value: "\(n.name)\(n.ip.isEmpty ? "" : " · \(n.ip)")")
            }
            if !c.command.isEmpty { InfoRow(label: "Команда", value: c.command, mono: true) }
            InfoRow(label: "Создан", value: Format.started(c.created))
        }
    }

    @ViewBuilder private var launchSection: some View {
        if let p = proc {
            let chain = snapshot.ancestors(of: p.pid).reversed()
            InfoSection(title: "Кто запустил") {
                LaunchChain(chain: Array(chain), process: p, label: entity.launchdLabel, selection: $selection)
                InfoRow(label: "Запущен", value: Format.started(p.started))
                InfoRow(label: "Пользователь", value: p.user + (p.uid == 0 ? " (администратор)" : ""))
                if let label = entity.launchdLabel { InfoRow(label: "Служба", value: label, mono: true) }
            }
        }
    }

    @ViewBuilder private var processSection: some View {
        if let p = proc {
            InfoSection(title: "Процесс") {
                InfoRow(label: "PID", value: String(p.pid), mono: true) {
                    IconButton(symbol: "doc.on.doc", help: "Скопировать PID") { monitor.copy(String(p.pid)) }
                }
                if let cpu = entity.cpu { InfoRow(label: "Процессор", value: Format.cpu(cpu)) }
                if let mem = entity.memory { InfoRow(label: "Память", value: Format.bytes(mem)) }
                if let dir = p.cwd {
                    InfoRow(label: "Рабочая папка", value: Classifier.abbreviate(dir)) {
                        IconButton(symbol: "folder", help: "Открыть в Finder") { monitor.reveal(dir) }
                        IconButton(symbol: "terminal", help: "Терминал в этой папке") { monitor.openTerminal(dir) }
                    }
                }
                if let path = p.path {
                    InfoRow(label: "Программа", value: Classifier.abbreviate(path), mono: true) {
                        IconButton(symbol: "magnifyingglass", help: "Показать в Finder") { monitor.reveal(path) }
                    }
                }
                if let cmd = p.commandLine {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Команда").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Spacer()
                            IconButton(symbol: "doc.on.doc", help: "Скопировать команду") { monitor.copy(cmd) }
                        }
                        Text(cmd)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                } else if p.uid != ProcessInspector.myUID {
                    Text("Процесс другого пользователя (\(p.user)) — команду и папку macOS без прав администратора не показывает.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clientsSection: some View {
        InfoSection(title: "Процессы") {
            ForEach(entity.pids, id: \.self) { pid in
                let p = snapshot.processes[pid]
                InfoRow(label: "PID \(pid)", value: p?.executableName ?? "?")
            }
            if let mem = entity.memory, mem > 0 { InfoRow(label: "Память", value: Format.bytes(mem)) }
        }
    }
}

/// «Терминал › zsh › npm › node» — откуда взялся процесс.
private struct LaunchChain: View {
    let chain: [ProcInfo]
    let process: ProcInfo
    let label: String?
    @Binding var selection: String?

    private struct Step: Identifiable {
        let id: Int
        let name: String
        let icon: IconSource?
    }

    private var steps: [Step] {
        var out: [Step] = []
        var lastBundle: String?
        for p in chain {
            if p.comm == "login" { continue }
            if let b = p.appBundle {
                if b == lastBundle { continue }
                lastBundle = b
                out.append(Step(id: Int(p.pid), name: Classifier.appName(b), icon: .app(b)))
            } else {
                lastBundle = nil
                out.append(Step(id: Int(p.pid), name: stepName(p), icon: nil))
            }
        }
        if out.isEmpty {
            out.append(Step(id: 1, name: process.ppid == 1 ? "launchd" : "PID \(process.ppid)", icon: .symbol("gearshape.fill", -1)))
        }
        return out
    }

    private func stepName(_ p: ProcInfo) -> String {
        if let a0 = p.args?.first, !a0.isEmpty {
            let name = (a0 as NSString).lastPathComponent
            if name.hasPrefix("-") { return String(name.dropFirst()) }
            if name != p.executableName, name.contains(" ") { return name }
            return name
        }
        return p.executableName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowRow(spacing: 4) {
                ForEach(steps) { s in
                    HStack(spacing: 4) {
                        if let icon = s.icon { EntityIcon(icon: icon, size: 15) }
                        Text(s.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                Text(process.executableName)
                    .font(.system(size: 11.5, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let names = chain.map { $0.comm.lowercased() }
        let bundles = chain.compactMap(\.appBundle)
        if let label, label.hasPrefix("homebrew.mxcl.") {
            return "Служба Homebrew: запущена через brew services и стартует сама при входе в систему."
        }
        if label != nil { return "Запущен launchd как служба — стартует автоматически." }
        if names.contains(where: { Classifier.shells.contains($0) || Classifier.shells.contains("-" + $0) }) {
            if let b = bundles.last { return "Запущен из командной строки в «\(Classifier.appName(b))»." }
            return "Запущен из командной строки."
        }
        if let b = bundles.last { return "Запущен приложением «\(Classifier.appName(b))»." }
        if process.ppid == 1, let b = process.appBundle, let path = process.path, Classifier.isMainExecutable(path, of: b) {
            return "Обычное приложение — открыто из Dock, Finder или Spotlight."
        }
        if process.ppid == 1 { return "Работает сам по себе: родитель завершился или это фоновая служба." }
        return ""
    }
}

/// Перенос элементов по строкам, как текст.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += lineH + spacing; lineH = 0 }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
            maxW = max(maxW, x)
        }
        return CGSize(width: min(maxW, width), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y + (lineH > 0 ? 0 : 0)), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}

// MARK: - Группа

private struct GroupDetail: View {
    let group: EntityGroup
    let snapshot: Snapshot
    @Binding var selection: String?
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let members = group.entityIDs.compactMap { snapshot.entities[$0] }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                EntityIcon(icon: group.icon, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title).font(.system(size: 17, weight: .bold))
                    Text(kindTitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            FlowRow(spacing: 8) {
                let containers = members.filter { $0.kind == .container }
                if containers.contains(where: \.isRunning) {
                    Button { monitor.composeAction(group, .stop) } label: { Label("Остановить", systemImage: "stop.fill") }
                    Button { monitor.composeAction(group, .restart) } label: { Label("Перезапустить", systemImage: "arrow.clockwise") }
                }
                if containers.contains(where: { !$0.isRunning }) {
                    Button { monitor.composeAction(group, .start) } label: { Label("Запустить", systemImage: "play.fill") }
                }
                if containers.isEmpty, members.contains(where: { $0.kind == .process }), group.kind != .system {
                    Button(role: .destructive) { monitor.terminateGroup(group) } label: {
                        Label("Завершить всё", systemImage: "xmark.circle")
                    }
                }
            }
            .disabled(monitor.busy[group.id] != nil)

            if let dir = group.directory {
                InfoSection(title: "Папка") {
                    InfoRow(label: "Путь", value: Classifier.abbreviate(dir)) {
                        IconButton(symbol: "folder", help: "Открыть в Finder") { monitor.reveal(dir) }
                        IconButton(symbol: "terminal", help: "Терминал в этой папке") { monitor.openTerminal(dir) }
                    }
                    if let files = group.composeFiles {
                        InfoRow(label: "Compose", value: files.split(separator: ",").map { Classifier.abbreviate(String($0)) }.joined(separator: "\n"))
                    }
                }
            }

            InfoSection(title: "Состав") {
                ForEach(members) { e in
                    Button { selection = e.id } label: {
                        HStack(spacing: 8) {
                            EntityIcon(icon: e.icon, size: 22).opacity(e.isRunning ? 1 : 0.4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 12, weight: .semibold))
                                if !e.subtitle.isEmpty {
                                    Text(e.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            ForEach(e.ports.prefix(3)) { PortChip(binding: $0, compact: true) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var kindTitle: String {
        switch group.kind {
        case .compose: return "Docker Compose" + (group.subtitle.map { " · \($0)" } ?? "")
        case .stoppedCompose: return "Docker Compose — всё остановлено"
        case .project: return "Проект · " + (group.subtitle ?? "")
        case .app: return "Приложение"
        case .docker: return "Контейнеры без compose"
        case .system: return "Системные службы macOS"
        case .service: return "Служба"
        case .single: return "Процесс"
        }
    }
}

// MARK: - Ничего не выбрано

private struct Overview: View {
    let snapshot: Snapshot
    let model: VisibleModel

    var body: some View {
        let containers = snapshot.containers.values.filter(\.isRunning).count
        VStack(alignment: .leading, spacing: 16) {
            Text("Сводка").font(.system(size: 17, weight: .bold))
            HStack(spacing: 10) {
                tile("\(model.portCount)", "портов")
                tile("\(model.appCount)", "слушают")
                tile("\(containers)", "контейнеров")
            }
            InfoSection(title: "Docker") {
                Text(snapshot.docker.title).font(.system(size: 12))
            }
            InfoSection(title: "Подсказки") {
                tip("magnifyingglass", "Введите номер порта в поиск — увидите, кто его занял, или что он свободен.")
                tip("cursorarrow.click.2", "Щелчок по строке показывает, кто запустил процесс, его команду, папку и связи.")
                tip("contextualmenu.and.cursorarrow", "Правый щелчок — завершить, открыть в браузере, перейти в папку.")
                tip("point.3.connected.trianglepath.dotted", "На схеме карточки можно перетаскивать, а масштаб менять щипком.")
            }
            InfoSection(title: "Линии на схеме") {
                lineRow(.local, "Mac → Mac")
                lineRow(.toContainer, "Mac → контейнер (через опубликованный порт)")
                lineRow(.betweenContainers, "контейнер → контейнер")
                lineRow(.fromContainer, "контейнер → Mac (host.docker.internal)")
                Text("Бегущий пунктир — прямо сейчас идёт обмен данными, бледный — связь была недавно.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            InfoSection(title: "Цвет точки у порта") {
                legendRow(Palette.loopback, "Только этот Mac (127.0.0.1)")
                legendRow(Palette.network, "Виден из сети — к нему могут подключиться другие устройства")
                legendRow(Palette.specific, "Привязан к конкретному адресу")
                legendRow(Palette.internalPort, "Порт внутри Docker, на Mac не опубликован")
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12))
        }
    }

    private func lineRow(_ k: LinkKind, _ text: String) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(Palette.link(k)).frame(width: 20, height: 3)
            Text(text).font(.system(size: 12))
        }
    }

    private func legendRow(_ c: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(c).frame(width: 8, height: 8).padding(.top, 4)
            Text(text).font(.system(size: 12))
        }
    }
}
