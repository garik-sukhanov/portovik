import Foundation

struct ScanOptions: Sendable {
    var includeUDP = false
    var dockerDeepScan = true
    var linkMemory: TimeInterval = 60
    /// Обновлять ли сведения изнутри контейнеров (docker exec) — только пока на них смотрят.
    var refreshContainerNets = true
}

/// Собирает снимок: кто слушает какие порты, кто с кем соединён, как всё сгруппировано.
actor Scanner {
    private enum Owner: Hashable {
        case pid(pid_t)
        case container(String)

        var isContainer: Bool { if case .container = self { return true } else { return false } }
    }

    private struct StaticInfo {
        var path: String?
        var args: [String]?
        var bundle: String?
    }

    private struct Remembered {
        var link: Link
        var seen: Date
        var clients: [pid_t: Date]   // pid → время запуска (чтобы не спутать с новым процессом с тем же PID)
    }

    private struct LKey: Hashable { let pid: pid_t; let proto: NetProto; let port: UInt16 }
    private struct PubKey: Hashable { let proto: NetProto; let port: UInt16 }
    private struct RawLink { var client: Owner; var server: Owner; var port: UInt16; var delta: UInt64 }

    private let docker = DockerClient()
    private var statics: [String: StaticInfo] = [:]
    private var cpuPrev: [pid_t: (cpu: UInt64, wall: UInt64)] = [:]
    private var bytesPrev: [String: UInt64] = [:]
    private var lastScanAt: Date?
    private var launchd: [pid_t: String] = [:]
    private var launchdAt = Date.distantPast
    private var localIPs: Set<String> = []
    private var localIPsAt = Date.distantPast
    private var dockerVersion = ""
    private var dockerVersionAt = Date.distantPast
    private var containerNets: [String: ContainerNet] = [:]
    private var netScanAt = Date.distantPast
    private var netScanRunning = false
    private var netScanSkip: [String: Date] = [:]
    private var memory: [String: Remembered] = [:]

    // Docker Desktop, OrbStack: адреса, под которыми Mac виден из контейнеров (host.docker.internal).
    private static let hostGateways: Set<String> = ["192.168.65.254", "192.168.65.2", "0.250.250.254", "198.19.248.254"]

    func scan(_ opt: ScanOptions) -> Snapshot {
        let now = Date()
        let wallNow = DispatchTime.now().uptimeNanoseconds
        let kprocs = ProcessInspector.allProcesses()
        let me = ProcessInspector.myUID

        // 1. Сокеты своих процессов — через libproc, точно и с полными адресами.
        var sockets: [SocketRecord] = []
        var inspected = Set<pid_t>()
        var soOwners: [UInt64: [pid_t]] = [:]
        var soRecord: [UInt64: SocketRecord] = [:]
        for (pid, kp) in kprocs where kp.uid == me && pid > 0 {
            guard let list = ProcessInspector.sockets(pid: pid, includeUDP: opt.includeUDP) else { continue }
            inspected.insert(pid)
            for (rec, so) in list {
                soOwners[so, default: []].append(pid)
                if soRecord[so] == nil { soRecord[so] = rec }
            }
        }
        // Унаследованный сокет (nginx master + workers) отдаём самому старшему процессу.
        for (so, pids) in soOwners {
            guard var rec = soRecord[so] else { continue }
            if pids.count > 1 {
                let set = Set(pids)
                rec.pid = pids.filter { !set.contains(kprocs[$0]?.ppid ?? 0) }.min() ?? pids.min()!
            }
            sockets.append(rec)
        }

        // 2. netstat — сокеты чужих процессов (root и др.) и счётчики байт.
        var bytes: [String: UInt64] = [:]
        if let ns = Netstat.read(includeUDP: opt.includeUDP) {
            for r in ns {
                if let rem = r.remote, let rx = r.rx, let tx = r.tx {
                    bytes[Self.byteKey(r.proto, r.local.port, rem.port)] = rx &+ tx
                }
                if !inspected.contains(r.pid), kprocs[r.pid] != nil { sockets.append(r) }
            }
        }

        // 3. Docker.
        var containers: [DockerContainer] = []
        var dockerState: DockerState
        do {
            containers = try docker.containers()
            if dockerVersion.isEmpty || now.timeIntervalSince(dockerVersionAt) > 300 {
                dockerVersion = (try? docker.version()) ?? ""
                dockerVersionAt = now
            }
            dockerState = .running(version: dockerVersion)
        } catch DockerClient.Failure.noSocket {
            dockerState = DockerClient.isInstalled() ? .notRunning : .notFound
        } catch DockerClient.Failure.connect {
            dockerState = .notRunning
        } catch {
            dockerState = .failed(error.localizedDescription)
        }
        if !dockerState.isRunning { dockerVersion = "" }
        let running = containers.filter(\.isRunning)
        var containerByID: [String: DockerContainer] = [:]
        for c in containers { containerByID[c.id] = c }
        var published: [PubKey: String] = [:]
        for c in running {
            for p in c.ports { if let pub = p.publicPort { published[PubKey(proto: p.proto, port: pub)] = c.id } }
        }
        let nets = containerNets.filter { containerByID[$0.key]?.isRunning == true }

        if now.timeIntervalSince(launchdAt) > 15 { launchd = Launchd.userJobs(); launchdAt = now }
        if now.timeIntervalSince(localIPsAt) > 15 { localIPs = ProcessInspector.localAddresses(); localIPsAt = now }
        let localSet = localIPs

        // 4. Слушающие порты.
        var listenAddrs: [LKey: [String]] = [:]
        for s in sockets where s.isListener {
            let k = LKey(pid: s.pid, proto: s.proto, port: s.local.port)
            if !(listenAddrs[k]?.contains(s.local.address) ?? false) { listenAddrs[k, default: []].append(s.local.address) }
        }
        var dockerEnginePIDs = Set<pid_t>()
        for pid in Set(listenAddrs.keys.map(\.pid)) {
            guard let kp = kprocs[pid] else { continue }
            let st = staticInfo(pid, kp)
            let exe = st.path.map { ($0 as NSString).lastPathComponent } ?? kp.comm
            if Classifier.isDockerEngine(exe: exe, bundle: st.bundle) { dockerEnginePIDs.insert(pid) }
        }

        var procPorts: [pid_t: [PortBinding]] = [:]
        var tcpListeners: [UInt16: [(owner: Owner, addrs: [String])]] = [:]
        for (k, addrs) in listenAddrs {
            // Порт опубликованного контейнера держит движок Docker — отдаём его контейнеру.
            if let cid = published[PubKey(proto: k.proto, port: k.port)], dockerEnginePIDs.contains(k.pid) {
                if k.proto == .tcp { tcpListeners[k.port, default: []].append((.container(cid), addrs)) }
                continue
            }
            let scope = addrs.map(BindScope.init(address:)).max() ?? .any
            procPorts[k.pid, default: []].append(
                PortBinding(proto: k.proto, port: k.port, addresses: addrs.sorted(), scope: scope))
            if k.proto == .tcp { tcpListeners[k.port, default: []].append((.pid(k.pid), addrs)) }
        }
        for (k, cid) in published where k.proto == .tcp && tcpListeners[k.port] == nil {
            tcpListeners[k.port] = [(.container(cid), ["*"])]
        }

        // 5. Соединения на Mac.
        var rawLinks: [RawLink] = []
        var externalRaw: [Owner: [String: ExternalPeer]] = [:]
        var newBytes: [String: UInt64] = [:]
        func addExternal(_ owner: Owner, _ rem: NetEndpoint, inbound: Bool, localPort: UInt16) {
            let key = "\(rem.display)|\(inbound)"
            var peer = externalRaw[owner]?[key] ?? ExternalPeer(remote: rem, inbound: inbound, localPort: localPort, count: 0)
            peer.count += 1
            externalRaw[owner, default: [:]][key] = peer
        }

        for s in sockets where s.proto == .tcp && s.state == .established {
            guard let rem = s.remote else { continue }
            let key = Self.byteKey(.tcp, s.local.port, rem.port)
            var delta: UInt64 = 0
            if let total = bytes[key] {
                newBytes[key] = total
                if let prev = bytesPrev[key] { delta = total >= prev ? total - prev : total }
                else if lastScanAt != nil { delta = total }
            }
            let serverSide = listenAddrs[LKey(pid: s.pid, proto: .tcp, port: s.local.port)] != nil
            if Address.isLoopback(rem.address) || localSet.contains(rem.address) {
                if serverSide { continue }
                guard let cands = tcpListeners[rem.port], !cands.isEmpty else { continue }
                let target = cands.first { c in
                    c.addrs.contains { a in
                        Address.isAny(a) || a == rem.address || (Address.isLoopback(a) && Address.isLoopback(rem.address))
                    }
                } ?? cands[0]
                if case .pid(let p) = target.owner, p == s.pid { continue }
                rawLinks.append(RawLink(client: .pid(s.pid), server: target.owner, port: rem.port, delta: delta))
            } else {
                addExternal(.pid(s.pid), rem, inbound: serverSide, localPort: s.local.port)
            }
        }

        // 6. Соединения изнутри контейнеров.
        var ipToContainer: [String: String] = [:]
        var gateways = Self.hostGateways
        for c in running {
            for n in c.networks {
                if !n.ip.isEmpty { ipToContainer[n.ip] = c.id }
                if !n.gateway.isEmpty { gateways.insert(n.gateway) }
            }
        }
        var containerTargets = Set<String>()
        for (cid, net) in nets {
            for rem in net.outbound {
                if let target = ipToContainer[rem.address] {
                    if target != cid {
                        rawLinks.append(RawLink(client: .container(cid), server: .container(target), port: rem.port, delta: 0))
                    }
                } else if gateways.contains(rem.address) || localSet.contains(rem.address) {
                    if let t = tcpListeners[rem.port]?.first {
                        rawLinks.append(RawLink(client: .container(cid), server: t.owner, port: rem.port, delta: 0))
                        containerTargets.insert("\(t.owner)|\(rem.port)")
                    }
                } else {
                    addExternal(.container(cid), rem, inbound: false, localPort: 0)
                }
            }
        }
        // Запросы контейнеров к Mac на стороне Mac делает движок Docker. Если заглядываем внутрь
        // контейнеров, настоящий источник известен — дубль от имени Docker убираем.
        let engineClientsKnown = opt.dockerDeepScan && dockerState.isRunning
        rawLinks.removeAll { l in
            guard case .pid(let p) = l.client else { return false }
            let engine = dockerEnginePIDs.contains(p) || kprocs[p].map {
                Classifier.isDockerEngine(exe: staticInfo(p, $0).path.map { ($0 as NSString).lastPathComponent } ?? $0.comm,
                                          bundle: staticInfo(p, $0).bundle)
            } ?? false
            guard engine else { return false }
            return engineClientsKnown || containerTargets.contains("\(l.server)|\(l.port)")
        }

        // 7. Какие процессы показывать: всех, кто слушает, плюс клиентов (в том числе недавних).
        var clientPIDs = Set<pid_t>()
        for l in rawLinks { if case .pid(let p) = l.client { clientPIDs.insert(p) } }
        for m in memory.values where now.timeIntervalSince(m.seen) < opt.linkMemory {
            for (p, start) in m.clients where kprocs[p]?.started == start { clientPIDs.insert(p) }
        }
        let listenerPIDs = Set(procPorts.keys)
        let relevant = listenerPIDs.union(clientPIDs)

        var procs: [pid_t: ProcInfo] = [:]
        var newCPU: [pid_t: (cpu: UInt64, wall: UInt64)] = [:]
        for pid in relevant {
            guard let kp = kprocs[pid] else { continue }
            var p = makeProc(kp)
            if kp.uid == me {
                p.cwd = ProcessInspector.cwd(pid)
                if let t = ProcessInspector.taskInfo(pid) {
                    p.rss = t.rss
                    if let prev = cpuPrev[pid], wallNow > prev.wall, t.cpuNs >= prev.cpu {
                        p.cpu = Double(t.cpuNs - prev.cpu) / Double(wallNow - prev.wall) * 100
                    }
                    newCPU[pid] = (t.cpuNs, wallNow)
                }
            }
            procs[pid] = p
            var cur = kp.ppid
            var depth = 0
            while cur > 1, procs[cur] == nil, let akp = kprocs[cur], depth < 64 {
                procs[cur] = makeProc(akp)
                cur = akp.ppid
                depth += 1
            }
        }

        // 8. Карточки.
        var entities: [String: Entity] = [:]
        var pidEntity: [pid_t: String] = [:]
        for pid in relevant.sorted() {
            guard let p = procs[pid] else { continue }
            if !listenerPIDs.contains(pid), let bundle = p.appBundle {
                // Клиенты одного приложения (вкладки Chrome, хелперы) — одна карточка.
                let id = "a:\(bundle)"
                if entities[id] == nil {
                    entities[id] = Entity(
                        id: id, kind: .appClients, title: Classifier.appName(bundle),
                        subtitle: "клиент", icon: .app(bundle),
                        isSystem: Classifier.isSystem(path: p.path, uid: p.uid),
                        isDockerEngine: Classifier.isDockerEngine(exe: p.executableName, bundle: bundle),
                        appBundle: bundle)
                }
                entities[id]!.pids.append(pid)
                entities[id]!.memory = (entities[id]!.memory ?? 0) + (p.rss ?? 0)
                pidEntity[pid] = id
                continue
            }
            var e = processEntity(p, ports: (procPorts[pid] ?? []).sorted { $0.port < $1.port })
            e.isDockerEngine = e.isDockerEngine || dockerEnginePIDs.contains(pid)
            entities[e.id] = e
            pidEntity[pid] = e.id
        }
        for c in containers {
            if !c.isRunning && (c.composeProject == nil || c.isOneOff) { continue }
            let e = containerEntity(c, net: nets[c.id])
            entities[e.id] = e
        }

        // Один порт у нескольких владельцев — конфликт, подсветим.
        var portOwners: [PubKey: Set<String>] = [:]
        for e in entities.values where e.isRunning {
            for b in e.ports where !b.internalOnly { portOwners[PubKey(proto: b.proto, port: b.port), default: []].insert(e.id) }
        }
        for (k, owners) in portOwners where owners.count > 1 {
            for id in owners {
                guard var e = entities[id] else { continue }
                for i in e.ports.indices where e.ports[i].proto == k.proto && e.ports[i].port == k.port && !e.ports[i].internalOnly {
                    e.ports[i].conflict = true
                }
                entities[id] = e
            }
        }

        // 9. Группы.
        var groups: [String: EntityGroup] = [:]
        func put(_ entityID: String, _ gid: String, _ make: () -> EntityGroup) {
            if groups[gid] == nil { groups[gid] = make() }
            groups[gid]!.entityIDs.append(entityID)
            entities[entityID]?.groupID = gid
        }
        // Папка с одним compose-проектом сливается с процессами этого проекта на Mac;
        // если из одной папки подняты несколько проектов (docker compose -p …), группируем по имени.
        var projectsPerDir: [String: Set<String>] = [:]
        for c in containers {
            if let dir = c.composeDir, let p = c.composeProject { projectsPerDir[dir, default: []].insert(p) }
        }
        for id in entities.keys.sorted() {
            guard let e = entities[id] else { continue }
            if e.kind == .container, let cid = e.containerID, let c = containerByID[cid] {
                if let project = c.composeProject {
                    let gid: String
                    if let dir = c.composeDir, projectsPerDir[dir]?.count == 1 { gid = "project:\(dir)" }
                    else { gid = "compose:\(project)" }
                    put(id, gid) {
                        EntityGroup(id: gid, kind: .compose, title: project,
                                    subtitle: c.composeDir.map(Classifier.abbreviate),
                                    icon: .symbol("square.stack.3d.up.fill", 0.56))
                    }
                    groups[gid]!.kind = .compose
                    groups[gid]!.title = project
                    groups[gid]!.icon = .symbol("square.stack.3d.up.fill", 0.56)
                    groups[gid]!.directory = c.composeDir
                    groups[gid]!.composeProject = project
                    groups[gid]!.composeFiles = c.composeFiles
                } else {
                    put(id, "docker") {
                        EntityGroup(id: "docker", kind: .docker, title: "Контейнеры Docker",
                                    subtitle: "без docker compose", icon: .symbol("shippingbox", 0.56))
                    }
                }
                continue
            }
            if e.isSystem {
                put(id, "system") {
                    EntityGroup(id: "system", kind: .system, title: "Службы macOS",
                                subtitle: "системные процессы", icon: .symbol("gearshape.2.fill", -1))
                }
                continue
            }
            if let bundle = e.appBundle {
                let gid = "app:\(bundle)"
                put(id, gid) { EntityGroup(id: gid, kind: .app, title: Classifier.appName(bundle), icon: .app(bundle)) }
                continue
            }
            guard let pid = e.pids.first, let p = procs[pid] else { continue }
            if let root = Classifier.projectRoot(for: p.cwd) {
                let gid = "project:\(root)"
                put(id, gid) {
                    EntityGroup(id: gid, kind: .project, title: (root as NSString).lastPathComponent,
                                subtitle: Classifier.abbreviate(root), icon: .symbol("folder.fill", 0.6), directory: root)
                }
                continue
            }
            if let bundle = launcherApp(of: pid, procs: procs) {
                let gid = "app:\(bundle)"
                put(id, gid) { EntityGroup(id: gid, kind: .app, title: Classifier.appName(bundle), icon: .app(bundle)) }
                continue
            }
            let isService = p.ppid == 1
            let gid = (isService ? "svc:" : "single:") + "\(pid)"
            put(id, gid) {
                EntityGroup(id: gid, kind: isService ? .service : .single, title: e.title,
                            subtitle: e.launchdLabel, icon: e.icon)
            }
        }
        for gid in groups.keys where groups[gid]!.kind == .compose {
            let members = groups[gid]!.entityIDs.compactMap { entities[$0] }
            if !members.contains(where: \.isRunning) { groups[gid]!.kind = .stoppedCompose }
        }
        for gid in groups.keys {
            groups[gid]!.entityIDs.sort { a, b in
                guard let ea = entities[a], let eb = entities[b] else { return a < b }
                if ea.isRunning != eb.isRunning { return ea.isRunning }
                if ea.isClientOnly != eb.isClientOnly { return !ea.isClientOnly }
                let pa = ea.ports.first?.port ?? .max, pb = eb.ports.first?.port ?? .max
                if pa != pb { return pa < pb }
                return ea.title.localizedStandardCompare(eb.title) == .orderedAscending
            }
        }
        let sortedGroups = groups.values.sorted { a, b in
            if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }

        // 10. Связи.
        func entityID(_ o: Owner) -> String? {
            switch o {
            case .pid(let p): return pidEntity[p]
            case .container(let c): return entities["c:\(c)"] != nil ? "c:\(c)" : nil
            }
        }
        let dt = lastScanAt.map { max(0.5, now.timeIntervalSince($0)) } ?? 1
        var agg: [String: Link] = [:]
        for r in rawLinks {
            guard let from = entityID(r.client), let to = entityID(r.server), from != to else { continue }
            let kind: LinkKind
            switch (r.client.isContainer, r.server.isContainer) {
            case (false, false): kind = .local
            case (false, true): kind = .toContainer
            case (true, true): kind = .betweenContainers
            case (true, false): kind = .fromContainer
            }
            let lid = "\(from)>\(to):\(r.port)"
            var l = agg[lid] ?? Link(from: from, to: to, port: r.port, kind: kind, connections: 0)
            l.connections += 1
            l.bytesPerSec += Double(r.delta) / dt
            agg[lid] = l
        }
        for (lid, l) in agg {
            var clients: [pid_t: Date] = [:]
            for pid in entities[l.from]?.pids ?? [] { if let kp = kprocs[pid] { clients[pid] = kp.started } }
            memory[lid] = Remembered(link: l, seen: now, clients: clients)
        }
        for (lid, m) in memory {
            if now.timeIntervalSince(m.seen) > opt.linkMemory { memory[lid] = nil; continue }
            if agg[lid] == nil, entities[m.link.from] != nil, entities[m.link.to] != nil {
                var l = m.link
                l.live = false
                l.connections = 0
                l.bytesPerSec = 0
                agg[lid] = l
            }
        }

        var external: [String: [ExternalPeer]] = [:]
        for (owner, peers) in externalRaw {
            guard let id = entityID(owner) else { continue }
            external[id, default: []] += peers.values
        }
        for id in external.keys { external[id]!.sort { $0.count > $1.count } }

        // 11. Отложенно: сеть внутри контейнеров (docker exec), не чаще раза в 8 секунд.
        if opt.dockerDeepScan, dockerState.isRunning {
            if opt.refreshContainerNets, !netScanRunning, now.timeIntervalSince(netScanAt) > 8 {
                let ids = running.map(\.id).filter { netScanSkip[$0].map { now.timeIntervalSince($0) > 300 } ?? true }
                netScanRunning = true
                let client = docker
                Task.detached(priority: .utility) {
                    var res: [String: ContainerNet] = [:]
                    var failed: [String] = []
                    for id in ids {
                        if let n = (try? client.netScan(id)) ?? nil { res[id] = n } else { failed.append(id) }
                    }
                    await self.storeNets(res, failed: failed)
                }
            }
        } else {
            containerNets = [:]
        }

        bytesPrev = newBytes
        cpuPrev = newCPU
        lastScanAt = now
        if statics.count > 3000 {
            let alive = Set(kprocs.values.map { Self.staticKey($0) })
            statics = statics.filter { alive.contains($0.key) }
        }

        var snap = Snapshot()
        snap.date = now
        snap.entities = entities
        snap.groups = sortedGroups
        snap.links = agg.values.sorted { $0.id < $1.id }
        snap.processes = procs
        snap.containers = containerByID
        snap.external = external
        snap.docker = dockerState
        snap.scanned = true
        return snap
    }

    private func storeNets(_ res: [String: ContainerNet], failed: [String]) {
        containerNets = res
        let now = Date()
        for f in failed { netScanSkip[f] = now }
        netScanAt = now
        netScanRunning = false
    }

    // MARK: Помощники

    private static func byteKey(_ proto: NetProto, _ l: UInt16, _ r: UInt16) -> String {
        "\(proto.rawValue)|\(l)|\(r)"
    }

    private static func staticKey(_ kp: KernelProc) -> String {
        "\(kp.pid)@\(kp.started.timeIntervalSince1970)"
    }

    private func staticInfo(_ pid: pid_t, _ kp: KernelProc) -> StaticInfo {
        let key = Self.staticKey(kp)
        if let s = statics[key] { return s }
        let path = ProcessInspector.path(pid)
        let args = kp.uid == ProcessInspector.myUID ? ProcessInspector.arguments(pid) : nil
        var bundle = Classifier.appBundle(for: path)
        if let b = bundle, let path, Classifier.isInterpreter((path as NSString).lastPathComponent),
           !Classifier.isMainExecutable(path, of: b) {
            bundle = nil
        }
        let s = StaticInfo(path: path, args: args, bundle: bundle)
        statics[key] = s
        return s
    }

    private func makeProc(_ kp: KernelProc) -> ProcInfo {
        let st = staticInfo(kp.pid, kp)
        return ProcInfo(pid: kp.pid, ppid: kp.ppid, uid: kp.uid, comm: kp.comm, started: kp.started,
                        path: st.path, args: st.args, appBundle: st.bundle,
                        user: ProcessInspector.userName(kp.uid))
    }

    /// Процесс без .app и без проекта, но запущенный приложением (не из терминала) — например, языковой сервер редактора.
    private func launcherApp(of pid: pid_t, procs: [pid_t: ProcInfo]) -> String? {
        var cur = procs[pid]?.ppid ?? 0
        var depth = 0
        while cur > 1, let a = procs[cur], depth < 32 {
            let name = a.comm.hasPrefix("-") ? String(a.comm.dropFirst()) : a.comm
            if Classifier.shells.contains(name) { return nil }
            if let b = a.appBundle, !Classifier.isSystem(path: a.path, uid: a.uid) { return b }
            cur = a.ppid
            depth += 1
        }
        return nil
    }

    private func processEntity(_ p: ProcInfo, ports: [PortBinding]) -> Entity {
        let exe = p.executableName
        let fl = Classifier.flavor(exe: exe, args: p.args ?? [exe], bundle: p.appBundle)
        var title = fl.title ?? exe
        var parts: [String] = []
        if let b = p.appBundle {
            let app = Classifier.appName(b)
            if let path = p.path, Classifier.isMainExecutable(path, of: b) {
                title = fl.title ?? app
            } else if title != app {
                parts.append(app)
            }
        }
        if let d = fl.detail, !d.isEmpty { parts.insert(d, at: 0) }
        if parts.isEmpty, title != exe { parts.append(exe) }

        let icon: IconSource
        if let b = p.appBundle { icon = .app(b) }
        else if let badge = fl.badge { icon = .badge(badge.0, badge.1) }
        else { icon = .symbol("terminal.fill", -1) }

        var e = Entity(id: "p:\(p.pid)", kind: .process, title: title,
                       subtitle: parts.joined(separator: " · "), icon: icon, ports: ports)
        e.pids = [p.pid]
        e.isSystem = Classifier.isSystem(path: p.path, uid: p.uid)
        e.isDockerEngine = Classifier.isDockerEngine(exe: exe, bundle: p.appBundle)
        e.cpu = p.cpu
        e.memory = p.rss
        e.started = p.started
        e.hint = fl.hint
        // «application.…» — так launchd помечает обычные приложения, это не служба.
        e.launchdLabel = launchd[p.pid].flatMap { $0.hasPrefix("application.") ? nil : $0 }
        e.appBundle = p.appBundle
        e.projectDir = Classifier.projectRoot(for: p.cwd)
        return e
    }

    private func containerEntity(_ c: DockerContainer, net: ContainerNet?) -> Entity {
        var ports: [PortBinding] = []
        var inner = Set<UInt16>()
        for p in c.ports {
            guard let pub = p.publicPort else { continue }
            let ips = p.ips.isEmpty ? ["*"] : p.ips
            ports.append(PortBinding(proto: p.proto, port: pub, addresses: ips,
                                     scope: ips.map(BindScope.init(address:)).max() ?? .any,
                                     innerPort: p.privatePort))
            inner.insert(p.privatePort)
        }
        for p in c.ports where p.publicPort == nil && !inner.contains(p.privatePort) {
            ports.append(PortBinding(proto: p.proto, port: p.privatePort, addresses: [], scope: .loopback, internalOnly: true))
            inner.insert(p.privatePort)
        }
        for lp in (net?.listening ?? []).sorted() where !inner.contains(lp) {
            ports.append(PortBinding(proto: .tcp, port: lp, addresses: [], scope: .loopback, internalOnly: true))
            inner.insert(lp)
        }
        ports.sort { ($0.internalOnly ? 1 : 0, $0.port) < ($1.internalOnly ? 1 : 0, $1.port) }

        var e = Entity(id: "c:\(c.id)", kind: .container, title: c.composeService ?? c.name,
                       subtitle: c.image, icon: .symbol("shippingbox.fill", 0.56), ports: ports)
        e.containerID = c.id
        e.isRunning = c.isRunning
        e.started = c.created
        e.health = c.health
        e.projectDir = c.composeDir
        return e
    }
}
