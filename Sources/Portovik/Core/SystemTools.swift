import Foundation

/// Запуск системных утилит и разбор их вывода.
enum Command {
    struct Result {
        var status: Int32
        var output: String
        var error: String
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Сначала дочитываем вывод, потом ждём — иначе большой вывод упрётся в буфер канала.
        var errData = Data()
        let errQueue = DispatchQueue(label: "cmd.stderr")
        errQueue.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errQueue.sync {}
        timer.cancel()
        return Result(status: p.terminationStatus,
                      output: String(decoding: outData, as: UTF8.self),
                      error: String(decoding: errData, as: UTF8.self))
    }
}

/// `netstat -anv` знает PID владельца для сокетов всех пользователей (в том числе root)
/// и считает переданные байты — libproc без прав администратора этого не даёт.
enum Netstat {
    static func read(includeUDP: Bool) -> [SocketRecord]? {
        guard let tcp = Command.run("/usr/sbin/netstat", ["-anv", "-p", "tcp"]), tcp.status == 0 else { return nil }
        var out = parse(tcp.output)
        if includeUDP, let udp = Command.run("/usr/sbin/netstat", ["-anv", "-p", "udp"]), udp.status == 0 {
            out += parse(udp.output)
        }
        return out
    }

    // proto  recv-q send-q  local  foreign  [state]  rxbytes txbytes rhiwat shiwat  process:pid  state(hex) …
    private static let lineRE = try! NSRegularExpression(
        pattern: #"^(tcp|udp)(?:4|6|46)?\s+\d+\s+\d+\s+(\S+)\s+(\S+)\s+(?:([A-Z][A-Z0-9_]*)\s+)?(\d+)\s+(\d+)\s+\d+\s+\d+\s+(.*?):(\d+)\s+[0-9a-f]{5}\s"#
    )

    static func parse(_ text: String) -> [SocketRecord] {
        var out: [SocketRecord] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("tcp") || s.hasPrefix("udp") else { continue }
            let ns = s as NSString
            guard let m = lineRE.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            func g(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let proto: NetProto = g(1) == "tcp" ? .tcp : .udp
            guard let pidStr = g(8), let pid = pid_t(pidStr), pid > 0,
                  let localPart = g(2).map(splitEndpoint), let lport = localPart.1 else { continue }
            let laddr = localPart.0
            let (faddr, fport) = splitEndpoint(g(3) ?? "*.*")
            let state = proto == .tcp ? TCPState(netstat: g(4) ?? "") : .unknown
            if proto == .tcp, state != .listen, state != .established { continue }
            let remote = fport.map { NetEndpoint(address: faddr, port: $0) }
            var rec = SocketRecord(pid: pid, proto: proto,
                                   local: NetEndpoint(address: laddr, port: lport),
                                   remote: proto == .tcp && state == .listen ? nil : remote,
                                   state: state)
            rec.rx = g(5).flatMap(UInt64.init)
            rec.tx = g(6).flatMap(UInt64.init)
            out.append(rec)
        }
        return out
    }

    /// «127.0.0.1.8080» → ("127.0.0.1", 8080); «*.*» → ("*", nil); «::1.5432» → ("::1", 5432).
    static func splitEndpoint(_ s: String) -> (String, UInt16?) {
        guard let dot = s.lastIndex(of: ".") else { return (s, nil) }
        let addr = String(s[..<dot])
        let port = UInt16(s[s.index(after: dot)...])
        var a = addr
        if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) }
        if a.hasPrefix("::ffff:"), a.contains(".") { a = String(a.dropFirst(7)) }
        return (a, port)
    }
}

/// Какие процессы запущены launchd как службы пользователя (pid → метка).
enum Launchd {
    static func userJobs() -> [pid_t: String] {
        guard let r = Command.run("/bin/launchctl", ["list"]), r.status == 0 else { return [:] }
        return parse(r.output)
    }

    static func parse(_ text: String) -> [pid_t: String] {
        var out: [pid_t: String] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3, let pid = pid_t(f[0]) else { continue }
            out[pid] = String(f[2])
        }
        return out
    }

    @discardableResult
    static func bootout(label: String) -> (ok: Bool, message: String) {
        guard let r = Command.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"]) else {
            return (false, "Не удалось запустить launchctl")
        }
        let msg = (r.error + r.output).trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0, msg)
    }
}
