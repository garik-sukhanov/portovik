import CoreGraphics
import Foundation

enum GraphMetrics {
    static let cardWidth: CGFloat = 258
    static let headerHeight: CGFloat = 38
    static let rowHeight: CGFloat = 50
    static let padding: CGFloat = 6
    static let colGap: CGFloat = 170
    static let rowGap: CGFloat = 26
    static let componentGap: CGFloat = 60
    static let isolatedGap: CGFloat = 36
    static let margin: CGFloat = 72
}

/// Раскладка схемы. Связанные группы — слоями слева направо (клиенты → серверы),
/// группы без связей — плиткой ниже.
struct GraphLayout {
    var cards: [String: CGRect] = [:]          // id группы → рамка карточки
    var rowOffset: [String: CGFloat] = [:]     // id сущности → смещение её строки от верха карточки
    var entityGroup: [String: String] = [:]
    var headers: Set<String> = []
    var size: CGSize = CGSize(width: 400, height: 300)

    static func showsHeader(_ vg: VisibleGroup) -> Bool {
        vg.group.kind.isMeaningful || vg.entities.count > 1
    }

    static func height(_ vg: VisibleGroup) -> CGFloat {
        (showsHeader(vg) ? GraphMetrics.headerHeight : 0) + GraphMetrics.padding * 2
            + GraphMetrics.rowHeight * CGFloat(vg.entities.count)
    }

    /// Меняется только при изменении состава — тогда и перестраиваем раскладку.
    static func signature(_ m: VisibleModel) -> String {
        let g = m.groups.map { $0.id + ":" + $0.entities.map(\.id).joined(separator: ",") }.joined(separator: "|")
        let l = Set(m.links.map { "\($0.from)>\($0.to)" }).sorted().joined(separator: "|")
        return g + "#" + l
    }

    static func compute(_ model: VisibleModel) -> GraphLayout {
        typealias M = GraphMetrics
        var L = GraphLayout()
        let groups = model.groups
        guard !groups.isEmpty else { return L }

        var index: [String: Int] = [:]
        for (i, g) in groups.enumerated() {
            index[g.id] = i
            let header = showsHeader(g)
            if header { L.headers.insert(g.id) }
            for (j, e) in g.entities.enumerated() {
                L.entityGroup[e.id] = g.id
                L.rowOffset[e.id] = (header ? M.headerHeight : 0) + M.padding + CGFloat(j) * M.rowHeight
            }
        }

        let n = groups.count
        var succ = [Set<Int>](repeating: [], count: n)
        var pred = [Set<Int>](repeating: [], count: n)
        for l in model.links {
            guard let ga = L.entityGroup[l.from], let gb = L.entityGroup[l.to],
                  let a = index[ga], let b = index[gb], a != b else { continue }
            succ[a].insert(b)
            pred[b].insert(a)
        }

        // Компоненты связности (без учёта направления).
        var comp = [Int](repeating: -1, count: n)
        var comps: [[Int]] = []
        for s in 0..<n where comp[s] < 0 {
            var stack = [s]
            comp[s] = comps.count
            var members: [Int] = []
            while let v = stack.popLast() {
                members.append(v)
                for w in succ[v].union(pred[v]) where comp[w] < 0 {
                    comp[w] = comps.count
                    stack.append(w)
                }
            }
            comps.append(members.sorted())
        }
        let connected = comps.filter { $0.count > 1 }.sorted { $0.count > $1.count }
        let isolated = comps.filter { $0.count == 1 }.map { $0[0] }

        var y = M.margin
        var maxX = M.margin + M.cardWidth

        for members in connected {
            let memberSet = Set(members)

            // Разрываем циклы: обратные рёбра обхода в глубину не участвуют в расслоении.
            var dag: [Int: [Int]] = [:]
            var state: [Int: Int] = [:]
            func dfs(_ v: Int) {
                state[v] = 1
                for w in succ[v].sorted() where memberSet.contains(w) {
                    if state[w] == 1 { continue }
                    dag[v, default: []].append(w)
                    if state[w] == nil { dfs(w) }
                }
                state[v] = 2
            }
            for r in members.filter({ pred[$0].isEmpty }) + members where state[r] == nil { dfs(r) }

            // Слой = длина самого длинного пути от источника.
            var indeg: [Int: Int] = [:]
            for v in members { indeg[v] = 0 }
            for ws in dag.values { for w in ws { indeg[w, default: 0] += 1 } }
            var layer: [Int: Int] = [:]
            var queue = members.filter { indeg[$0] == 0 }
            for v in queue { layer[v] = 0 }
            var qi = 0
            while qi < queue.count {
                let v = queue[qi]; qi += 1
                for w in dag[v] ?? [] {
                    layer[w] = max(layer[w] ?? 0, (layer[v] ?? 0) + 1)
                    indeg[w]! -= 1
                    if indeg[w] == 0 { queue.append(w) }
                }
            }
            // Источники подтягиваем вплотную к тем, к кому они подключаются.
            for v in members where pred[v].isDisjoint(with: memberSet) {
                let s = (dag[v] ?? []).compactMap { layer[$0] }
                if let mn = s.min(), mn - 1 > (layer[v] ?? 0) { layer[v] = mn - 1 }
            }

            let maxLayer = layer.values.max() ?? 0
            var columns = [[Int]](repeating: [], count: maxLayer + 1)
            for v in members { columns[layer[v] ?? 0].append(v) }

            // Порядок внутри столбцов — метод барицентров, чтобы линии меньше пересекались.
            var pos: [Int: Double] = [:]
            func updatePos() {
                for col in columns {
                    let c = Double(max(col.count - 1, 1))
                    for (i, v) in col.enumerated() { pos[v] = col.count == 1 ? 0.5 : Double(i) / c }
                }
            }
            func bary(_ v: Int, _ ns: Set<Int>) -> Double {
                let vals = ns.filter(memberSet.contains).compactMap { pos[$0] }
                return vals.isEmpty ? (pos[v] ?? 0) : vals.reduce(0, +) / Double(vals.count)
            }
            updatePos()
            if columns.count > 1 {
                for _ in 0..<6 {
                    for c in 1..<columns.count {
                        columns[c].sort { bary($0, pred[$0]) < bary($1, pred[$1]) }
                        updatePos()
                    }
                    for c in stride(from: columns.count - 2, through: 0, by: -1) {
                        columns[c].sort { bary($0, succ[$0]) < bary($1, succ[$1]) }
                        updatePos()
                    }
                }
            }

            let colHeights = columns.map { col in
                col.map { height(groups[$0]) }.reduce(0, +) + M.rowGap * CGFloat(max(0, col.count - 1))
            }
            let compH = colHeights.max() ?? 0
            for (c, col) in columns.enumerated() {
                var cy = y + (compH - colHeights[c]) / 2
                let x = M.margin + CGFloat(c) * (M.cardWidth + M.colGap)
                for v in col {
                    let h = height(groups[v])
                    L.cards[groups[v].id] = CGRect(x: x, y: cy, width: M.cardWidth, height: h)
                    cy += h + M.rowGap
                }
                maxX = max(maxX, x + M.cardWidth)
            }
            y += compH + M.componentGap
        }

        if !isolated.isEmpty {
            let gap = M.isolatedGap
            let available = max(maxX - M.margin, 4 * M.cardWidth + 3 * gap)
            let cols = max(1, Int((available + gap) / (M.cardWidth + gap)))
            var colY = [CGFloat](repeating: y, count: cols)
            for v in isolated {
                let h = height(groups[v])
                let c = colY.indices.min { colY[$0] < colY[$1] } ?? 0
                let x = M.margin + CGFloat(c) * (M.cardWidth + gap)
                L.cards[groups[v].id] = CGRect(x: x, y: colY[c], width: M.cardWidth, height: h)
                colY[c] += h + M.rowGap
                maxX = max(maxX, x + M.cardWidth)
            }
            y = (colY.max() ?? y) - M.rowGap + M.componentGap
        }

        L.size = CGSize(width: maxX + M.margin, height: max(y - M.componentGap + M.margin, 300))
        return L
    }
}
