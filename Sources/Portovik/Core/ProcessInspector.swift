import Darwin
import Foundation

/// Базовые сведения о процессе из ядра — доступны для любого пользователя.
struct KernelProc: Sendable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let comm: String
    let started: Date
    var isZombie = false
}

/// Чтение процессов и их сокетов через sysctl и libproc — без запуска внешних утилит.
enum ProcessInspector {
    static let myUID = getuid()

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
    }()

    // MARK: Список процессов

    static func allProcesses() -> [pid_t: KernelProc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
        var len = buf.count * stride
        guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return [:] }

        var out: [pid_t: KernelProc] = [:]
        out.reserveCapacity(len / stride)
        for i in 0..<(len / stride) {
            if let kp = kernelProc(from: &buf[i]) { out[kp.pid] = kp }
        }
        return out
    }

    static func kernelProc(_ pid: pid_t) -> KernelProc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &len, nil, 0) == 0, len > 0 else { return nil }
        return kernelProc(from: &info)
    }

    private static func kernelProc(from kp: inout kinfo_proc) -> KernelProc? {
        let pid = kp.kp_proc.p_pid
        guard pid >= 0 else { return nil }
        let comm = withUnsafeBytes(of: &kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let tv = kp.kp_proc.p_un.__p_starttime
        let started = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
        return KernelProc(pid: pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid,
                          comm: comm, started: started, isZombie: kp.kp_proc.p_stat == SZOMB)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Сокеты

    /// Сокеты процесса. `nil` — нет прав (чужой процесс) или процесс уже завершился.
    /// Второй элемент — адрес сокета в ядре: один и тот же сокет бывает унаследован детьми.
    static func sockets(pid: pid_t, includeUDP: Bool) -> [(SocketRecord, UInt64)]? {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return nil }
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / fdSize + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
        guard got > 0 else { return nil }

        var out: [(SocketRecord, UInt64)] = []
        let siSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, siSize) == siSize else { continue }
            let psi = si.psi
            guard psi.soi_family == AF_INET || psi.soi_family == AF_INET6 else { continue }

            if psi.soi_kind == Int32(SOCKINFO_TCP) {
                let tcp = psi.soi_proto.pri_tcp
                let ini = tcp.tcpsi_ini
                let state = TCPState(rawValue: Int(tcp.tcpsi_state)) ?? .unknown
                guard state == .listen || state == .established else { continue }
                let local = NetEndpoint(address: address(ini, local: true), port: port(ini.insi_lport))
                let remote = state == .listen
                    ? nil
                    : NetEndpoint(address: address(ini, local: false), port: port(ini.insi_fport))
                out.append((SocketRecord(pid: pid, proto: .tcp, local: local, remote: remote, state: state), psi.soi_so))
            } else if includeUDP, psi.soi_kind == Int32(SOCKINFO_IN), psi.soi_protocol == IPPROTO_UDP {
                let ini = psi.soi_proto.pri_in
                let lport = port(ini.insi_lport)
                guard lport != 0 else { continue }
                let fport = port(ini.insi_fport)
                let local = NetEndpoint(address: address(ini, local: true), port: lport)
                let remote = fport == 0 ? nil : NetEndpoint(address: address(ini, local: false), port: fport)
                out.append((SocketRecord(pid: pid, proto: .udp, local: local, remote: remote, state: .unknown), psi.soi_so))
            }
        }
        return out
    }

    private static func port(_ raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    private static func address(_ ini: in_sockinfo, local: Bool) -> String {
        // laddr и faddr — разные безымянные union-типы, поэтому без общего выражения.
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var v4 = local ? ini.insi_laddr.ina_46.i46a_addr4 : ini.insi_faddr.ina_46.i46a_addr4
            if v4.s_addr == 0 { return "*" }
            return ntop(AF_INET, &v4)
        }
        var v6 = local ? ini.insi_laddr.ina_6 : ini.insi_faddr.ina_6
        let isZero = withUnsafeBytes(of: &v6) { $0.allSatisfy { $0 == 0 } }
        if isZero { return "*" }
        let s = ntop(AF_INET6, &v6)
        if s.hasPrefix("::ffff:"), s.contains(".") { return String(s.dropFirst(7)) }
        return s
    }

    static func ntop<T>(_ family: Int32, _ addr: inout T) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        let ok = withUnsafePointer(to: &addr) { ptr in
            inet_ntop(family, UnsafeRawPointer(ptr), &buf, socklen_t(buf.count)) != nil
        }
        return ok ? String(cString: buf) : "?"
    }

    // MARK: Подробности о процессе

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 { return Int(value) }
        return 262_144
    }()

    /// Аргументы командной строки (только для своих процессов).
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buf = [UInt8](repeating: 0, count: argMax)
        var size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    /// Разбор KERN_PROCARGS2: argc, путь к файлу, выравнивающие нули, затем argv.
    static func parseProcArgs(_ buf: [UInt8]) -> [String]? {
        guard buf.count > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 }
        while i < buf.count, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < buf.count {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// Текущая папка процесса (только для своих процессов).
    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let s = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return s.isEmpty ? nil : s
    }

    /// Память и суммарное процессорное время в наносекундах.
    static func taskInfo(_ pid: pid_t) -> (rss: UInt64, cpuNs: UInt64)? {
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { return nil }
        let ticks = ti.pti_total_user &+ ti.pti_total_system
        return (ti.pti_resident_size, ticks &* timebase.numer / timebase.denom)
    }

    private static var userNames: [uid_t: String] = [:]
    private static let userLock = NSLock()

    static func userName(_ uid: uid_t) -> String {
        userLock.lock(); defer { userLock.unlock() }
        if let n = userNames[uid] { return n }
        let name: String
        if let pw = getpwuid(uid) { name = String(cString: pw.pointee.pw_name) } else { name = "uid \(uid)" }
        userNames[uid] = name
        return name
    }

    /// Адреса этого Mac — соединение на них тоже «локальное».
    static func localAddresses() -> Set<String> {
        var set: Set<String> = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return set }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            if let sa = cur.pointee.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    var s = String(cString: host)
                    if let i = s.firstIndex(of: "%") { s = String(s[..<i]) }
                    set.insert(s)
                }
            }
            cursor = cur.pointee.ifa_next
        }
        return set
    }
}
