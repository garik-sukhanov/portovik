import Foundation

struct VisibleGroup: Identifiable {
    var group: EntityGroup
    var entities: [Entity]
    var id: String { group.id }
}

/// Снимок после фильтров и поиска — то, что реально рисуется.
struct VisibleModel {
    var groups: [VisibleGroup] = []
    var links: [Link] = []
    var portCount = 0
    var appCount = 0
    var freePort: UInt16?
    var query = ""

    struct Options {
        var search = ""
        var showSystem = true
        var showClients = true
        var includeStopped = true
        var includeNeighbors = false
    }

    static func build(_ s: Snapshot, _ o: Options) -> VisibleModel {
        var m = VisibleModel()
        var q = o.search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix(":") { q.removeFirst() }
        m.query = q
        let numeric = !q.isEmpty && q.count <= 5 && q.allSatisfy(\.isNumber)

        func passesFilters(_ e: Entity, _ g: EntityGroup) -> Bool {
            if !o.includeStopped && !e.isRunning { return false }
            if !o.showClients && e.isClientOnly { return false }
            if q.isEmpty && !o.showSystem && (e.isSystem || g.kind == .system) { return false }
            // Системные клиенты (демоны macOS, которые ходят через прокси и т.п.) — шум; видны только в поиске.
            if q.isEmpty && e.isSystem && e.isClientOnly { return false }
            return true
        }

        func matches(_ e: Entity, _ g: EntityGroup) -> Bool {
            if q.isEmpty { return true }
            if numeric {
                return e.ports.contains { String($0.port).hasPrefix(q) || $0.innerPort.map { String($0) == q } == true }
            }
            var hay = [e.title, e.subtitle, g.title, g.subtitle ?? "", e.launchdLabel ?? "", e.projectDir ?? ""]
            if let pid = e.pid {
                hay.append(String(pid))
                if let cmd = s.processes[pid]?.commandLine { hay.append(cmd) }
            }
            if let cid = e.containerID, let c = s.containers[cid] { hay += [c.name, c.image, c.shortID] }
            return hay.contains { $0.lowercased().contains(q) }
        }

        var groupOf: [String: EntityGroup] = [:]
        var candidates = Set<String>()
        var matched = Set<String>()
        for g in s.groups {
            if g.kind == .stoppedCompose && !o.includeStopped { continue }
            for id in g.entityIDs {
                guard let e = s.entities[id], passesFilters(e, g) else { continue }
                groupOf[id] = g
                candidates.insert(id)
                if matches(e, g) { matched.insert(id) }
            }
        }
        if o.includeNeighbors && !q.isEmpty {
            for l in s.links {
                if matched.contains(l.from), candidates.contains(l.to) { matched.insert(l.to) }
                if matched.contains(l.to), candidates.contains(l.from) { matched.insert(l.from) }
            }
        }

        for g in s.groups {
            let ents = g.entityIDs.filter(matched.contains).compactMap { s.entities[$0] }
            if !ents.isEmpty { m.groups.append(VisibleGroup(group: g, entities: ents)) }
        }
        m.links = s.links.filter { matched.contains($0.from) && matched.contains($0.to) }
        for vg in m.groups {
            for e in vg.entities where e.isRunning {
                let n = e.publicPorts.count
                m.portCount += n
                if n > 0 { m.appCount += 1 }
            }
        }
        if numeric, let n = Int(q), n > 0, n <= 65535 {
            let busy = s.entities.values.contains { e in
                e.isRunning && e.ports.contains { !$0.internalOnly && Int($0.port) == n }
            }
            if !busy { m.freePort = UInt16(n) }
        }
        return m
    }
}

enum Format {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }

    static func rate(_ bps: Double) -> String {
        if bps < 1 { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .binary) + "/с"
    }

    static func cpu(_ v: Double) -> String {
        v < 10 ? String(format: "%.1f%%", v).replacingOccurrences(of: ".", with: ",") : String(format: "%.0f%%", v)
    }

    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "\(Int(s)) с" }
        if s < 3600 { return "\(Int(s / 60)) мин" }
        if s < 86_400 { return "\(Int(s / 3600)) ч" }
        return "\(Int(s / 86_400)) дн"
    }

    static func started(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(f.string(from: d)) (\(age(d)) назад)"
    }
}
