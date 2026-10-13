import Foundation

// MARK: - Сеть

enum NetProto: String, Hashable, Sendable {
    case tcp = "TCP", udp = "UDP"
}

enum TCPState: Int, Sendable {
    case closed = 0, listen, synSent, synReceived, established, closeWait,
         finWait1, closing, lastAck, finWait2, timeWait
    case unknown = 99

    init(netstat s: String) {
        switch s {
        case "LISTEN": self = .listen
        case "ESTABLISHED": self = .established
        case "SYN_SENT": self = .synSent
        case "SYN_RCVD", "SYN_RECEIVED": self = .synReceived
        case "CLOSE_WAIT": self = .closeWait
        case "FIN_WAIT_1": self = .finWait1
        case "FIN_WAIT_2": self = .finWait2
        case "CLOSING": self = .closing
        case "LAST_ACK": self = .lastAck
        case "TIME_WAIT": self = .timeWait
        case "CLOSED": self = .closed
        default: self = .unknown
        }
    }
}

struct NetEndpoint: Hashable, Sendable {
    var address: String
    var port: UInt16

    var display: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

/// Один сокет одного процесса — из libproc или netstat.
struct SocketRecord: Hashable, Sendable {
    var pid: pid_t
    var proto: NetProto
    var local: NetEndpoint
    var remote: NetEndpoint?
    var state: TCPState
    var rx: UInt64? = nil
    var tx: UInt64? = nil

    /// Слушающий TCP-сокет или «привязанный» UDP-сокет без собеседника.
    var isListener: Bool {
        proto == .tcp ? state == .listen : remote == nil
    }
}

/// Насколько широко открыт порт.
enum BindScope: Int, Comparable, Sendable {
    case loopback = 0   // только этот Mac
    case specific = 1   // конкретный интерфейс (адрес в сети, VPN…)
    case any = 2        // все интерфейсы — порт виден из сети

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    init(address: String) {
        if Address.isAny(address) { self = .any }
        else if Address.isLoopback(address) { self = .loopback }
        else { self = .specific }
    }

    var title: String {
        switch self {
        case .loopback: return "Только этот Mac"
        case .specific: return "Конкретный адрес"
        case .any: return "Виден из сети"
        }
    }
}

enum Address {
    static func isLoopback(_ a: String) -> Bool {
        a.hasPrefix("127.") || a == "::1" || a.hasPrefix("::ffff:127.") || a == "localhost"
    }

    static func isAny(_ a: String) -> Bool {
        a == "*" || a == "0.0.0.0" || a == "::" || a.isEmpty || a == "::ffff:0.0.0.0"
    }
}

// MARK: - Процессы

struct ProcInfo: Sendable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let comm: String
    let started: Date
    var path: String?
    var args: [String]?
    var cwd: String?
    var rss: UInt64?
    var cpu: Double?
    var appBundle: String?
    var user: String

    var executableName: String {
        path.map { ($0 as NSString).lastPathComponent } ?? comm
    }

    var commandLine: String? {
        guard let args, !args.isEmpty else { return nil }
        return args.map(Shell.quote).joined(separator: " ")
    }
}

enum Shell {
    static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Docker

struct DockerPort: Hashable, Sendable {
    var ips: [String]
    var privatePort: UInt16
    var publicPort: UInt16?
    var proto: NetProto
}

struct DockerNetwork: Hashable, Sendable {
    var name: String
    var ip: String
    var gateway: String
}

struct DockerContainer: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var image: String
    var command: String
    var state: String
    var status: String
    var health: String?
    var created: Date
    var ports: [DockerPort]
    var labels: [String: String]
    var networks: [DockerNetwork]

    var isRunning: Bool { state == "running" || state == "restarting" }
    var shortID: String { String(id.prefix(12)) }
    var composeProject: String? { labels["com.docker.compose.project"] }
    var composeService: String? { labels["com.docker.compose.service"] }
    var composeDir: String? { labels["com.docker.compose.project.working_dir"] }
    var composeFiles: String? { labels["com.docker.compose.project.config_files"] }
    var isOneOff: Bool { labels["com.docker.compose.oneoff"]?.lowercased() == "true" }
}

enum DockerState: Equatable, Sendable {
    case unknown
    case notFound
    case notRunning
    case running(version: String)
    case failed(String)

    var isRunning: Bool { if case .running = self { return true } else { return false } }

    var title: String {
        switch self {
        case .unknown: return "Docker: проверяю…"
        case .notFound: return "Docker не найден"
        case .notRunning: return "Docker не запущен"
        case .running(let v): return v.isEmpty ? "Docker работает" : v.hasPrefix("Docker") ? v : "Docker \(v)"
        case .failed(let m): return "Docker: \(m)"
        }
    }
}

/// Что удалось узнать о сети изнутри контейнера (через /proc/net/tcp).
struct ContainerNet: Sendable, Equatable {
    var listening: Set<UInt16>
    var outbound: [NetEndpoint]
}

// MARK: - То, что видит пользователь

enum EntityKind: Sendable {
    case process        // процесс на Mac
    case appClients     // процессы-клиенты одного приложения, склеенные в одну карточку
    case container      // контейнер Docker
}

struct PortBinding: Identifiable, Hashable, Sendable {
    var proto: NetProto
    var port: UInt16
    var addresses: [String]
    var scope: BindScope
    var innerPort: UInt16? = nil     // порт внутри контейнера
    var internalOnly = false         // порт контейнера, не опубликованный на Mac
    var conflict = false             // этот же порт держит кто-то ещё

    var id: String { "\(proto.rawValue)-\(port)-\(innerPort ?? 0)-\(internalOnly)" }
    var isDocker: Bool { innerPort != nil }

    var label: String {
        if internalOnly { return "\(port)" }
        if let inner = innerPort, inner != port { return "\(port)→\(inner)" }
        return "\(port)"
    }
}

enum IconSource: Hashable, Sendable {
    case app(String)                 // путь к .app
    case badge(String, Double)       // короткий текст и оттенок 0…1
    case symbol(String, Double)      // SF Symbol и оттенок (−1 — серый)
}

struct Entity: Identifiable, Sendable {
    let id: String
    var kind: EntityKind
    var title: String
    var subtitle: String
    var icon: IconSource
    var ports: [PortBinding] = []
    var pids: [pid_t] = []
    var containerID: String? = nil
    var groupID: String = ""
    var isSystem = false
    var isDockerEngine = false
    var isRunning = true
    var cpu: Double? = nil
    var memory: UInt64? = nil
    var started: Date? = nil
    var hint: String? = nil
    var launchdLabel: String? = nil
    var appBundle: String? = nil
    var projectDir: String? = nil
    var health: String? = nil

    var pid: pid_t? { kind == .process ? pids.first : nil }
    var isClientOnly: Bool { kind != .container && ports.isEmpty }
    var publicPorts: [PortBinding] { ports.filter { !$0.internalOnly } }
}

enum GroupKind: Sendable {
    case project, compose, app, service, single, docker, stoppedCompose, system

    var rank: Int {
        switch self {
        case .project, .compose: return 0
        case .app: return 1
        case .service, .single: return 2
        case .docker: return 3
        case .stoppedCompose: return 4
        case .system: return 5
        }
    }

    /// Группа сама по себе что-то значит (проект, compose), даже если в ней один элемент.
    var isMeaningful: Bool {
        switch self {
        case .project, .compose, .docker, .stoppedCompose, .system: return true
        default: return false
        }
    }
}

struct EntityGroup: Identifiable, Sendable {
    let id: String
    var kind: GroupKind
    var title: String
    var subtitle: String?
    var icon: IconSource
    var entityIDs: [String] = []
    var directory: String? = nil
    var composeProject: String? = nil
    var composeFiles: String? = nil
}

enum LinkKind: Sendable {
    case local              // Mac → Mac
    case toContainer        // Mac → контейнер (через опубликованный порт)
    case betweenContainers  // контейнер → контейнер
    case fromContainer      // контейнер → Mac (host.docker.internal)
}

struct Link: Identifiable, Hashable, Sendable {
    var from: String
    var to: String
    var port: UInt16
    var kind: LinkKind
    var connections: Int
    var bytesPerSec: Double = 0
    var live = true

    var id: String { "\(from)>\(to):\(port)" }
    var isActive: Bool { live && bytesPerSec > 0 }
}

struct ExternalPeer: Hashable, Sendable {
    var remote: NetEndpoint
    var inbound: Bool
    var localPort: UInt16
    var count: Int
}

struct Snapshot: Sendable {
    var date = Date()
    var entities: [String: Entity] = [:]
    var groups: [EntityGroup] = []
    var links: [Link] = []
    var processes: [pid_t: ProcInfo] = [:]
    var containers: [String: DockerContainer] = [:]
    var external: [String: [ExternalPeer]] = [:]
    var docker: DockerState = .unknown
    var scanned = false

    static let empty = Snapshot()

    func group(_ id: String?) -> EntityGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// Цепочка родителей процесса: от непосредственного родителя вверх, без launchd.
    func ancestors(of pid: pid_t) -> [ProcInfo] {
        var out: [ProcInfo] = []
        var cur = processes[pid]?.ppid ?? 0
        var guardCount = 0
        while cur > 1, let p = processes[cur], guardCount < 64 {
            out.append(p)
            cur = p.ppid
            guardCount += 1
        }
        return out
    }

    func incoming(_ id: String) -> [Link] { links.filter { $0.to == id } }
    func outgoing(_ id: String) -> [Link] { links.filter { $0.from == id } }
}
