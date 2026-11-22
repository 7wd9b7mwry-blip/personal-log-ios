import SwiftUI

/// The causal map (public.app_causal_graph): PCMCI+ discoveries and the strongest effect estimates (lever's day held
/// equal) as a graph. It opens on the key metrics and what drives them; tap a metric to select it (its links light up
/// and list below), double-tap to bring in what drives it; pinch and drag to move around. A row opens the metric or
/// the pair.
struct CausalGraph: Decodable {
    struct Node: Decodable, Identifiable, Hashable { let id: Int; let name: String; let domain: String?; let key: Bool? }
    struct Edge: Decodable, Hashable {
        let method: String      // discovery | effect
        let mode: String        // daily | weekly | monthly | quarterly
        let source: Int
        let target: Int
        let lag: Int?
        let type: String?       // --> directed; o-o / x-x direction unclear
        let size: Double?       // partial correlation (discovery) or effect in SDs (effect)
        let q: Double?
    }
    let nodes: [Node]
    let edges: [Edge]
}

struct CausalMapView: View {
    @EnvironmentObject var store: Store
    @State private var graph: CausalGraph?
    @State private var error: String?
    @State private var shown: Set<Int> = []          // metrics on the map
    @State private var selected: Int?
    @State private var showEffects = true
    @State private var showDiscovery = true
    @State private var pos: [Int: CGPoint] = [:]     // layout, unit square
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero

    private var nodes: [Int: CausalGraph.Node] { Dictionary(uniqueKeysWithValues: (graph?.nodes ?? []).map { ($0.id, $0) }) }

    private var visibleEdges: [CausalGraph.Edge] {
        (graph?.edges ?? []).filter { e in
            shown.contains(e.source) && shown.contains(e.target)
                && (e.method == "effect" ? showEffects : showDiscovery)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "Causal map", intro: "Arrows: what moves what. Solid: found by causal discovery (PCMCI+); "
                     + "thin: effect estimates holding other factors equal. Blue raises, orange lowers. "
                     + "Tap a metric to see its links, double-tap to add what drives it; pinch and drag to move.") {
                    HStack {
                        Toggle("Effects", isOn: $showEffects).toggleStyle(.button)
                        Toggle("Discovery", isOn: $showDiscovery).toggleStyle(.button)
                        Spacer()
                        Button("Key metrics") { reset() }.font(.system(size: 13))
                    }
                    .font(.system(size: 13))
                    .padding(.bottom, 6)
                    if let graph, !graph.edges.isEmpty {
                        canvas.frame(height: 460).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    } else if let error {
                        Muted(text: error)
                    } else if graph != nil {
                        Muted(text: "No links yet.")
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                if let s = selected, let n = nodes[s] { linksCard(n) }
            }
            .reportPage()
        }
        .navigationTitle("Causal map")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: drawing

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in
                for e in visibleEdges { drawEdge(e, ctx: &ctx, size: size) }
                for id in shown { drawNode(id, ctx: &ctx, size: size) }
            }
            .background(Color.white)
            .contentShape(Rectangle())
            .gesture(SimultaneousGesture(
                MagnifyGesture().onChanged {
                    zoom = max(0.8, min(4, zoomBase * $0.magnification))
                    pan = bounded(pan, size); panBase = pan
                }.onEnded { _ in zoomBase = zoom },
                DragGesture().onChanged {
                    pan = bounded(CGSize(width: panBase.width + $0.translation.width, height: panBase.height + $0.translation.height), size)
                }.onEnded { _ in panBase = pan }))
            .onTapGesture(count: 2) { p in if let id = hit(p, size: size) { expand(id) } }
            .onTapGesture { p in selected = hit(p, size: size) }
        }
    }

    private func screen(_ id: Int, _ size: CGSize) -> CGPoint? {
        guard let p = pos[id] else { return nil }
        let pad: CGFloat = 40
        let x = pad + p.x * (size.width - 2 * pad), y = pad + p.y * (size.height - 2 * pad)
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: cx + (x - cx) * zoom + pan.width, y: cy + (y - cy) * zoom + pan.height)
    }

    /// A pan that keeps the metrics in view: the layout's edge never moves past the frame's centre.
    private func bounded(_ p: CGSize, _ size: CGSize) -> CGSize {
        let pts = shown.compactMap { pos[$0] }
        guard !pts.isEmpty else { return .zero }
        let pad: CGFloat = 40, w = size.width - 2 * pad, h = size.height - 2 * pad
        // the layout's extent around the frame centre, at this zoom
        let xs = pts.map { (pad + $0.x * w - size.width / 2) * zoom }, ys = pts.map { (pad + $0.y * h - size.height / 2) * zoom }
        let lo = CGSize(width: -(xs.max()!), height: -(ys.max()!)), hi = CGSize(width: -(xs.min()!), height: -(ys.min()!))
        return CGSize(width: min(max(p.width, lo.width), hi.width), height: min(max(p.height, lo.height), hi.height))
    }

    private func hit(_ p: CGPoint, size: CGSize) -> Int? {
        shown.compactMap { id in screen(id, size).map { (id, hypot($0.x - p.x, $0.y - p.y)) } }
            .filter { $0.1 < 22 }.min { $0.1 < $1.1 }?.0
    }

    private func color(_ e: CausalGraph.Edge) -> Color {
        (e.size ?? 0) >= 0 ? Color(red: 0.16, green: 0.38, blue: 0.85) : Color(red: 0.90, green: 0.45, blue: 0.10)
    }

    private func drawEdge(_ e: CausalGraph.Edge, ctx: inout GraphicsContext, size: CGSize) {
        guard let a = screen(e.source, size), let b = screen(e.target, size) else { return }
        let lit = selected == nil || selected == e.source || selected == e.target
        let w = e.method == "discovery" ? 2.6 : 0.8 + min(abs(e.size ?? 0), 2) * 0.9
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        ctx.stroke(path, with: .color(color(e).opacity(lit ? 0.85 : 0.12)), lineWidth: w)
        guard e.type == "-->" else { return }
        let ang = atan2(b.y - a.y, b.x - a.x), r: CGFloat = 11, tip = CGPoint(x: b.x - cos(ang) * r, y: b.y - sin(ang) * r)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - cos(ang - 0.45) * 8, y: tip.y - sin(ang - 0.45) * 8))
        head.addLine(to: CGPoint(x: tip.x - cos(ang + 0.45) * 8, y: tip.y - sin(ang + 0.45) * 8))
        head.closeSubpath()
        ctx.fill(head, with: .color(color(e).opacity(lit ? 0.9 : 0.12)))
    }

    private func drawNode(_ id: Int, ctx: inout GraphicsContext, size: CGSize) {
        guard let p = screen(id, size), let n = nodes[id] else { return }
        let key = n.key == true, sel = selected == id
        let linked = selected.map { s in visibleEdges.contains { ($0.source == s && $0.target == id) || ($0.target == s && $0.source == id) } } ?? false
        let r: CGFloat = key ? 10 : 6
        let dim = selected != nil && !sel && !linked
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                 with: .color((key ? Theme.accent : Color.gray).opacity(dim ? 0.25 : 1)))
        if sel { ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)), with: .color(Theme.accent), lineWidth: 2) }
        if key || sel || linked || zoom > 1.6 {
            let label = Text(n.name).font(.system(size: key || sel ? 11 : 9, weight: key || sel ? .semibold : .regular))
                .foregroundColor(Theme.text.opacity(dim ? 0.3 : 1))
            ctx.draw(label, at: CGPoint(x: p.x, y: p.y + r + 8), anchor: .top)
        }
    }

    // MARK: the selected metric's links

    @ViewBuilder private func linksCard(_ n: CausalGraph.Node) -> some View {
        let all = (graph?.edges ?? []).filter { $0.source == n.id || $0.target == n.id }
            .sorted { abs($0.size ?? 0) > abs($1.size ?? 0) }
        Card(title: n.name, intro: "\(all.count) link(s). Double-tap it on the map to add what drives it.") {
            CardRow(route: .metric(n.id)) { Text("Open its chart").font(.system(size: 14)).foregroundStyle(Theme.accent) }
            ForEach(all, id: \.self) { e in
                CardRow(route: .pair(lever: e.source, target: e.target)) {
                    Text("\(nodes[e.source]?.name ?? "?") \(e.type == "-->" ? "→" : "—") \(nodes[e.target]?.name ?? "?")")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Muted(text: describe(e))
                }
            }
        }
    }

    private func describe(_ e: CausalGraph.Edge) -> String {
        let lag = (e.lag ?? 0) == 0 ? "same day" : "\(e.lag!) day(s) later"
        let s = String(format: "%+.2f", e.size ?? 0), q = String(format: "%.3f", e.q ?? 0)
        if e.method == "discovery" {
            let period = e.mode == "daily" ? "" : " (\(e.mode) blocks)"
            return "Causal discovery\(period): partial r \(s), \(lag)\(e.type == "-->" ? "" : ", direction unclear") · q \(q)"
        }
        return "Effect estimate: \(s) SD per SD, \(lag) · q \(q)"
    }

    // MARK: data and layout

    private func load() async {
        guard graph == nil else { return }
        do {
            let data = try await API(creds: store.creds).rpc("app_causal_graph")
            graph = try JSONDecoder().decode(CausalGraph.self, from: data)
            reset()
        } catch {
            self.error = "Couldn't load the map: \(error.localizedDescription)"
        }
    }

    /// The key metrics, what drives them, and every discovery link.
    private func reset() {
        guard let g = graph else { return }
        let keys = Set(g.nodes.filter { $0.key == true }.map(\.id))
        var s = keys
        for e in g.edges where e.method == "discovery" || keys.contains(e.target) { s.insert(e.source); s.insert(e.target) }
        shown = s
        selected = nil
        zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero
        layout(fresh: true)
    }

    /// Adds what drives a metric (its incoming effect links).
    private func expand(_ id: Int) {
        guard let g = graph else { return }
        for e in g.edges where e.target == id { shown.insert(e.source) }
        selected = id
        layout(fresh: false)
    }

    /// Force-directed layout (Fruchterman-Reingold) in the unit square; placed nodes start where they are.
    private func layout(fresh: Bool) {
        let ids = Array(shown).sorted()
        var p: [Int: CGPoint] = [:]
        for (i, id) in ids.enumerated() {
            if !fresh, let old = pos[id] { p[id] = old; continue }
            let a = Double(i) * 2.399963, r = 0.45 * sqrt(Double(i + 1) / Double(ids.count))
            p[id] = CGPoint(x: 0.5 + r * cos(a), y: 0.5 + r * sin(a))
        }
        let edges = visibleEdges.map { ($0.source, $0.target) }
        let k = 0.9 / sqrt(Double(max(ids.count, 1)))
        var temp = 0.1
        for _ in 0..<260 {
            var d = [Int: CGVector](uniqueKeysWithValues: ids.map { ($0, .zero) })
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let a = ids[i], b = ids[j]
                    var dx = p[a]!.x - p[b]!.x, dy = p[a]!.y - p[b]!.y
                    var dist = hypot(dx, dy)
                    if dist < 1e-4 { dx = 0.01; dy = 0.01; dist = 0.014 }
                    let f = k * k / dist
                    d[a]!.dx += dx / dist * f; d[a]!.dy += dy / dist * f
                    d[b]!.dx -= dx / dist * f; d[b]!.dy -= dy / dist * f
                }
            }
            for (a, b) in edges {
                guard let pa = p[a], let pb = p[b] else { continue }
                let dx = pa.x - pb.x, dy = pa.y - pb.y, dist = max(hypot(dx, dy), 1e-4), f = dist * dist / k
                d[a]!.dx -= dx / dist * f; d[a]!.dy -= dy / dist * f
                d[b]!.dx += dx / dist * f; d[b]!.dy += dy / dist * f
            }
            for id in ids {
                let v = d[id]!, len = max(hypot(v.dx, v.dy), 1e-9), step = min(len, temp)
                p[id] = CGPoint(x: min(1, max(0, p[id]!.x + v.dx / len * step)), y: min(1, max(0, p[id]!.y + v.dy / len * step)))
            }
            temp *= 0.985
        }
        withAnimation(.easeInOut(duration: 0.3)) { pos = p }
    }
}
