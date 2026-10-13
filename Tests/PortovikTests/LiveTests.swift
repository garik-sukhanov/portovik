import Darwin
import XCTest
@testable import Portovik

/// Живые проверки на этом Mac: настоящий сервер, настоящий клиент, настоящий kill.
final class LiveTests: XCTestCase {
    private func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func spawn(_ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    private func waitFor(_ timeout: TimeInterval = 8, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    func testServerClientLinkAndKill() async throws {
        let port = freePort()
        let server = try spawn(["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"])
        defer { if server.isRunning { server.terminate() } }

        let scanner = Scanner()
        var snap = Snapshot()
        let opt = ScanOptions(includeUDP: false, dockerDeepScan: false, linkMemory: 0)
        let listening = await waitFor {
            snap = await scanner.scan(opt)
            return snap.entities["p:\(server.processIdentifier)"] != nil
        }
        XCTAssertTrue(listening, "сервер появился в снимке")

        // Клиент подключается и молчит 30 секунд — http.server ждёт запрос, соединение остаётся открытым.
        let client = try spawn(["python3", "-c",
            "import socket,time; s=socket.create_connection(('127.0.0.1',\(port))); time.sleep(30)"])
        defer { if client.isRunning { client.terminate() } }
        let found = await waitFor {
            snap = await scanner.scan(opt)
            return snap.links.contains { $0.to == "p:\(server.processIdentifier)" && $0.port == port }
        }
        XCTAssertTrue(found, "сервер и связь клиента появились в снимке")
        if !found {
            for e in snap.entities.values where e.ports.contains(where: { $0.port == port }) || e.pids.contains(client.processIdentifier) {
                print("DEBUG entity", e.id, e.title, e.ports.map(\.port), e.pids)
            }
            for l in snap.links where l.port == port { print("DEBUG link", l) }
            print("DEBUG server pid", server.processIdentifier, "client pid", client.processIdentifier)
        }

        let e = try XCTUnwrap(snap.entities["p:\(server.processIdentifier)"])
        XCTAssertEqual(e.ports.map(\.port), [port])
        XCTAssertEqual(e.ports.first?.scope, .loopback)
        XCTAssertEqual(e.title, "Python http.server")
        let link = try XCTUnwrap(snap.links.first { $0.to == e.id })
        XCTAssertEqual(link.from, "p:\(client.processIdentifier)")
        XCTAssertEqual(link.kind, .local)
        XCTAssertNotNil(snap.processes[server.processIdentifier]?.commandLine)
        XCTAssertFalse(snap.ancestors(of: server.processIdentifier).isEmpty, "видна цепочка родителей")

        // Завершаем так же, как кнопка «Завершить»: SIGTERM и ждём, пока порт освободится.
        XCTAssertEqual(kill(server.processIdentifier, SIGTERM), 0)
        let gone = await waitFor {
            snap = await scanner.scan(opt)
            return !snap.entities.values.contains { $0.ports.contains { $0.port == port } }
        }
        XCTAssertTrue(gone, "после завершения порт свободен")
        XCTAssertEqual(VisibleModel.build(snap, .init(search: String(port))).freePort, port)
    }

    /// Docker: временный контейнер из локального образа, остановка через API, как кнопкой «Остановить».
    /// Запуск: PORTOVIK_DOCKER_IMAGE=caddy:2-alpine swift test --filter testDocker
    func testDockerContainerLifecycle() async throws {
        guard let image = ProcessInfo.processInfo.environment["PORTOVIK_DOCKER_IMAGE"] else {
            throw XCTSkip("задайте PORTOVIK_DOCKER_IMAGE с уже скачанным образом")
        }
        let docker = DockerClient()
        let port = freePort()
        let name = "portovik-test-\(port)"
        let create = try docker.request("POST", "/containers/create?name=\(name)", json: [
            "Image": image,
            "ExposedPorts": ["80/tcp": [String: String]()],
            "HostConfig": ["PortBindings": ["80/tcp": [["HostIp": "127.0.0.1", "HostPort": String(port)]]], "AutoRemove": true],
        ])
        XCTAssertEqual(create.status, 201, String(decoding: create.body, as: UTF8.self))
        defer { _ = try? docker.request("DELETE", "/containers/\(name)?force=1") }
        try docker.start(name)

        let scanner = Scanner()
        var snap = Snapshot()
        let opt = ScanOptions(includeUDP: false, dockerDeepScan: true, linkMemory: 0)
        let seen = await waitFor(20) {
            snap = await scanner.scan(opt)
            return snap.entities.values.contains { $0.kind == .container && $0.ports.contains { $0.port == port && $0.innerPort == 80 } }
        }
        XCTAssertTrue(seen, "опубликованный порт контейнера виден и приписан контейнеру")
        let owners = snap.entities.values.filter { $0.ports.contains { $0.port == port && !$0.internalOnly } }
        XCTAssertEqual(owners.count, 1, "порт не дублируется у движка Docker")
        XCTAssertEqual(owners.first?.groupID, "docker")

        try docker.stop(name)
        let stopped = await waitFor(20) {
            snap = await scanner.scan(opt)
            return !snap.entities.values.contains { $0.ports.contains { $0.port == port && !$0.internalOnly } }
        }
        XCTAssertTrue(stopped, "после остановки порт свободен")
    }
}
