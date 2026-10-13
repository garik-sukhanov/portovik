import Darwin
import Foundation

/// Минимальный клиент Docker Engine API через unix-сокет — без docker CLI.
/// Работает с Docker Desktop, OrbStack, Colima, Rancher Desktop и Podman (docker-совместимый сокет).
final class DockerClient: @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    enum Failure: LocalizedError {
        case noSocket
        case connect(Int32)
        case io(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noSocket: return "Сокет Docker не найден"
            case .connect(let e): return "Нет связи с Docker (\(String(cString: strerror(e))))"
            case .io(let m): return m
            case .http(let code, let m): return m.isEmpty ? "Docker ответил \(code)" : m
            }
        }
    }

    private let lock = NSLock()
    private var cachedSocket: String?

    // MARK: Поиск сокета

    static func candidateSockets() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list: [String] = []
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            list.append(String(host.dropFirst(7)))
        }
        if let ctx = currentContextSocket() { list.append(ctx) }
        list += [
            "\(home)/.docker/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.colima/docker.sock",
            "\(home)/.rd/docker.sock",
            "\(home)/.local/share/containers/podman/machine/podman.sock",
            "/var/run/docker.sock",
        ]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// Сокет из текущего docker context (~/.docker/config.json → contexts/meta/*/meta.json).
    private static func currentContextSocket() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cfgURL = home.appendingPathComponent(".docker/config.json")
        guard let data = try? Data(contentsOf: cfgURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = cfg["currentContext"] as? String,
              current != "default" else { return nil }
        let metaDir = home.appendingPathComponent(".docker/contexts/meta")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: metaDir.path) else { return nil }
        for d in dirs {
            let url = metaDir.appendingPathComponent(d).appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: url),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  meta["Name"] as? String == current,
                  let endpoints = meta["Endpoints"] as? [String: Any],
                  let dockerEP = endpoints["docker"] as? [String: Any],
                  let host = dockerEP["Host"] as? String, host.hasPrefix("unix://") else { continue }
            return String(host.dropFirst(7))
        }
        return nil
    }

    /// Есть ли вообще на Mac какой-нибудь Docker — чтобы отличать «не запущен» от «не установлен».
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        let apps = ["/Applications/Docker.app", "/Applications/OrbStack.app",
                    "/Applications/Rancher Desktop.app", "/Applications/Podman Desktop.app"]
        if apps.contains(where: fm.fileExists(atPath:)) { return true }
        let bins = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/opt/homebrew/bin/colima"]
        return bins.contains(where: fm.fileExists(atPath:))
    }

    private func socketPath() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let s = cachedSocket, FileManager.default.fileExists(atPath: s) { return s }
        cachedSocket = Self.candidateSockets().first { FileManager.default.fileExists(atPath: $0) }
        return cachedSocket
    }

    private func forgetSocket() {
        lock.lock(); cachedSocket = nil; lock.unlock()
    }

    // MARK: HTTP поверх unix-сокета

    func request(_ method: String, _ path: String, json: Any? = nil, timeout: TimeInterval = 6) throws -> Response {
        guard let sock = socketPath() else { throw Failure.noSocket }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io("socket(): \(errno)") }
        defer { close(fd) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sock.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw Failure.io("Слишком длинный путь к сокету") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            forgetSocket()
            throw Failure.connect(e)
        }

        var body = Data()
        if let json { body = try JSONSerialization.data(withJSONObject: json) }
        // HTTP/1.0: Docker отвечает без chunked и сам закрывает соединение в конце ответа.
        var head = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nUser-Agent: Portovik\r\n"
        if json != nil || method == "POST" {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var packet = Data(head.utf8)
        packet.append(body)
        try packet.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { throw Failure.io("Не удалось отправить запрос Docker") }
                sent += n
            }
        }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(buf, count: n); continue }
            if n == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.io("Docker не ответил за \(Int(timeout)) с") }
            throw Failure.io("Ошибка чтения из сокета Docker: \(errno)")
        }
        return try Self.parseResponse(data)
    }

    static func parseResponse(_ data: Data) throws -> Response {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { throw Failure.io("Непонятный ответ Docker") }
        let headText = String(decoding: data[data.startIndex..<sep.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[sep.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = dechunk(body)
        }
        return Response(status: status, headers: headers, body: body)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            guard let lineEnd = data[i...].range(of: Data("\r\n".utf8)) else { break }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = min(data.endIndex, start + size)
            out.append(data[start..<end])
            i = min(data.endIndex, end + 2)
        }
        return out
    }

    private func check(_ r: Response, _ ok: Set<Int>) throws {
        guard ok.contains(r.status) else {
            let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
            let msg = (obj?["message"] as? String) ?? String(decoding: r.body.prefix(300), as: UTF8.self)
            throw Failure.http(r.status, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: API

    func version() throws -> String {
        let r = try request("GET", "/version", timeout: 3)
        try check(r, [200])
        let obj = try JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        let platform = (obj?["Platform"] as? [String: Any])?["Name"] as? String
        return platform ?? (obj?["Version"] as? String) ?? ""
    }

    func containers() throws -> [DockerContainer] {
        let r = try request("GET", "/containers/json?all=1", timeout: 4)
        try check(r, [200])
        let arr = (try JSONSerialization.jsonObject(with: r.body) as? [[String: Any]]) ?? []
        return arr.compactMap(Self.parseContainer)
    }

    static func parseContainer(_ o: [String: Any]) -> DockerContainer? {
        guard let id = o["Id"] as? String else { return nil }
        let name = ((o["Names"] as? [String])?.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var image = o["Image"] as? String ?? ""
        if let at = image.range(of: "@sha256:") { image = String(image[..<at.lowerBound]) }
        if image.hasPrefix("sha256:") { image = String(image.dropFirst(7).prefix(12)) }
        let status = o["Status"] as? String ?? ""
        var health = (o["Health"] as? [String: Any])?["Status"] as? String
        if health == nil {
            if status.contains("(healthy)") { health = "healthy" }
            else if status.contains("(unhealthy)") { health = "unhealthy" }
            else if status.contains("health: starting") { health = "starting" }
        }

        // Docker перечисляет один порт дважды — для IPv4 и IPv6; склеиваем.
        var portMap: [String: DockerPort] = [:]
        var order: [String] = []
        for p in o["Ports"] as? [[String: Any]] ?? [] {
            guard let priv = (p["PrivatePort"] as? NSNumber)?.uint16Value else { continue }
            let pub = (p["PublicPort"] as? NSNumber)?.uint16Value
            let proto: NetProto = (p["Type"] as? String) == "udp" ? .udp : .tcp
            let ip = p["IP"] as? String ?? ""
            let key = "\(proto.rawValue)-\(priv)-\(pub ?? 0)"
            if portMap[key] == nil {
                portMap[key] = DockerPort(ips: [], privatePort: priv, publicPort: pub, proto: proto)
                order.append(key)
            }
            if !ip.isEmpty, !(portMap[key]!.ips.contains(ip)) { portMap[key]!.ips.append(ip) }
        }

        var networks: [DockerNetwork] = []
        let nets = (o["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any] ?? [:]
        for (netName, v) in nets {
            guard let n = v as? [String: Any] else { continue }
            networks.append(DockerNetwork(name: netName,
                                          ip: n["IPAddress"] as? String ?? "",
                                          gateway: n["Gateway"] as? String ?? ""))
        }
        networks.sort { $0.name < $1.name }

        return DockerContainer(
            id: id, name: name, image: image,
            command: o["Command"] as? String ?? "",
            state: o["State"] as? String ?? "",
            status: status, health: health,
            created: Date(timeIntervalSince1970: (o["Created"] as? NSNumber)?.doubleValue ?? 0),
            ports: order.compactMap { portMap[$0] },
            labels: o["Labels"] as? [String: String] ?? [:],
            networks: networks)
    }

    func stop(_ id: String) throws {
        try check(try request("POST", "/containers/\(id)/stop?t=10", timeout: 30), [204, 304])
    }

    func start(_ id: String) throws {
        try check(try request("POST", "/containers/\(id)/start", timeout: 30), [204, 304])
    }

    func restart(_ id: String) throws {
        try check(try request("POST", "/containers/\(id)/restart?t=10", timeout: 40), [204])
    }

    func logs(_ id: String, tail: Int = 500) throws -> String {
        let r = try request("GET", "/containers/\(id)/logs?stdout=1&stderr=1&tail=\(tail)", timeout: 8)
        try check(r, [200])
        return String(decoding: Self.demux(r.body), as: UTF8.self)
    }

    /// Соединения изнутри контейнера: `cat /proc/net/tcp*` через docker exec.
    /// `nil` — в контейнере нет `cat` или exec не удался.
    func netScan(_ id: String) throws -> ContainerNet? {
        let create = try request("POST", "/containers/\(id)/exec", json: [
            "Cmd": ["cat", "/proc/net/tcp", "/proc/net/tcp6"],
            "AttachStdout": true, "AttachStderr": false,
        ], timeout: 4)
        try check(create, [201])
        guard let obj = try JSONSerialization.jsonObject(with: create.body) as? [String: Any],
              let execID = obj["Id"] as? String else { return nil }
        let start = try request("POST", "/exec/\(execID)/start", json: ["Detach": false, "Tty": false], timeout: 5)
        try check(start, [200])
        return ProcNetTCP.parse(String(decoding: Self.demux(start.body), as: UTF8.self))
    }

    /// Поток docker без TTY разбит на кадры: [тип, 0, 0, 0, размер(4 байта BE)] + данные.
    static func demux(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] <= 2, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0 else { return data }
        var out = Data()
        var i = 0
        while i + 8 <= bytes.count {
            let size = Int(bytes[i + 4]) << 24 | Int(bytes[i + 5]) << 16 | Int(bytes[i + 6]) << 8 | Int(bytes[i + 7])
            let start = i + 8
            let end = min(bytes.count, start + size)
            out.append(contentsOf: bytes[start..<end])
            i = end
        }
        return out
    }
}

/// Разбор /proc/net/tcp и /proc/net/tcp6 из Linux-контейнера.
enum ProcNetTCP {
    static func parse(_ text: String) -> ContainerNet? {
        guard text.contains("local_address") else { return nil }
        var allListen = Set<UInt16>()
        var visibleListen = Set<UInt16>()
        var established: [(NetEndpoint, NetEndpoint)] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count > 4, f[0].hasSuffix(":"),
                  let l = endpoint(f[1]), let r = endpoint(f[2]) else { continue }
            switch f[3] {
            case "0A":
                allListen.insert(l.port)
                // 127.0.0.11 — встроенный DNS Docker, остальное на loopback снаружи недоступно.
                if !Address.isLoopback(l.address) { visibleListen.insert(l.port) }
            case "01":
                established.append((l, r))
            default:
                break
            }
        }
        // Соединения на свои слушающие порты — входящие; остаются исходящие.
        let outbound = established
            .filter { !allListen.contains($0.0.port) && !Address.isLoopback($0.1.address) }
            .map { $0.1 }
        return ContainerNet(listening: visibleListen, outbound: outbound)
    }

    /// «0100007F:1F40» → 127.0.0.1:8000. Адрес записан 32-битными словами в порядке little-endian.
    static func endpoint(_ s: Substring) -> NetEndpoint? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1], radix: 16) else { return nil }
        let hex = parts[0]
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 8, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let word = UInt32(hex[idx..<next], radix: 16) else { return nil }
            bytes += [UInt8(word & 0xff), UInt8((word >> 8) & 0xff), UInt8((word >> 16) & 0xff), UInt8(word >> 24)]
            idx = next
        }
        let address: String
        switch bytes.count {
        case 4:
            address = bytes.map(String.init).joined(separator: ".")
        case 16:
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                address = bytes[12..<16].map(String.init).joined(separator: ".")
            } else if bytes.allSatisfy({ $0 == 0 }) {
                address = "::"
            } else {
                var a6 = in6_addr()
                withUnsafeMutableBytes(of: &a6) { $0.copyBytes(from: bytes) }
                address = ProcessInspector.ntop(AF_INET6, &a6)
            }
        default:
            return nil
        }
        return NetEndpoint(address: address == "0.0.0.0" ? "*" : address, port: port)
    }
}
