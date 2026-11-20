import Charts
import SwiftUI

/// One metric: its chart and stats, what drives it (key metrics), its sweet spots and weekday pattern, what it drives,
/// everything related to it, and the AI's look; each row opens the evidence for that pair.
struct MetricView: View {
    @EnvironmentObject var store: Store
    let r: ReportData
    let id: Int
    @State private var days: [DayValue] = []
    @State private var error: String?
    @State private var range = 90
    @State private var allDrivers = false
    @State private var allRelated = false
    @State private var touched: Date?   // where a finger is on the chart

    var body: some View {
        let m = r.metric(id)
        let key = r.key(id)
        ScrollView {
            LazyVStack(spacing: 14) {
                Card(title: m?.name, intro: subtitle(m)) { chart(m) }
                InsightCard(page: .metric(id))
                if let k = key { drivers(k, m) }
                let timing = r.timing.filter { $0.target == id }
                if !timing.isEmpty {
                    Card(title: "Timing before bed") {
                        ForEach(timing) { t in
                            CardRow {
                                Text("\(t.habit) \(ReportHome.span(t))").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Muted(text: "\(t.helps ? "Better" : "Worse") by " + String(Units.signed(abs(t.typical_effect ?? 0), m?.unit, weightUnit: r.weightUnit).dropFirst())
                                      + " (typically \(t.typical_amount ?? ""), \(t.n_span ?? 0) nights)")
                            }
                        }
                    }
                }
                let drives = r.drives(id)
                if !drives.isEmpty {
                    Card(title: "It drives", intro: "Key metrics this one moves, others held equal.") {
                        ForEach(drives) { d in
                            CardRow(route: .pair(lever: id, target: d.target)) {
                                HStack {
                                    Text("\((d.effect_sd ?? 0) > 0 ? "▲" : "▼") \(r.name(d.target))").font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(String(format: "%+.2f SD", d.effect_sd ?? 0)).font(.system(size: 13).monospacedDigit())
                                        .foregroundStyle(d.good == true ? Theme.good : Theme.warn)
                                }
                            }
                        }
                    }
                }
                let related = r.pairs(with: id)
                if !related.isEmpty {
                    Card(title: "Related", intro: "\(related.count) relationships, strongest first, from every method.") {
                        ForEach(allRelated ? related : Array(related.prefix(8))) { p in
                            CardRow(route: .pair(lever: p.other(than: id), target: id)) { PairRow(r: r, p: p, focus: id) }
                        }
                        if related.count > 8 {
                            Button(allRelated ? "Show fewer" : "Show all \(related.count)") { allRelated.toggle() }
                                .font(.system(size: 14)).padding(.top, 8)
                        }
                    }
                }
            }
            .reportPage()
        }
        .navigationTitle(m?.name ?? "Metric")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.prefetch(oneTapAway())
            do { days = try await store.metricSeries(id) } catch { self.error = error.localizedDescription }
        }
    }

    /// The pages its rows open (as shown before "Show all"): their AI answers are prepared ahead.
    private func oneTapAway() -> [Route] {
        var out: [Route] = []
        if let k = r.key(id) {
            out += k.drivers.filter { $0.factor != true }.prefix(6).map { Route.pair(lever: $0.lever, target: id) }
            out += k.drivers.filter { $0.factor == true }.prefix(5).map { Route.pair(lever: $0.lever, target: id) }
            out += k.curves.map { Route.pair(lever: $0.lever, target: id) }
        }
        out += r.drives(id).map { Route.pair(lever: id, target: $0.target) }
        out += r.pairs(with: id).prefix(8).map { Route.pair(lever: $0.other(than: id), target: id) }
        return out
    }

    private func subtitle(_ m: RMetric?) -> String? {
        var parts: [String] = []
        if let d = m?.domain { parts.append(d.replacingOccurrences(of: "_", with: " ").capitalized) }
        if let g = r.key(id)?.goal { parts.append(g == "min" ? "lower is better" : "higher is better") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func drivers(_ k: RKey, _ m: RMetric?) -> some View {
        let habits = k.drivers.filter { $0.factor != true }
        let linked = k.drivers.filter { $0.factor == true }
        if !habits.isEmpty {
            Card(title: "What drives it", intro: "Each with the others held equal: change per +1 SD of the lever, in SDs of \(m?.name ?? "this").") {
                ForEach(allDrivers ? habits : Array(habits.prefix(6))) { d in driverRow(d) }
                if habits.count > 6 {
                    Button(allDrivers ? "Show fewer" : "Show all \(habits.count)") { allDrivers.toggle() }.font(.system(size: 14)).padding(.top, 8)
                }
            }
        }
        if !linked.isEmpty {
            Card(title: "Moves with it the same day", intro: "Other outcomes that go with it with the rest held equal; which drives which is open.") {
                ForEach(linked.prefix(5)) { d in driverRow(d) }
            }
        }
        if !k.curves.isEmpty {
            Card(title: "Sweet spots") {
                ForEach(k.curves, id: \.self) { c in
                    CardRow(route: .pair(lever: c.lever, target: id)) {
                        Text("\(((c.kind == "peak") == (k.goal != "min")) ? "Best" : "Worst") around "
                             + "\(Units.format(c.vertex, r.metric(c.lever)?.unit, weightUnit: r.weightUnit)) of \(r.name(c.lever))"
                             + (c.lag > 0 ? " (day before)" : "")).font(.system(size: 14)).foregroundStyle(Theme.text)
                        Muted(text: String(format: "p = %.3f, other factors held equal", c.p ?? 1))
                    }
                }
            }
        }
        if let w = k.weekday.first { weekday(w) }
    }

    private func driverRow(_ d: REffect) -> some View {
        CardRow(route: .pair(lever: d.lever, target: id)) {
            HStack {
                Text("\((d.effect_sd ?? 0) > 0 ? "▲" : "▼") \(r.name(d.lever))").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text(String(format: "%+.2f SD", d.effect_sd ?? 0)).font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(d.good == true ? Theme.good : Theme.warn)
            }
            HStack {
                Muted(text: (d.lag > 0 ? "the day before" : "same day") + " · \(d.good == true ? "better" : "worse")"
                      + String(format: " · p = %.3f · %d days", d.p ?? 1, d.n ?? 0))
                Spacer()
                Badge(robust: d.robust)
            }
        }
    }

    @ViewBuilder
    private func chart(_ m: RMetric?) -> some View {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range, to: Date()) ?? Date()
        let shown = days.filter { $0.day >= cutoff }
        let (f, label) = Units.axis(m?.unit, values: shown.isEmpty ? [0] : shown.map(\.value), weightUnit: r.weightUnit)
        VStack(alignment: .leading, spacing: 10) {
            if let last = days.last {
                HStack(alignment: .firstTextBaseline) {
                    Text(Units.format(last.value, m?.unit, weightUnit: r.weightUnit)).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
                    Muted(text: last.day.formatted(.dateTime.month(.abbreviated).day()))
                }
                HStack(spacing: 18) {
                    // the same spans as the range picker: only those the data reaches into
                    ForEach(RangePicker.options(oldest: days.first?.day), id: \.self) { d in
                        let since = Calendar.current.date(byAdding: .day, value: -d, to: Date()) ?? Date()
                        stat(d == 365 ? "Year" : "\(d) days", mean(days.filter { $0.day >= since }[...]), m)
                    }
                }
            } else if let error {
                Muted(text: error)
            } else {
                ProgressView()
            }
            RangePicker(days: $range, oldest: days.first?.day)
            // a finger on the chart shows the nearest day's value and date
            let hit = touched.flatMap { t in shown.min { abs($0.day.timeIntervalSince(t)) < abs($1.day.timeIntervalSince(t)) } }
            // the trend over the shown days (measured ones only), x in days since the first
            let origin = shown.first?.day ?? Date()
            let trend = TrendFit.fit(shown.filter { !$0.filled }.map { ($0.day.timeIntervalSince(origin) / 86400, $0.value) })
            Chart {
                ForEach(shown) { d in
                    LineMark(x: .value("Day", d.day), y: .value(label, d.value * f), series: .value("Series", "value"))
                        .interpolationMethod(.monotone).foregroundStyle(Theme.accent)
                    if range <= 90 {
                        PointMark(x: .value("Day", d.day), y: .value(label, d.value * f)).symbolSize(12)
                            .foregroundStyle(d.filled ? Color.gray : Theme.accent)
                    }
                }
                if let trend {
                    ForEach(Array(trend.points.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Day", origin.addingTimeInterval(p.x * 86400)), y: .value(label, p.y * f),
                                 series: .value("Series", "trend"))
                            .foregroundStyle(trend.color).lineStyle(trend.stroke)
                    }
                }
                if let hit {
                    RuleMark(x: .value("Day", hit.day)).foregroundStyle(Theme.muted.opacity(0.5))
                    PointMark(x: .value("Day", hit.day), y: .value(label, hit.value * f)).symbolSize(70).foregroundStyle(Theme.accent)
                        .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartTip(value: Units.format(hit.value, m?.unit, weightUnit: r.weightUnit),
                                     detail: hit.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + (hit.filled ? " · filled" : ""))
                        }
                }
            }
            .chartXSelection(value: $touched)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel(label)
            .frame(height: 200)
            if let trend {
                let k = range <= 30 ? 1.0 : range <= 90 ? 7.0 : 30.0
                let per = range <= 30 ? "a day" : range <= 90 ? "a week" : "a month"
                TrendCaption(fit: trend, text: trend.caption(
                    change: { Units.format($0 * k, m?.unit, weightUnit: r.weightUnit) },
                    at: { origin.addingTimeInterval($0 * 86400).formatted(.dateTime.month(.abbreviated).day()) },
                    per: per, overTime: true))
            }
        }
    }

    private func stat(_ title: String, _ v: Double?, _ m: RMetric?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(Units.format(v, m?.unit, weightUnit: r.weightUnit)).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text)
        }
    }

    private func mean(_ s: ArraySlice<DayValue>) -> Double? {
        s.isEmpty ? nil : s.map(\.value).reduce(0, +) / Double(s.count)
    }

    private func weekday(_ w: RWeekday) -> some View {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let pts = w.means.enumerated().compactMap { i, v in v.map { (names[i], $0) } }
        return Card(title: "Weekday pattern", intro: "Best on \(names[w.best]), worst on \(names[w.worst])" + String(format: " · p = %.3f", w.p ?? 1)) {
            Chart(pts, id: \.0) { p in
                BarMark(x: .value("Day", p.0), y: .value("Mean", p.1))
                    .foregroundStyle(p.0 == names[w.best] ? Theme.good : p.0 == names[w.worst] ? Theme.warn : Theme.accent.opacity(0.35))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 140)
        }
    }
}
