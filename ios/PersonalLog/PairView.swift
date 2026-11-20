import Charts
import SwiftUI

/// One relationship: the effect estimate (when the lever drives a key metric), every method's evidence, the AI's look,
/// and the two metrics on the same days over 30 / 90 days / a year: the outcome's mean by fifths of the lever, and a
/// scatter.
struct PairView: View {
    @EnvironmentObject var store: Store
    let r: ReportData
    let lever: Int
    let target: Int
    @State private var rows: [(Date, Double?, Double, Double?)] = []
    @State private var dayBefore = false
    @State private var range = 90
    @State private var loaded = false
    @State private var error: String?
    @State private var touched: Int?   // the scatter point under a finger

    var body: some View {
        let effect = r.driver(lever, target)
        let pair = r.pair(lever, target)
        let lu = r.metric(lever)?.unit, tu = r.metric(target)?.unit
        let cutoff = Calendar.current.date(byAdding: .day, value: -range, to: Date()) ?? Date()
        let pts: [(Double, Double)] = rows.filter { $0.0 >= cutoff }.compactMap { row in (dayBefore ? row.3 : row.1).map { ($0, row.2) } }
        ScrollView {
            LazyVStack(spacing: 14) {
                if let e = effect {
                    Card(title: "Effect estimate") {
                        Text("+1 SD of \(r.name(lever))\(e.lag > 0 ? " the day before" : "") → "
                             + String(format: "%+.2f SD", e.effect_sd ?? 0) + " of \(r.name(target))")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        HStack {
                            Muted(text: (e.good == true ? "better" : "worse")
                                  + String(format: " · p = %.3f · q = %.2f · %d days · %d other factors held equal",
                                           e.p ?? 1, e.q ?? 1, e.n ?? 0, e.n_controls ?? 0))
                            Spacer()
                            Badge(robust: e.robust)
                        }
                        .padding(.top, 4)
                    }
                }
                if let p = pair {
                    Card(title: "Evidence", intro: "Robust = a method that holds other factors equal passed its multiple-testing check; correlations alone stay tentative.") {
                        ForEach(p.evidence, id: \.self) { ev in
                            CardRow {
                                HStack { Text(ev.kind.capitalized).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub); Spacer(); Badge(robust: ev.robust) }
                                Text(ev.text).font(.system(size: 13)).foregroundStyle(Theme.text)
                            }
                        }
                    }
                } else if effect == nil {
                    Card { Muted(text: "No method found this pair beyond chance; the raw days below are just the data.") }
                }
                InsightCard(page: .pair(lever, target))
                Card(title: "On your days", intro: "Raw days, nothing held equal: a picture of the data behind the estimate.") {
                    VStack(alignment: .leading, spacing: 10) {
                        RangePicker(days: $range, oldest: rows.first?.0)
                        Picker("", selection: $dayBefore) {
                            Text("Same day").tag(false); Text("Day before").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Muted(text: dayBefore ? "\(r.name(lever)) the day before vs \(r.name(target))" : "\(r.name(lever)) and \(r.name(target)) the same day")
                        if pts.count >= 5 {
                            bins(pts, lu, tu)
                            let trend = TrendFit.fit(pts)
                            scatter(pts, lu, tu, trend)
                            if let trend, let lo = pts.map(\.0).min(), let hi = pts.map(\.0).max() {
                                TrendCaption(fit: trend, text: trend.caption(
                                    change: { Units.format($0 * (hi - lo), tu, weightUnit: r.weightUnit) },
                                    at: { Units.format($0, lu, weightUnit: r.weightUnit) + " of \(r.name(lever))" },
                                    per: "from the lowest to the highest \(r.name(lever))",
                                    goalMin: r.key(target)?.goal.map { $0 == "min" }))
                            }
                            Muted(text: "\(pts.count) days" + correlation(pts))
                        } else {
                            Muted(text: loaded ? (error ?? "Too few days with both in this range (\(pts.count)).") : "Loading…")
                        }
                    }
                }
                Card {
                    CardRow(route: .metric(lever)) { Text(r.name(lever)).font(.system(size: 14)).foregroundStyle(Theme.text) }
                    CardRow(route: .metric(target)) { Text(r.name(target)).font(.system(size: 14)).foregroundStyle(Theme.text) }
                }
            }
            .reportPage()
        }
        .navigationTitle("\(r.name(lever)) → \(r.name(target))")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.prefetch([.metric(lever), .metric(target)])
            dayBefore = (effect?.lag ?? 0) > 0
            do { rows = try await store.pairDays(lever: lever, target: target) } catch { self.error = error.localizedDescription }
            loaded = true
        }
    }

    private func correlation(_ pts: [(Double, Double)]) -> String {
        let n = Double(pts.count)
        let mx = pts.map(\.0).reduce(0, +) / n, my = pts.map(\.1).reduce(0, +) / n
        let sxy = pts.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
        let sxx = pts.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +), syy = pts.map { ($0.1 - my) * ($0.1 - my) }.reduce(0, +)
        guard sxx > 0, syy > 0 else { return "" }
        return String(format: " · raw r = %+.2f", sxy / (sxx * syy).squareRoot())
    }

    /// The outcome's mean in up to five equal-count groups of the lever, low to high (lever values in the axis unit).
    private func bins(_ pts: [(Double, Double)], _ lu: String?, _ tu: String?) -> some View {
        let sorted = pts.sorted { $0.0 < $1.0 }
        let k = min(5, max(2, sorted.count / 6))
        let (fx, ax) = Units.axis(lu, values: pts.map(\.0), weightUnit: r.weightUnit)
        let short = { (v: Double) in String(format: abs(v * fx) >= 100 ? "%.0f" : "%.3g", v * fx) }
        let groups: [(String, Double, Int)] = (0..<k).compactMap { i in
            let s = sorted[(i * sorted.count / k)..<((i + 1) * sorted.count / k)]
            guard let lo = s.first?.0, let hi = s.last?.0 else { return nil }
            return (lo == hi ? short(lo) : "\(short(lo))–\(short(hi))", s.map(\.1).reduce(0, +) / Double(s.count), s.count)
        }
        let (fy, ay) = Units.axis(tu, values: pts.map(\.1), weightUnit: r.weightUnit)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(r.name(target)) by \(r.name(lever))\(ax.isEmpty ? "" : " (\(ax))")").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub)
            Chart(groups, id: \.0) { g in
                BarMark(x: .value("Lever", g.0), y: .value(ay, g.1 * fy))
                    .foregroundStyle(Theme.accent.opacity(0.75))
                    .annotation(position: .top) { Text(Units.format(g.1, tu, weightUnit: r.weightUnit)).font(.system(size: 10)).foregroundStyle(Theme.text) }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) } }
            .frame(height: 170)
        }
    }

    private func dist(_ proxy: ChartProxy, _ pt: (Double, Double), _ fx: Double, _ fy: Double, _ p: CGPoint) -> CGFloat {
        guard let x = proxy.position(forX: pt.0 * fx), let y = proxy.position(forY: pt.1 * fy) else { return .infinity }
        return hypot(x - p.x, y - p.y)
    }

    private func scatter(_ pts: [(Double, Double)], _ lu: String?, _ tu: String?, _ trend: TrendFit?) -> some View {
        let (fx, ax) = Units.axis(lu, values: pts.map(\.0), weightUnit: r.weightUnit)
        let (fy, ay) = Units.axis(tu, values: pts.map(\.1), weightUnit: r.weightUnit)
        return Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { item in
                PointMark(x: .value(ax, item.element.0 * fx), y: .value(ay, item.element.1 * fy)).symbolSize(18)
                    .foregroundStyle(Theme.accent.opacity(0.7))
            }
            if let trend {
                ForEach(Array(trend.points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value(ax, p.x * fx), y: .value(ay, p.y * fy), series: .value("Series", "trend"))
                        .foregroundStyle(trend.color).lineStyle(trend.stroke)
                }
            }
            if let i = touched, i < pts.count {
                PointMark(x: .value(ax, pts[i].0 * fx), y: .value(ay, pts[i].1 * fy)).symbolSize(90).foregroundStyle(Theme.accent)
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTip(value: "\(r.name(target)): \(Units.format(pts[i].1, tu, weightUnit: r.weightUnit))",
                                 detail: "\(r.name(lever)): \(Units.format(pts[i].0, lu, weightUnit: r.weightUnit))")
                    }
            }
        }
        // a finger on the plot picks the nearest point (on screen), shown with both values
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard let frame = proxy.plotFrame else { return }
                            let origin = geo[frame].origin
                            let p = CGPoint(x: g.location.x - origin.x, y: g.location.y - origin.y)
                            touched = pts.indices.min { a, b in
                                dist(proxy, pts[a], fx, fy, p) < dist(proxy, pts[b], fx, fy, p)
                            }
                        }
                        .onEnded { _ in touched = nil })
            }
        }
        .chartXScale(domain: .automatic(includesZero: false))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel("\(r.name(lever))\(ax.isEmpty ? "" : " (\(ax))")")
        .chartYAxisLabel("\(r.name(target))\(ay.isEmpty ? "" : " (\(ay))")")
        .frame(height: 220)
    }
}
