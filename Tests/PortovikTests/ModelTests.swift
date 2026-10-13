import XCTest
@testable import Portovik

final class ModelTests: XCTestCase {
    private func entity(_ id: String, _ group: String, ports: [UInt16] = [], kind: EntityKind = .process) -> Entity {
        var e = Entity(id: id, kind: kind, title: id, subtitle: "", icon: .symbol("terminal", -1),
                       ports: ports.map { PortBinding(proto: .tcp, port: $0, addresses: ["127.0.0.1"], scope: .loopback) })
        e.groupID = group
        return e
    }

    /// chrome → web(3000) → db(5432); отдельно стоящий redis.
    private func sampleSnapshot() -> Snapshot {
        var s = Snapshot()
        let ents = [
            entity("a:chrome", "app:chrome", kind: .appClients),
            entity("p:1", "project:web", ports: [3000]),
            entity("c:db", "compose:x", ports: [5432], kind: .container),
            entity("p:2", "single:2", ports: [6379]),
        ]
        for e in ents { s.entities[e.id] = e }
        s.groups = [
            EntityGroup(id: "compose:x", kind: .compose, title: "x", icon: .symbol("x", 0), entityIDs: ["c:db"]),
            EntityGroup(id: "project:web", kind: .project, title: "web", icon: .symbol("x", 0), entityIDs: ["p:1"]),
            EntityGroup(id: "app:chrome", kind: .app, title: "Chrome", icon: .symbol("x", 0), entityIDs: ["a:chrome"]),
            EntityGroup(id: "single:2", kind: .single, title: "redis", icon: .symbol("x", 0), entityIDs: ["p:2"]),
        ]
        s.links = [
            Link(from: "a:chrome", to: "p:1", port: 3000, kind: .local, connections: 2),
            Link(from: "p:1", to: "c:db", port: 5432, kind: .toContainer, connections: 1),
        ]
        s.scanned = true
        return s
    }

    func testSearchByPortAndFreePort() {
        let s = sampleSnapshot()
        let m = VisibleModel.build(s, .init(search: "543", showClients: false))
        XCTAssertEqual(m.groups.flatMap { $0.entities.map(\.id) }, ["c:db"])
        XCTAssertEqual(m.freePort, 543, "сам порт 543 свободен, хотя 5432 занят")

        let free = VisibleModel.build(s, .init(search: ":8080"))
        XCTAssertTrue(free.groups.isEmpty)
        XCTAssertEqual(free.freePort, 8080)

        let busy = VisibleModel.build(s, .init(search: "3000"))
        XCTAssertNil(busy.freePort)
    }

    func testNeighborsOnGraphSearch() {
        let s = sampleSnapshot()
        let m = VisibleModel.build(s, .init(search: "3000", showClients: true, includeNeighbors: true))
        let ids = Set(m.groups.flatMap { $0.entities.map(\.id) })
        XCTAssertEqual(ids, ["a:chrome", "p:1", "c:db"], "на схеме поиск показывает и соседей по связям")
        XCTAssertEqual(m.links.count, 2)
    }

    func testClientsHiddenInList() {
        let s = sampleSnapshot()
        let m = VisibleModel.build(s, .init(showClients: false))
        XCTAssertFalse(m.groups.contains { $0.id == "app:chrome" })
        XCTAssertEqual(m.portCount, 3)
    }

    func testGraphLayoutLayersAndNoOverlap() {
        let s = sampleSnapshot()
        let m = VisibleModel.build(s, .init(showClients: true))
        let L = GraphLayout.compute(m)
        let chrome = L.cards["app:chrome"]!, web = L.cards["project:web"]!, db = L.cards["compose:x"]!
        XCTAssertLessThan(chrome.minX, web.minX, "клиент левее сервера")
        XCTAssertLessThan(web.minX, db.minX, "web левее базы, к которой подключается")
        let rects = Array(L.cards.values)
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(rects[i].intersects(rects[j]), "карточки не перекрываются")
            }
        }
        // Отдельный redis уходит в плитку ниже связанной части.
        XCTAssertGreaterThan(L.cards["single:2"]!.minY, max(chrome.maxY, web.maxY, db.maxY))
        XCTAssertTrue(L.headers.contains("compose:x"))
        XCTAssertFalse(L.headers.contains("single:2"))
    }

    func testGraphLayoutSurvivesCycles() {
        var s = sampleSnapshot()
        s.links.append(Link(from: "c:db", to: "a:chrome", port: 1, kind: .fromContainer, connections: 1))
        let L = GraphLayout.compute(VisibleModel.build(s, .init(showClients: true)))
        XCTAssertEqual(L.cards.count, 4)
    }

    func testPortChipLabel() {
        let pub = PortBinding(proto: .tcp, port: 8081, addresses: ["127.0.0.1"], scope: .loopback, innerPort: 80)
        XCTAssertEqual(pub.label, "8081→80")
        let same = PortBinding(proto: .tcp, port: 80, addresses: ["*"], scope: .any, innerPort: 80)
        XCTAssertEqual(same.label, "80")
        XCTAssertEqual(BindScope(address: "0.0.0.0"), .any)
        XCTAssertEqual(BindScope(address: "::1"), .loopback)
        XCTAssertEqual(BindScope(address: "192.168.1.5"), .specific)
    }
}
