import XCTest
@testable import Portovik

final class ParsingTests: XCTestCase {
    func testNetstatListenAndEstablished() {
        let text = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
        tcp4       0      0  127.0.0.1.10808        127.0.0.1.61578        ESTABLISHED       136970         3894  340160  146988           proxyd:693    00102 00000204 0000000000f6a875 00000080 01002800      2      0 000000
        tcp4       0      0  *.8090                 *.*                    LISTEN                 0            0  131072  131072 My Cool Server H:77716  00100 00000106 0000000000f61926 00000001 00000800      1      0 000000
        tcp6       0      0  ::1.5432               *.*                    LISTEN                 0            0  131072  131072         postgres:1449   00100 00000106 0000000000f61926 00000001 00000800      1      0 000000
        tcp4       0      0  127.0.0.1.52000        127.0.0.1.8080         TIME_WAIT              0            0  131072  131072                ?:0      00100 00000106 0000000000f61926 00000001 00000800      1      0 000000
        udp4       0      0  *.5353                 *.*                                        1120           99  786896    9216              adb:33736  00100 00000204 0000000000f6adfd 00000001 04000800      1      0 000002
        """
        let recs = Netstat.parse(text)
        XCTAssertEqual(recs.count, 4, "TIME_WAIT отбрасываем")

        let est = recs[0]
        XCTAssertEqual(est.pid, 693)
        XCTAssertEqual(est.state, .established)
        XCTAssertEqual(est.local, NetEndpoint(address: "127.0.0.1", port: 10808))
        XCTAssertEqual(est.remote, NetEndpoint(address: "127.0.0.1", port: 61578))
        XCTAssertEqual(est.rx, 136970)
        XCTAssertEqual(est.tx, 3894)

        let spaced = recs[1]
        XCTAssertEqual(spaced.pid, 77716, "имя процесса с пробелами не ломает разбор")
        XCTAssertTrue(spaced.isListener)
        XCTAssertEqual(spaced.local.address, "*")
        XCTAssertNil(spaced.remote)

        XCTAssertEqual(recs[2].local, NetEndpoint(address: "::1", port: 5432))

        let udp = recs[3]
        XCTAssertEqual(udp.proto, .udp)
        XCTAssertEqual(udp.pid, 33736)
        XCTAssertTrue(udp.isListener)
    }

    func testSplitEndpoint() {
        XCTAssertEqual(Netstat.splitEndpoint("127.0.0.1.8080").0, "127.0.0.1")
        XCTAssertEqual(Netstat.splitEndpoint("127.0.0.1.8080").1, 8080)
        XCTAssertEqual(Netstat.splitEndpoint("*.*").1, nil)
        XCTAssertEqual(Netstat.splitEndpoint("fe80::1%lo0.5432").0, "fe80::1")
        XCTAssertEqual(Netstat.splitEndpoint("::ffff:127.0.0.1.80").0, "127.0.0.1")
    }

    func testLaunchctlList() {
        let jobs = Launchd.parse("PID\tStatus\tLabel\n-\t0\tcom.apple.x\n1449\t0\thomebrew.mxcl.postgresql@14\n")
        XCTAssertEqual(jobs, [1449: "homebrew.mxcl.postgresql@14"])
    }

    func testProcNetTCP() throws {
        // Настоящий вывод из контейнера web: слушает 80 и 8000, встроенный DNS на 127.0.0.11,
        // ходит в db (172.26.0.2:5432) и на Mac (192.168.65.254:5101).
        let text = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 96189 1
           1: 0B00007F:9DE5 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 105055 1
           2: 00000000:1F40 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 96198 1
           3: 03001AAC:81CA 02001AAC:1538 01 00000000:00000000 00:00000000 00000000     0        0 96196 1
           4: 03001AAC:CB14 FE41A8C0:13ED 01 00000000:00000000 00:00000000 00000000     0        0 96197 1
           5: 03001AAC:0050 01001AAC:D0F2 01 00000000:00000000 00:00000000 00000000     0        0 96197 1
           6: 0100007F:9E16 0100007F:1F40 01 00000000:00000000 03:00000718 00000000     0        0 0 3
        """
        let net = try XCTUnwrap(ProcNetTCP.parse(text))
        XCTAssertEqual(net.listening, [80, 8000], "127.0.0.11 (DNS Docker) не считаем")
        XCTAssertEqual(net.outbound, [
            NetEndpoint(address: "172.26.0.2", port: 5432),
            NetEndpoint(address: "192.168.65.254", port: 5101),
        ], "входящие на свои порты и loopback не считаются исходящими")
        XCTAssertNil(ProcNetTCP.parse("OCI runtime exec failed: \"cat\": executable file not found"))
    }

    func testProcNetTCP6Mapped() {
        let e = ProcNetTCP.endpoint("0000000000000000FFFF000002001AAC:1538")
        XCTAssertEqual(e, NetEndpoint(address: "172.26.0.2", port: 5432))
        let loop6 = ProcNetTCP.endpoint("00000000000000000000000001000000:0050")
        XCTAssertEqual(loop6, NetEndpoint(address: "::1", port: 80))
    }

    func testDockerDemuxAndChunked() throws {
        var framed = Data([1, 0, 0, 0, 0, 0, 0, 5])
        framed.append(Data("hello".utf8))
        framed.append(Data([2, 0, 0, 0, 0, 0, 0, 1]))
        framed.append(Data("!".utf8))
        XCTAssertEqual(String(decoding: DockerClient.demux(framed), as: UTF8.self), "hello!")
        XCTAssertEqual(DockerClient.demux(Data("plain".utf8)), Data("plain".utf8))

        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n4\r\n[1,2\r\n2\r\n,3\r\n1\r\n]\r\n0\r\n\r\n".utf8)
        let r = try DockerClient.parseResponse(raw)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "[1,2,3]")
    }

    func testDockerContainerParsing() throws {
        let json = """
        {"Id":"52cb1af89052","Names":["/shop-web-1"],"Image":"timescale/timescaledb:latest-pg15@sha256:abc",
         "Command":"/docker-entrypoint.sh","Created":1791877337,"State":"running","Status":"Up 2 minutes (healthy)",
         "Ports":[{"IP":"127.0.0.1","PrivatePort":80,"PublicPort":8081,"Type":"tcp"},{"IP":"::1","PrivatePort":80,"PublicPort":8081,"Type":"tcp"},
                  {"IP":"","PrivatePort":5432,"Type":"tcp"}],
         "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web",
                   "com.docker.compose.project.working_dir":"/Users/x/shop"},
         "NetworkSettings":{"Networks":{"shop_default":{"IPAddress":"172.26.0.3","Gateway":"172.26.0.1"}}}}
        """
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let c = try XCTUnwrap(DockerClient.parseContainer(obj))
        XCTAssertEqual(c.name, "shop-web-1")
        XCTAssertEqual(c.image, "timescale/timescaledb:latest-pg15")
        XCTAssertEqual(c.health, "healthy")
        XCTAssertEqual(c.ports.count, 2, "IPv4 и IPv6 одного порта склеиваются")
        XCTAssertEqual(c.ports[0].ips, ["127.0.0.1", "::1"])
        XCTAssertEqual(c.ports[0].publicPort, 8081)
        XCTAssertNil(c.ports[1].publicPort)
        XCTAssertEqual(c.composeProject, "shop")
        XCTAssertEqual(c.networks.first?.ip, "172.26.0.3")
    }

    func testProcArgs() {
        var buf: [UInt8] = [3, 0, 0, 0]
        func add(_ s: String, zeros: Int = 1) {
            buf.append(contentsOf: Array(s.utf8))
            buf.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        }
        add("/usr/local/bin/node", zeros: 4)
        add("node")
        add("--import")
        add("tsx")
        add("PATH=/usr/bin")
        XCTAssertEqual(ProcessInspector.parseProcArgs(buf), ["node", "--import", "tsx"])
    }

    func testClassifier() {
        XCTAssertEqual(Classifier.appBundle(for: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"), "/Applications/Docker.app")
        XCTAssertEqual(Classifier.appBundle(for: "/Applications/Antigravity.app/Contents/Frameworks/X.framework/Helpers/H.app/Contents/MacOS/H"),
                       "/Applications/Antigravity.app")
        XCTAssertNil(Classifier.appBundle(for: "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"))
        XCTAssertNil(Classifier.appBundle(for: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"))

        let tsx = Classifier.flavor(exe: "node", args: ["node", "--import", "tsx", "src/server/main.ts", "--config", "x.json"], bundle: nil)
        XCTAssertEqual(tsx.title, "main.ts")
        XCTAssertEqual(tsx.detail, "tsx · Node.js")

        let vite = Classifier.flavor(exe: "node", args: ["node", "/p/node_modules/.bin/vite", "--port", "5173"], bundle: nil)
        XCTAssertEqual(vite.title, "Vite")

        let http = Classifier.flavor(exe: "Python", args: ["python3", "-m", "http.server", "8765"], bundle: nil)
        XCTAssertEqual(http.title, "Python http.server")

        let django = Classifier.flavor(exe: "python3.12", args: ["python", "manage.py", "runserver"], bundle: nil)
        XCTAssertEqual(django.title, "Django")

        let pg = Classifier.flavor(exe: "postgres", args: ["postgres", "-D", "/opt/homebrew/var/postgresql@14"], bundle: nil)
        XCTAssertEqual(pg.title, "PostgreSQL")

        XCTAssertTrue(Classifier.isSystem(path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", uid: 501))
        XCTAssertFalse(Classifier.isSystem(path: "/usr/bin/ruby", uid: 501))
    }

    func testProjectRootIgnoresHomebrew() {
        XCTAssertNil(Classifier.projectRoot(for: "/opt/homebrew/var/postgresql@14"))
        XCTAssertNil(Classifier.projectRoot(for: "/"))
        XCTAssertNil(Classifier.projectRoot(for: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testPlural() {
        XCTAssertEqual(plural(1, "порт", "порта", "портов"), "порт")
        XCTAssertEqual(plural(3, "порт", "порта", "портов"), "порта")
        XCTAssertEqual(plural(11, "порт", "порта", "портов"), "портов")
        XCTAssertEqual(plural(22, "порт", "порта", "портов"), "порта")
        XCTAssertEqual(plural(35, "порт", "порта", "портов"), "портов")
    }
}
