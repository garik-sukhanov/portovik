import AppKit
import Observation
import SwiftUI

enum Prefs {
    static let interval = "refreshInterval"
    static let showUDP = "showUDP"
    static let showSystem = "showSystem"
    static let showClients = "showClients"
    static let deepScan = "dockerDeepScan"
    static let linkMemory = "linkMemory"
    static let showMenuBar = "showMenuBar"
    static let viewMode = "viewMode"

    static func register() {
        UserDefaults.standard.register(defaults: [
            interval: 2.0, showUDP: false, showSystem: true, showClients: true,
            deepScan: true, linkMemory: 60.0, showMenuBar: true, viewMode: "list",
        ])
    }
}

struct LogsTarget: Identifiable, Equatable {
    let id: String       // id контейнера
    let title: String
}

/// Источник правды для интерфейса: периодически пересобирает снимок и выполняет действия.
@MainActor @Observable
final class Monitor {
    static let shared = Monitor()

    private(set) var snapshot = Snapshot.empty
    var paused = false
    var busy: [String: String] = [:]
    var logsTarget: LogsTarget?

    @ObservationIgnored private let scanner = Scanner()
    @ObservationIgnored let docker = DockerClient()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var ticking = false
    /// Окно на экране или открыто меню — тогда обновляемся часто; иначе экономим батарею.
    @ObservationIgnored var mainWindowVisible = true {
        didSet { if mainWindowVisible && !oldValue { refreshNow() } }
    }
    @ObservationIgnored var menuOpen = false {
        didSet { if menuOpen && !oldValue { refreshNow() } }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused { await self.tick() }
                let pref = max(1, UserDefaults.standard.double(forKey: Prefs.interval))
                let secs = (self.mainWindowVisible || self.menuOpen) ? pref : max(pref, 10)
                try? await Task.sleep(for: .seconds(secs))
            }
        }
    }

    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let d = UserDefaults.standard
        let opt = ScanOptions(includeUDP: d.bool(forKey: Prefs.showUDP),
                              dockerDeepScan: d.bool(forKey: Prefs.deepScan),
                              linkMemory: d.double(forKey: Prefs.linkMemory),
                              refreshContainerNets: mainWindowVisible)
        snapshot = await scanner.scan(opt)
    }

    func refreshNow() {
        Task { await tick() }
    }

    // MARK: Процессы

    func terminate(_ e: Entity) {
        switch e.kind {
        case .container: containerAction(e, .stop); return
        case .appClients: quitApp(e); return
        case .process: break
        }
        guard let pid = e.pid else { return }
        guard isSameProcess(pid, started: e.started) else {
            inform("«\(e.title)» уже завершился.", nil)
            refreshNow()
            return
        }
        if e.isDockerEngine {
            inform("Это движок Docker",
                   "Он держит порты опубликованных контейнеров. Чтобы освободить порт, остановите нужный контейнер или compose-проект — сам Docker завершать не нужно.")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = e.isSystem ? .critical : .warning
        alert.messageText = "Завершить «\(e.title)»?"
        var lines = ["PID \(pid)" + portsSuffix(e)]
        if let label = e.launchdLabel {
            lines.append("Это служба launchd «\(label)». Если она настроена на автоперезапуск, launchd сразу запустит её снова — тогда выберите «Остановить службу».")
        }
        if e.isSystem {
            lines.append("Это системный процесс macOS. Завершайте его, только если точно знаете зачем.")
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Завершить")
        alert.addButton(withTitle: "Отмена")
        if e.launchdLabel != nil { alert.addButton(withTitle: "Остановить службу") }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Принудительно (kill -9)"
        let response = alert.runModal()
        let force = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: send(pid: pid, entity: e, force: force)
        case .alertThirdButtonReturn: stopService(e)
        default: break
        }
    }

    func terminateGroup(_ g: EntityGroup) {
        let procs = g.entityIDs.compactMap { snapshot.entities[$0] }.filter { $0.kind == .process && !$0.isDockerEngine }
        let containers = g.entityIDs.compactMap { snapshot.entities[$0] }.filter { $0.kind == .container && $0.isRunning }
        guard !procs.isEmpty || !containers.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Остановить всё в «\(g.title)»?"
        var items: [String] = procs.map { "• \($0.title) (PID \($0.pid ?? 0))" }
        items += containers.map { "• контейнер \($0.title)" }
        alert.informativeText = items.joined(separator: "\n")
        alert.addButton(withTitle: "Остановить всё")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for p in procs {
            guard let pid = p.pid, isSameProcess(pid, started: p.started) else { continue }
            send(pid: pid, entity: p, force: false, quiet: true)
        }
        if !containers.isEmpty { runContainers(containers.compactMap(\.containerID), .stop, busyKey: g.id) }
    }

    private func send(pid: pid_t, entity e: Entity, force: Bool, quiet: Bool = false) {
        let sig = force ? SIGKILL : SIGTERM
        if kill(pid, sig) != 0 {
            let err = errno
            switch err {
            case ESRCH: refreshNow()
            case EPERM: adminKill(pid: pid, signal: sig, entity: e)
            default: inform("Не удалось завершить «\(e.title)»", String(cString: strerror(err)))
            }
            return
        }
        busy[e.id] = "Завершается…"
        Task {
            let gone = await waitExit(pid, started: e.started, seconds: force ? 2 : 4)
            busy[e.id] = nil
            if !gone && !force && !quiet {
                let a = NSAlert()
                a.messageText = "«\(e.title)» ещё работает"
                a.informativeText = "Процесс не завершился за 4 секунды. Завершить принудительно? Несохранённые данные этого процесса пропадут."
                a.addButton(withTitle: "Принудительно")
                a.addButton(withTitle: "Отмена")
                if a.runModal() == .alertFirstButtonReturn, isSameProcess(pid, started: e.started) {
                    kill(pid, SIGKILL)
                }
            }
            await tick()
        }
    }

    private func adminKill(pid: pid_t, signal sig: Int32, entity e: Entity) {
        let owner = snapshot.processes[pid]?.user ?? "другому пользователю"
        let alert = NSAlert()
        alert.messageText = "«\(e.title)» принадлежит пользователю \(owner)"
        alert.informativeText = "Обычных прав не хватает. Завершить с правами администратора? macOS спросит пароль."
        alert.addButton(withTitle: "Завершить как администратор")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"kill -\(sig) \(pid)\" with administrator privileges")?
            .executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            inform("Не удалось завершить «\(e.title)»", error[NSAppleScript.errorMessage] as? String)
        }
        refreshNow()
    }

    func stopService(_ e: Entity) {
        guard let label = e.launchdLabel else { return }
        let result = Launchd.bootout(label: label)
        if result.ok {
            var text = "launchd больше не будет её перезапускать до следующего входа в систему."
            if label.hasPrefix("homebrew.mxcl.") {
                let name = label.dropFirst("homebrew.mxcl.".count)
                text += "\n\nЧтобы она не стартовала и после перезагрузки: brew services stop \(name)"
            }
            inform("Служба «\(label)» остановлена", text)
        } else {
            inform("Не удалось остановить службу «\(label)»", result.message)
        }
        refreshNow()
    }

    private func quitApp(_ e: Entity) {
        guard let bundle = e.appBundle else { return }
        let alert = NSAlert()
        alert.messageText = "Завершить приложение «\(e.title)»?"
        alert.informativeText = "Приложение закроется целиком, как по ⌘Q, и отключится от всех серверов."
        alert.addButton(withTitle: "Завершить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let apps = Classifier.bundleID(bundle).map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        if apps.isEmpty {
            for pid in e.pids { kill(pid, SIGTERM) }
        } else {
            apps.forEach { $0.terminate() }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await tick()
        }
    }

    private func isSameProcess(_ pid: pid_t, started: Date?) -> Bool {
        guard let kp = ProcessInspector.kernelProc(pid), !kp.isZombie else { return false }
        guard let started else { return true }
        return abs(kp.started.timeIntervalSince(started)) < 1
    }

    private func waitExit(_ pid: pid_t, started: Date?, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isSameProcess(pid, started: started) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !isSameProcess(pid, started: started)
    }

    private func portsSuffix(_ e: Entity) -> String {
        let ports = e.publicPorts.map { String($0.port) }
        guard !ports.isEmpty else { return "" }
        return ports.count == 1 ? " · освободит порт \(ports[0])" : " · освободит порты \(ports.joined(separator: ", "))"
    }

    // MARK: Docker

    enum ContainerAction {
        case stop, start, restart

        var busyTitle: String {
            switch self {
            case .stop: return "Останавливается…"
            case .start: return "Запускается…"
            case .restart: return "Перезапускается…"
            }
        }
    }

    func containerAction(_ e: Entity, _ action: ContainerAction) {
        guard let cid = e.containerID else { return }
        let name = snapshot.containers[cid]?.name ?? e.title
        if action != .start {
            let alert = NSAlert()
            alert.messageText = action == .stop ? "Остановить контейнер «\(name)»?" : "Перезапустить контейнер «\(name)»?"
            var info = portsSuffix(e).replacingOccurrences(of: " · о", with: "О")
            if info.isEmpty { info = "Контейнер получит сигнал остановки; через 10 секунд Docker остановит его принудительно." }
            alert.informativeText = info
            alert.addButton(withTitle: action == .stop ? "Остановить" : "Перезапустить")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        runContainers([cid], action, busyKey: e.id)
    }

    func composeAction(_ g: EntityGroup, _ action: ContainerAction) {
        let members = g.entityIDs.compactMap { snapshot.entities[$0] }.filter { $0.kind == .container }
        let targets = members.filter { action == .start ? !$0.isRunning : $0.isRunning }.compactMap(\.containerID)
        guard !targets.isEmpty else { return }
        if action != .start {
            let alert = NSAlert()
            let verb = action == .stop ? "Остановить" : "Перезапустить"
            alert.messageText = "\(verb) проект «\(g.title)»?"
            alert.informativeText = "Контейнеров: \(targets.count). Это то же, что docker compose \(action == .stop ? "stop" : "restart")."
            alert.addButton(withTitle: verb)
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        runContainers(targets, action, busyKey: g.id)
    }

    private func runContainers(_ ids: [String], _ action: ContainerAction, busyKey: String) {
        busy[busyKey] = action.busyTitle
        for id in ids { busy["c:\(id)"] = action.busyTitle }
        let client = docker
        Task {
            let errors: [String] = await withTaskGroup(of: String?.self) { group in
                for id in ids {
                    group.addTask {
                        await Task.detached {
                            do {
                                switch action {
                                case .stop: try client.stop(id)
                                case .start: try client.start(id)
                                case .restart: try client.restart(id)
                                }
                                return nil
                            } catch {
                                return error.localizedDescription
                            }
                        }.value
                    }
                }
                var out: [String] = []
                for await e in group { if let e { out.append(e) } }
                return out
            }
            busy[busyKey] = nil
            for id in ids { busy["c:\(id)"] = nil }
            if !errors.isEmpty { inform("Docker вернул ошибку", Array(Set(errors)).joined(separator: "\n")) }
            await tick()
        }
    }

    func showLogs(_ e: Entity) {
        guard let cid = e.containerID else { return }
        logsTarget = LogsTarget(id: cid, title: snapshot.containers[cid]?.name ?? e.title)
    }

    func loadLogs(_ id: String) async -> String {
        let client = docker
        return await Task.detached {
            do { return try client.logs(id) } catch { return "Не удалось получить логи: \(error.localizedDescription)" }
        }.value
    }

    // MARK: Мелочи

    func openInBrowser(_ port: UInt16) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, !path.hasSuffix(".app") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openTerminal(_ dir: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func inform(_ title: String, _ text: String?) {
        let a = NSAlert()
        a.messageText = title
        if let text { a.informativeText = text }
        a.runModal()
    }
}
