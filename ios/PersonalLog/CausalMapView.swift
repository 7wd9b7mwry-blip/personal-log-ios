import SwiftUI

/// The causal map (public.app_causal_graph): PCMCI+ discoveries and the strongest effect estimates (lever's day held
/// equal) as a graph. It opens on the key metrics, or a focused report's metrics, and the metrics within N links of
/// them (1 to 3, or the whole map), links at least `minStrength` strong (set automatically for each view: the lowest
/// strength that keeps it readable, at most `maxLinks` links and `maxAdded` metrics besides the centre ones; the slider
/// overrides it until the view changes); tap a metric to select it (its links light up
/// and list below), double-tap to bring in what drives it; pinch and drag to move around. A row opens the metric or the
/// pair.
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
    struct Report: Decodable, Hashable, Identifiable { let id: Int; let title: String; let metrics: [Int]; let area: [Int]? }
    let nodes: [Node]
    let edges: [Edge]
    let reports: [Report]?
}

struct CausalMapView: View {
    @EnvironmentObject var store: Store
    @State private var graph: CausalGraph?
    @State private var focus: Int?                   // a focused report's metrics at the centre; nil: the key metrics
    @State private var depthChoice = -1              // the Links picker: -1 auto, 1 to 3, 0 the whole map
    @State private var depth = 1                     // metrics within this many links of them; 0: the whole map
    @State private var error: String?
    @State private var shown: Set<Int> = []          // metrics on the map
    @State private var selected: Int?
    @State private var showEffects = true
    @State private var showDiscovery = true
    @State private var minStrength = 0.0             // links weaker than this (|partial r| or |SD|) are left out
    @State private var autoStrength = true           // minStrength picked for the view (false once the slider moves)
    private let maxLinks = 30
    private let maxAdded = 14

    /// The slider's top: the strongest link, rounded up to 0.1 (effects can pass 1 SD).
    private var topStrength: Double {
        (max(0.6, (graph?.edges ?? []).map { abs($0.size ?? 0) }.max() ?? 0.6) * 10).rounded(.up) / 10
    }
    @State private var pos: [Int: CGPoint] = [:]     // layout, unit square
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero

    init(report: Int? = nil) { _focus = State(initialValue: report) }

    private var nodes: [Int: CausalGraph.Node] { Dictionary(uniqueKeysWithValues: (graph?.nodes ?? []).map { ($0.id, $0) }) }

    private var kindEdges: [CausalGraph.Edge] { edges(atLeast: minStrength) }

    private func edges(atLeast min: Double) -> [CausalGraph.Edge] {
        (graph?.edges ?? []).filter { ($0.method == "effect" ? showEffects : showDiscovery) && abs($0.size ?? 0) >= min }
    }

    private var visibleEdges: [CausalGraph.Edge] {
        kindEdges.filter { shown.contains($0.source) && shown.contains($0.target) }
    }

    /// The metrics the map centres on: the report's outcomes and area metrics, else the key metrics.
    private var seeds: Set<Int> { centre.union(areaSeeds) }

    /// Drawn large: the report's outcomes, else the key metrics.
    private var centre: Set<Int> {
        guard let g = graph else { return [] }
        if let f = focus, let r = g.reports?.first(where: { $0.id == f }) { return Set(r.metrics) }
        return Set(g.nodes.filter { $0.key == true }.map(\.id))
    }

    /// Drawn medium: the report's area metrics (its other measures, inputs too).
    private var areaSeeds: Set<Int> {
        guard let f = focus, let r = graph?.reports?.first(where: { $0.id == f }) else { return [] }
        return Set(r.area ?? []).subtracting(centre)
    }

    private var focusTitle: String {
        focus.flatMap { f in graph?.reports?.first { $0.id == f }?.title } ?? "Key metrics"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "Causal map", intro: "Arrows: what moves what. Solid: found by causal discovery (PCMCI+); "
                     + "thin: effect estimates holding other factors equal. Blue raises, orange lowers. "
                     + "Tap a metric to see its links, double-tap to add what drives it; pinch and drag to move.") {
                    HStack {
                        Menu {
                            Button("Key metrics") { focus = nil }
                            ForEach(graph?.reports ?? []) { r in Button(r.title) { focus = r.id } }
                        } label: {
                            Label(focusTitle, systemImage: "scope").lineLimit(1)
                        }
                        Spacer()
                        Picker("Links", selection: $depthChoice) {
                            Text("Auto").tag(-1); Text("1").tag(1); Text("2").tag(2); Text("3").tag(3); Text("All").tag(0)
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                    }
                    .font(.system(size: 13))
                    HStack {
                        Toggle("Effects", isOn: $showEffects).toggleStyle(.button)
                        Toggle("Discovery", isOn: $showDiscovery).toggleStyle(.button)
                        Spacer()
                        Button("Reset") { autoStrength = true; reset() }.font(.system(size: 13))
                    }
                    .font(.system(size: 13))
                    HStack {
                        Text("Min strength").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Slider(value: $minStrength, in: 0...topStrength, step: 0.05, onEditingChanged: { editing in
                            if !editing { autoStrength = false; reset(pick: false) }
                        })
                        Text(String(format: "%.2f", minStrength) + (autoStrength ? " auto" : ""))
                            .font(.system(size: 12).monospacedDigit()).frame(width: autoStrength ? 64 : 34, alignment: .trailing)
                    }
                    .padding(.bottom, 6)
                    Muted(text: (depth == 0 ? "\(focusTitle) on the whole map."
                          : "\(focusTitle) and the metrics within \(depth) link\(depth == 1 ? "" : "s") of them"
                            + (depthChoice == -1 ? " (picked for this view)." : "."))
                          + (focus == nil ? " Large dots: the key metrics." : " Large dots: the report's outcomes; medium: its area metrics."))
                        .font(.system(size: 12))
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
        .onChange(of: focus) { autoStrength = true; reset() }
        .onChange(of: depthChoice) { reset() }
        .onChange(of: showEffects) { reset() }
        .onChange(of: showDiscovery) { reset() }
    }

    // MARK: drawing

    private var canvas: some View {
        // read here, in the body, so a new layout redraws the map: the Canvas and GeometryReader closures run later,
        // outside the body, and SwiftUI doesn't track what they read (the first layout after loading wasn't drawn until
        // a toggle redrew the view)
        let _ = (pos, shown, zoom, pan, selected)
        return GeometryReader { geo in
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
        let key = centre.contains(id), own = areaSeeds.contains(id), sel = selected == id
        let linked = selected.map { s in visibleEdges.contains { ($0.source == s && $0.target == id) || ($0.target == s && $0.source == id) } } ?? false
        let r: CGFloat = key ? 10 : own ? 8 : 6
        let dim = selected != nil && !sel && !linked
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                 with: .color((key ? Theme.accent : own ? Theme.accent.opacity(0.55) : Color.gray).opacity(dim ? 0.25 : 1)))
        if sel { ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)), with: .color(Theme.accent), lineWidth: 2) }
        if key || own || sel || linked || zoom > 1.6 {
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

    /// Shows the centre metrics (seeds) and every metric within `depth` links of them, either direction, over the
    /// links shown (effects / discovery) at least `minStrength` strong; depth 0: every metric.
    /// `pick`: while the strength is automatic, first the lowest one (by 0.05) whose map has at most `maxLinks` links
    /// and `maxAdded` metrics besides the centre ones, so each view (key metrics, a report, 1 to 3 links or all) opens
    /// with as many links as stay readable (2026-11-24: key metrics about 1.0, Sleep 0.75, Nutrition 0.3, Hygiene 0).
    /// Links on Auto: from 1 link out, one more while that needs at most 0.1 more strength and shows at least as many
    /// links (2026-11-25: key metrics 2, Medical 3, Hygiene 3, Productivity 2, Sleep / Nutrition 1); with the strength
    /// set by hand, the deepest of 1 to 3 that stays readable at it.
    private func reset(pick: Bool = true) {
        guard graph != nil else { return }
        if depthChoice != -1 {
            depth = depthChoice
            if pick && autoStrength { minStrength = readable(depth).0 }
        } else if pick && autoStrength {
            var best = (d: 1, r: readable(1))
            for d in 2...3 {
                let r = readable(d)
                guard r.0 <= best.r.0 + 0.1 + 1e-9, r.1 >= best.r.1 else { break }
                best = (d, r)
            }
            depth = best.d
            minStrength = best.r.0
        } else {
            let centre = seeds
            depth = [3, 2, 1].first { d in
                let (s, n) = reach(atLeast: minStrength, depth: d)
                return n <= maxLinks && s.subtracting(centre).count <= maxAdded
            } ?? 1
        }
        shown = reach(atLeast: minStrength, depth: depth).0
        selected = nil
        zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero
        layout(fresh: true)
    }

    /// The lowest strength (by 0.05) at which `d` links out stays readable, and how many links that shows.
    private func readable(_ d: Int) -> (Double, Int) {
        let centre = seeds
        for t in stride(from: 0.0, through: topStrength, by: 0.05) {
            let (s, n) = reach(atLeast: t, depth: d)
            if n <= maxLinks && s.subtracting(centre).count <= maxAdded { return (t, n) }
        }
        return (topStrength, reach(atLeast: topStrength, depth: d).1)
    }

    /// The metrics within `depth` links of the seeds over the links at least `min` strong, and how many links join them.
    private func reach(atLeast min: Double, depth: Int) -> (Set<Int>, Int) {
        let es = edges(atLeast: min)
        var s = seeds
        if depth == 0 {
            for e in es { s.insert(e.source); s.insert(e.target) }
        } else {
            var next: [Int: Set<Int>] = [:]
            for e in es { next[e.source, default: []].insert(e.target); next[e.target, default: []].insert(e.source) }
            var frontier = s
            for _ in 0..<depth {
                frontier = Set(frontier.flatMap { next[$0] ?? [] }).subtracting(s)
                s.formUnion(frontier)
            }
        }
        return (s, es.filter { s.contains($0.source) && s.contains($0.target) }.count)
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
