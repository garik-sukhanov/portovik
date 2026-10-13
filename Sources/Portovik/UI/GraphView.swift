import SwiftUI

/// Вид «Схема»: карточки групп и стрелки соединений «клиент → порт сервера».
struct GraphView: View {
    let model: VisibleModel
    let snapshot: Snapshot
    @Binding var selection: String?
    @Environment(Monitor.self) private var monitor

    @State private var layout = GraphLayout()
    @State private var signature = ""
    @State private var offsets: [String: CGSize] = [:]
    @State private var dragging: DragState?
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @AppStorage("graphLegend") private var showLegend = false

    private struct DragState { var id: String; var delta: CGSize }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                canvas
                    .frame(width: max(layout.size.width * zoom, geo.size.width),
                           height: max(layout.size.height * zoom, geo.size.height),
                           alignment: .topLeading)
            }
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if pinchBase == nil { pinchBase = zoom }
                        zoom = clampZoom((pinchBase ?? 1) * v.magnification)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .overlay(alignment: .bottomTrailing) { controls(viewport: geo.size) }
            .overlay(alignment: .bottomLeading) { legend }
            .overlay {
                if model.groups.isEmpty {
                    ContentUnavailableView(model.query.isEmpty ? "Нечего показать" : "Ничего не найдено",
                                           systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text(model.query.isEmpty ? "Ни одно приложение не слушает порты." : "Попробуйте другой запрос."))
                }
            }
        }
        .onAppear { relayout(force: true) }
        .onChange(of: GraphLayout.signature(model)) { relayout() }
    }

    // MARK: Холст

    /// Три слоя одного масштаба: фон и статичные линии, бегущий пунктир (Core Animation), карточки.
    private var canvas: some View {
        let rows = rowRects()
        let focus = focusSet()
        let painter = EdgePainter(links: model.links, rows: rows, focus: focus)
        let geometry = painter.geometry()
        return ZStack(alignment: .topLeading) {
            scaled(
                ZStack(alignment: .topLeading) {
                    DotGrid()
                        .contentShape(Rectangle())
                        .onTapGesture { selection = nil }
                    Canvas { ctx, _ in painter.draw(geometry, in: &ctx) }
                        .allowsHitTesting(false)
                }
            )

            FlowLayer(items: painter.flowItems(geometry, scale: zoom))
                .frame(width: layout.size.width * zoom, height: layout.size.height * zoom)
                .allowsHitTesting(false)

            scaled(
                ZStack(alignment: .topLeading) {
                    ForEach(model.groups) { vg in
                        let r = cardRect(vg.id)
                        GraphCard(vg: vg, header: layout.headers.contains(vg.id), selection: $selection, focus: focus)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .gesture(
                                DragGesture(minimumDistance: 4, coordinateSpace: .named("graph"))
                                    .onChanged { v in dragging = DragState(id: vg.id, delta: v.translation) }
                                    .onEnded { v in
                                        var o = offsets[vg.id] ?? .zero
                                        o.width += v.translation.width
                                        o.height += v.translation.height
                                        offsets[vg.id] = o
                                        dragging = nil
                                    }
                            )
                    }
                }
                .coordinateSpace(.named("graph"))
            )
        }
    }

    private func scaled<V: View>(_ content: V) -> some View {
        content
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: layout.size.width * zoom, height: layout.size.height * zoom, alignment: .topLeading)
    }

    private func cardRect(_ gid: String) -> CGRect {
        var r = layout.cards[gid] ?? CGRect(x: -1000, y: -1000, width: GraphMetrics.cardWidth, height: 60)
        if let o = offsets[gid] { r = r.offsetBy(dx: o.width, dy: o.height) }
        if let d = dragging, d.id == gid { r = r.offsetBy(dx: d.delta.width, dy: d.delta.height) }
        return r
    }

    private func rowRects() -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for vg in model.groups {
            let card = cardRect(vg.id)
            for e in vg.entities {
                guard let off = layout.rowOffset[e.id] else { continue }
                out[e.id] = CGRect(x: card.minX, y: card.minY + off, width: card.width, height: GraphMetrics.rowHeight)
            }
        }
        return out
    }

    /// Выделили что-то — подсвечиваем его и соседей, остальное приглушаем.
    private func focusSet() -> Set<String>? {
        guard let sel = selection else { return nil }
        var base: Set<String>
        if snapshot.entities[sel] != nil { base = [sel] }
        else if let g = model.groups.first(where: { $0.id == sel }) { base = Set(g.entities.map(\.id)) }
        else { return nil }
        var out = base
        for l in model.links where base.contains(l.from) || base.contains(l.to) {
            out.insert(l.from)
            out.insert(l.to)
        }
        return out
    }

    private func relayout(force: Bool = false) {
        let sig = GraphLayout.signature(model)
        guard force || sig != signature else { return }
        signature = sig
        let new = GraphLayout.compute(model)
        if force { layout = new } else { withAnimation(.easeInOut(duration: 0.35)) { layout = new } }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(2, max(0.25, z)) }

    // MARK: Панели

    private func controls(viewport: CGSize) -> some View {
        HStack(spacing: 4) {
            IconButton(symbol: "minus.magnifyingglass", help: "Уменьшить") { withAnimation { zoom = clampZoom(zoom / 1.2) } }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 40)
            IconButton(symbol: "plus.magnifyingglass", help: "Увеличить") { withAnimation { zoom = clampZoom(zoom * 1.2) } }
            Divider().frame(height: 14)
            IconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Вписать в окно") {
                let fit = min((viewport.width - 24) / layout.size.width, (viewport.height - 24) / layout.size.height)
                withAnimation { zoom = clampZoom(min(1, fit)) }
            }
            IconButton(symbol: "rectangle.3.group", help: "Разложить заново (сбросить перетаскивание)") {
                withAnimation(.easeInOut(duration: 0.35)) {
                    offsets = [:]
                    layout = GraphLayout.compute(model)
                }
            }
            Divider().frame(height: 14)
            IconButton(symbol: showLegend ? "info.circle.fill" : "info.circle", help: "Обозначения") { showLegend.toggle() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .padding(12)
    }

    @ViewBuilder private var legend: some View {
        if showLegend {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    legendLine(.local, "Mac → Mac")
                    legendLine(.toContainer, "Mac → контейнер")
                }
                HStack(spacing: 12) {
                    legendLine(.betweenContainers, "контейнер → контейнер")
                    legendLine(.fromContainer, "контейнер → Mac")
                }
                HStack(spacing: 10) {
                    legendDot(Palette.loopback, "только этот Mac")
                    legendDot(Palette.network, "виден из сети")
                    legendDot(Palette.internalPort, "внутри Docker")
                }
                Text("Бегущий пунктир — сейчас идёт обмен, бледный — связь была недавно.")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5))
            .fixedSize()
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .padding(12)
        }
    }

    private func legendLine(_ k: LinkKind, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(Palette.link(k)).frame(width: 22, height: 3)
            Text(text)
        }
    }

    private func legendDot(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

// MARK: - Карточка группы

private struct GraphCard: View {
    let vg: VisibleGroup
    let header: Bool
    @Binding var selection: String?
    let focus: Set<String>?
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let group = vg.group
        let groupSelected = selection == group.id
        VStack(spacing: 0) {
            if header {
                HStack(spacing: 7) {
                    EntityIcon(icon: group.icon, size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title).font(.system(size: 12, weight: .bold)).lineLimit(1)
                        if let s = group.subtitle {
                            Text(s).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    if let b = monitor.busy[group.id] {
                        ProgressView().controlSize(.mini).help(b)
                    }
                    if group.kind != .system {
                        Menu { GroupMenuItems(group: group) } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: GraphMetrics.headerHeight)
                .background(headerTint.opacity(0.10))
                .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5) }
                .contentShape(Rectangle())
                .onTapGesture { selection = group.id }
                .contextMenu { GroupMenuItems(group: group) }
            }
            VStack(spacing: 0) {
                ForEach(vg.entities) { e in
                    GraphRow(entity: e, selected: selection == e.id,
                             dimmed: focus.map { !$0.contains(e.id) } ?? false)
                        .onTapGesture { selection = e.id }
                        .contextMenu { EntityMenuItems(entity: e) }
                }
            }
            .padding(.vertical, GraphMetrics.padding)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(groupSelected ? Color.accentColor : Color.primary.opacity(0.13),
                              lineWidth: groupSelected ? 2 : 0.8)
        )
        .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
    }

    private var headerTint: Color {
        switch vg.group.kind {
        case .compose, .docker, .stoppedCompose: return Palette.docker
        case .project: return .accentColor
        case .system: return .gray
        default: return .primary
        }
    }
}

private struct GraphRow: View {
    let entity: Entity
    let selected: Bool
    let dimmed: Bool
    @Environment(Monitor.self) private var monitor
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            EntityIcon(icon: entity.icon, size: 26)
                .opacity(entity.isRunning ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(entity.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(monitor.busy[entity.id] ?? subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let h = entity.health { HealthDot(health: h) }
            HStack(spacing: 3) {
                ForEach(entity.ports.prefix(2)) { PortChip(binding: $0, compact: true) }
                if entity.ports.count > 2 {
                    Text("+\(entity.ports.count - 2)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: GraphMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : hover ? Color.primary.opacity(0.05) : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.35 : 1)
        .onHover { hover = $0 }
        .help(helpText)
    }

    private var subtitle: String {
        if entity.isClientOnly { return entity.kind == .appClients ? "клиент" : (entity.subtitle.isEmpty ? "клиент" : entity.subtitle) }
        return entity.subtitle.isEmpty ? (entity.pid.map { "PID \($0)" } ?? "") : entity.subtitle
    }

    private var helpText: String {
        var s = entity.title
        if !entity.subtitle.isEmpty { s += " — " + entity.subtitle }
        if !entity.ports.isEmpty { s += "\nПорты: " + entity.ports.map(\.label).joined(separator: ", ") }
        return s
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            let color = Color.primary.opacity(0.10)
            var y: CGFloat = step
            while y < size.height {
                var x: CGFloat = step
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(color))
                    x += step
                }
                y += step
            }
        }
    }
}

// MARK: - Рёбра

/// Геометрия связей: из правого края строки клиента в «гнездо» с номером порта слева от сервера.
struct EdgePainter {
    let links: [Link]
    let rows: [String: CGRect]
    let focus: Set<String>?

    struct Edge {
        var link: Link
        var path: Path
        var end: CGPoint
        var mid: CGPoint
        var color: Color
        var width: CGFloat
        var dim: Bool
    }

    struct Tag {
        var rect: CGRect
        var port: UInt16
        var color: Color
        var live: Bool
        var dim: Bool
    }

    struct Geometry {
        var edges: [Edge] = []
        var tags: [Tag] = []
    }

    func geometry() -> Geometry {
        var targetPorts: [String: [UInt16]] = [:]
        for l in links where !(targetPorts[l.to]?.contains(l.port) ?? false) { targetPorts[l.to, default: []].append(l.port) }
        for k in targetPorts.keys { targetPorts[k]!.sort() }
        var sourceKeys: [String: [String]] = [:]
        for l in links {
            let key = "\(l.to):\(l.port)"
            if !(sourceKeys[l.from]?.contains(key) ?? false) { sourceKeys[l.from, default: []].append(key) }
        }

        func tagRect(_ to: String, _ port: UInt16) -> CGRect? {
            guard let row = rows[to], let ports = targetPorts[to], let i = ports.firstIndex(of: port) else { return nil }
            let y = row.minY + CGFloat(i + 1) * row.height / CGFloat(ports.count + 1)
            let w = CGFloat(String(port).count + 1) * 6.6 + 10
            return CGRect(x: row.minX - 6 - w, y: y - 8, width: w, height: 16)
        }

        var g = Geometry()
        var tagStyle: [String: (color: Color, live: Bool, dim: Bool)] = [:]
        for l in links {
            guard let src = rows[l.from], let tag = tagRect(l.to, l.port) else { continue }
            let keys = sourceKeys[l.from] ?? []
            let j = keys.firstIndex(of: "\(l.to):\(l.port)") ?? 0
            let sy = src.minY + CGFloat(j + 1) * src.height / CGFloat(keys.count + 1)
            let end = CGPoint(x: tag.minX - 1, y: tag.midY)
            let sameCard = abs(src.minX - (rows[l.to]?.minX ?? 0)) < 1 && end.x < src.maxX && end.x > src.minX - 60

            let start: CGPoint, c1: CGPoint, c2: CGPoint
            if sameCard {
                start = CGPoint(x: src.minX, y: sy)
                c1 = CGPoint(x: start.x - 56 - CGFloat(j) * 8, y: start.y)
                c2 = CGPoint(x: end.x - 40, y: end.y)
            } else {
                start = CGPoint(x: src.maxX, y: sy)
                let dx = max(start.x < end.x ? 50 : 90, abs(end.x - start.x) * 0.45)
                c1 = CGPoint(x: start.x + dx, y: start.y)
                c2 = CGPoint(x: end.x - dx, y: end.y)
            }
            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
            let mid = CGPoint(x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8,
                              y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8)

            let dim = focus.map { !($0.contains(l.from) && $0.contains(l.to)) } ?? false
            var alpha: Double = l.live ? 0.85 : 0.35
            if dim { alpha *= 0.12 }
            let width = l.live ? 1.4 + min(2.2, log2(Double(max(1, l.connections))) * 0.45) : 1.2
            g.edges.append(Edge(link: l, path: path, end: end, mid: mid,
                                color: Palette.link(l.kind).opacity(alpha), width: width, dim: dim))

            let key = "\(l.to):\(l.port)"
            let prev = tagStyle[key]
            tagStyle[key] = (color: Palette.link(l.kind), live: (prev?.live ?? false) || l.live,
                             dim: (prev?.dim ?? true) && dim)
        }
        for (to, ports) in targetPorts {
            for port in ports {
                guard let r = tagRect(to, port), let st = tagStyle["\(to):\(port)"] else { continue }
                g.tags.append(Tag(rect: r, port: port, color: st.color, live: st.live, dim: st.dim))
            }
        }
        return g
    }

    /// Статичный слой: линии, стрелки, скорость обмена, гнёзда портов.
    func draw(_ g: Geometry, in ctx: inout GraphicsContext) {
        for e in g.edges {
            let style = e.link.live
                ? StrokeStyle(lineWidth: e.width, lineCap: .round)
                : StrokeStyle(lineWidth: e.width, lineCap: .round, dash: [2, 4])
            // Под активной связью — бледная сплошная линия, поверх неё бежит пунктир.
            ctx.stroke(e.path, with: .color(e.link.isActive ? e.color.opacity(0.3) : e.color), style: style)

            var head = Path()
            head.move(to: e.end)
            head.addLine(to: CGPoint(x: e.end.x - 7, y: e.end.y - 4))
            head.addLine(to: CGPoint(x: e.end.x - 7, y: e.end.y + 4))
            head.closeSubpath()
            ctx.fill(head, with: .color(e.color))

            if e.link.isActive, e.link.bytesPerSec >= 1024, !e.dim {
                let text = ctx.resolve(Text(Format.rate(e.link.bytesPerSec))
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundColor(Palette.link(e.link.kind)))
                ctx.draw(text, at: CGPoint(x: e.mid.x, y: e.mid.y - 8))
            }
        }
        for t in g.tags {
            let alpha = (t.live ? 0.95 : 0.45) * (t.dim ? 0.2 : 1)
            ctx.fill(Path(roundedRect: t.rect, cornerRadius: 8), with: .color(t.color.opacity(alpha)))
            let text = ctx.resolve(Text(verbatim: ":" + String(t.port))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(t.dim ? 0.5 : 1)))
            ctx.draw(text, at: CGPoint(x: t.rect.midX, y: t.rect.midY))
        }
    }

    /// Активные связи для слоя анимации — уже в масштабе экрана.
    func flowItems(_ g: Geometry, scale: CGFloat) -> [FlowLayer.Item] {
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        return g.edges.filter { $0.link.isActive }.compactMap { e in
            guard let path = e.path.cgPath.copy(using: &transform) else { return nil }
            return FlowLayer.Item(id: e.link.id, path: path, color: NSColor(e.color),
                                  width: (e.width + 0.6) * scale, scale: scale)
        }
    }
}

/// Бегущий пунктир на Core Animation: анимацию крутит системный композитор, приложение не тратит процессор.
struct FlowLayer: NSViewRepresentable {
    struct Item {
        let id: String
        let path: CGPath
        let color: NSColor
        let width: CGFloat
        let scale: CGFloat
    }

    var items: [Item]

    func makeNSView(context: Context) -> FlowView { FlowView() }

    func updateNSView(_ view: FlowView, context: Context) { view.update(items) }

    final class FlowView: NSView {
        private let container = CALayer()
        private var shapes: [String: CAShapeLayer] = [:]

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            container.isGeometryFlipped = true
            layer?.addSublayer(container)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = bounds
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(_ items: [Item]) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var seen = Set<String>()
            for it in items {
                seen.insert(it.id)
                let shape: CAShapeLayer
                if let s = shapes[it.id] { shape = s } else {
                    shape = CAShapeLayer()
                    shape.fillColor = nil
                    shape.lineCap = .round
                    container.addSublayer(shape)
                    shapes[it.id] = shape
                }
                shape.path = it.path
                shape.strokeColor = it.color.cgColor
                shape.lineWidth = it.width
                let dash = [7 * it.scale, 5 * it.scale]
                if shape.lineDashPattern?.map({ CGFloat($0.doubleValue) }) != dash {
                    shape.lineDashPattern = dash.map { NSNumber(value: Double($0)) }
                    shape.removeAnimation(forKey: "flow")
                    let a = CABasicAnimation(keyPath: "lineDashPhase")
                    a.fromValue = 0
                    a.toValue = -(dash[0] + dash[1])
                    a.duration = 0.45
                    a.repeatCount = .infinity
                    shape.add(a, forKey: "flow")
                }
            }
            for (id, shape) in shapes where !seen.contains(id) {
                shape.removeFromSuperlayer()
                shapes[id] = nil
            }
            CATransaction.commit()
        }
    }
}

/// Видно ли окно на экране (не свёрнуто, не на другом рабочем столе, не закрыто другими окнами).
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> NSView {
        let v = ProbeView()
        v.onChange = { value in if visible != value { visible = value } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.report() }
            report()
        }

        private func report() {
            let value = window?.occlusionState.contains(.visible) ?? false
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
