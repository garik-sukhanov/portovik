import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case list, ports, graph
    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "Список"
        case .ports: return "Порты"
        case .graph: return "Схема"
        }
    }

    var symbol: String {
        switch self {
        case .list: return "list.bullet.rectangle"
        case .ports: return "tablecells"
        case .graph: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct MainView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Prefs.viewMode) private var mode: ViewMode = .list
    @AppStorage(Prefs.showSystem) private var showSystem = true
    @AppStorage(Prefs.showClients) private var showClients = true
    @AppStorage(Prefs.showUDP) private var showUDP = false
    @State private var search = ""
    @State private var selection: String?
    @State private var showInspector = true

    var body: some View {
        @Bindable var monitor = monitor
        let snap = monitor.snapshot
        let model = VisibleModel.build(snap, .init(
            search: search, showSystem: showSystem,
            showClients: mode == .graph && showClients,
            includeStopped: mode == .list,
            includeNeighbors: mode == .graph))

        content(model, snap)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 520, minHeight: 360)
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar(model, snap) }
            .searchable(text: $search, placement: .toolbar, prompt: "Порт, приложение, проект")
            .toolbar { toolbar }
            .navigationTitle("Портовик")
            .inspector(isPresented: $showInspector) {
                InspectorView(selection: $selection, model: model)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
            .sheet(item: $monitor.logsTarget) { target in
                LogsView(target: target)
            }
            .background(WindowVisibilityReader(visible: Binding(
                get: { monitor.mainWindowVisible },
                set: { monitor.mainWindowVisible = $0 })))
            .onChange(of: showUDP) { monitor.refreshNow() }
            .onChange(of: selection) { _, new in
                if new != nil, !showInspector { showInspector = true }
            }
    }

    @ViewBuilder private func content(_ model: VisibleModel, _ snap: Snapshot) -> some View {
        if !snap.scanned {
            ProgressView("Смотрю, кто чем занят…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch mode {
            case .list:
                if model.groups.isEmpty { emptyState(model) }
                else { ListModeView(model: model, snapshot: snap, selection: $selection) }
            case .ports:
                if model.groups.isEmpty { emptyState(model) }
                else { PortsTableView(model: model, snapshot: snap, selection: $selection) }
            case .graph:
                GraphView(model: model, snapshot: snap, selection: $selection)
            }
        }
    }

    @ViewBuilder private func emptyState(_ model: VisibleModel) -> some View {
        if let free = model.freePort {
            ContentUnavailableView {
                Label("Порт \(String(free)) свободен", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.loopback)
            } description: {
                Text("Его сейчас никто не слушает — можно занимать.")
            }
        } else if !model.query.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView("Никто не слушает порты", systemImage: "network.slash")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Вид", selection: $mode) {
                ForEach(ViewMode.allCases) { m in
                    Label(m.title, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .help("Список, таблица портов или схема связей")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Toggle("Службы macOS", isOn: $showSystem)
                Toggle("UDP-порты", isOn: $showUDP)
                Toggle("Клиенты на схеме", isOn: $showClients)
            } label: {
                Label("Фильтры", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Что показывать")

            Button {
                monitor.paused.toggle()
            } label: {
                Label(monitor.paused ? "Продолжить" : "Пауза", systemImage: monitor.paused ? "play.fill" : "pause.fill")
            }
            .help(monitor.paused ? "Продолжить обновление" : "Заморозить картинку")

            Button {
                monitor.refreshNow()
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Обновить сейчас (⌘R)")

            Button {
                showInspector.toggle()
            } label: {
                Label("Подробности", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Показать или скрыть подробности (⌥⌘I)")
        }
    }

    private func statusBar(_ model: VisibleModel, _ snap: Snapshot) -> some View {
        HStack(spacing: 14) {
            if let free = model.freePort, !model.groups.isEmpty {
                Label("Порт \(String(free)) свободен", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.loopback)
            }
            Text("\(model.portCount) \(plural(model.portCount, "порт", "порта", "портов"))")
            Text("\(model.appCount) \(plural(model.appCount, "слушатель", "слушателя", "слушателей"))")
            HStack(spacing: 4) {
                Circle()
                    .fill(snap.docker.isRunning ? Palette.loopback : Color.gray)
                    .frame(width: 6, height: 6)
                Text(snap.docker.title)
            }
            Spacer()
            if monitor.paused {
                Label("Пауза", systemImage: "pause.fill").foregroundStyle(.orange)
            } else if snap.scanned {
                Text("обновлено \(snap.date.formatted(date: .omitted, time: .standard))")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}
