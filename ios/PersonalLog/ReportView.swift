import Charts
import SwiftUI

/// The latest report to browse, styled like the email: the AI's picks, summary and key metrics first, each opening into
/// its chart, drivers and relationships, and each of those into the evidence and the two metrics side by side.
struct ReportView: View {
    @EnvironmentObject var store: Store
    @State private var loading = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.page.ignoresSafeArea()
                if let r = store.report {
                    ReportHome(r: r)
                } else {
                    VStack(spacing: 12) {
                        if loading { ProgressView() }
                        Muted(text: store.reportError ?? (store.reportDate != nil
                              ? "The browsable version starts with the next report."
                              : "It downloads when connected."))
                    }
                    .padding(32)
                }
            }
            .navigationTitle(store.reportDate.map { "Report · \($0)" } ?? "Report")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                ZStack {
                    Theme.page.ignoresSafeArea()
                    if let r = store.report {
                        switch route {
                        case let .metric(id): MetricView(r: r, id: id)
                        case let .pair(lever, target): PairView(r: r, lever: lever, target: target)
                        case let .suggestion(t): SuggestionView(r: r, t: t)
                        case .browse: BrowseView(r: r)
                        case let .entity(g): EntityView(r: r, g: g)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { loading = true; await store.refreshReport(); loading = false } } label: {
                        if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .task { loading = true; await store.refreshReport(); loading = false }
        }
        // the AI's inline links (pdb://m/<id>, pdb://p/<lever>/<target>) open those pages
        .environment(\.openURL, OpenURLAction { url in
            if let route = Route(url: url) { path.append(route); return .handled }
            return .systemAction
        })
    }
}

/// AI text with its links ([label](m:123), [label](p:1:2)) as tappable words.
struct LinkedText: View {
    /// The text with any links reduced to their labels.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[([^\]]+)\]\((m|p):[\d:]+\)"#, with: "$1", options: .regularExpression)
    }

    let text: String
    var size: CGFloat = 14
    var weight: Font.Weight = .regular

    var body: some View {
        let md = text.replacingOccurrences(of: #"\]\(m:(\d+)\)"#, with: "](pdb://m/$1)", options: .regularExpression)
            .replacingOccurrences(of: #"\]\(p:(\d+):(\d+)\)"#, with: "](pdb://p/$1/$2)", options: .regularExpression)
        let attr = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        Text(attr).font(.system(size: size, weight: weight)).foregroundStyle(Theme.text).tint(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ReportHome: View {
    @EnvironmentObject var store: Store
    let r: ReportData

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                InsightCard(page: .home, auto: true, title: "Worth a look")
                Card(title: "Your key metrics", intro: "Tap one for its chart, what drives it and everything related.") {
                    ForEach(r.keyMetrics) { k in CardRow(route: .metric(k.id)) { KeyRow(r: r, k: k) } }
                }
                if !r.tries.isEmpty {
                    Card(title: "Try this", intro: "From effect estimates that hold other factors equal. Ideas to test, not proof.") {
                        ForEach(r.tries.prefix(8)) { t in CardRow(route: .suggestion(t)) { TryRow(r: r, t: t) } }
                        if r.tries.count > 8 { Muted(text: "Strongest 8 of \(r.tries.count).").padding(.top, 6) }
                    }
                }
                if !r.timing.isEmpty {
                    Card(title: "Timing before bed") {
                        ForEach(r.timing.prefix(10)) { t in
                            CardRow(route: .metric(t.target)) {
                                Text("\(t.habit) \(Self.span(t))").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Muted(text: "\(r.name(t.target)) \(t.helps ? "better" : "worse"): "
                                      + "\(Units.signed(t.typical_effect ?? 0, r.metric(t.target)?.unit, weightUnit: r.weightUnit))"
                                      + " · typically \(t.typical_amount ?? "")")
                            }
                        }
                    }
                }
                Card(title: "Explore") {
                    CardRow(route: .browse) {
                        Text("All metrics by entity, and every relationship").font(.system(size: 14)).foregroundStyle(Theme.text)
                    }
                }
                if let rv = r.review, !rv.sections.isEmpty { ReviewCard(review: rv) }
            }
            .reportPage()
        }
        .refreshable { await store.refreshReport() }
        .task { store.prefetch(r.keyMetrics.map { Route.metric($0.id) } + r.timing.prefix(10).map { Route.metric($0.target) }) }
    }

    static func span(_ t: RTiming) -> String {
        let lo = ((t.span_from ?? 0) * 2).rounded() / 2, hi = ((t.span_to ?? 0) * 2).rounded() / 2
        return "\(Fmt.amount(lo))–\(Fmt.amount(hi)) h before bed"
    }
}

/// The AI's look at a page (app-insight): on the overview it is made once per report; elsewhere a stored one shows,
/// or a button asks for one. "Worth opening" rows go to those pages.
struct InsightCard: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL
    let page: InsightPage
    var auto = true   // asks for the answer when the page opens (usually prepared ahead already)
    var title = "AI look"
    @State private var insight: Insight?
    @State private var loading = false
    @State private var error: String?
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: "sparkles").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                if insight != nil && !loading {
                    Button { Task { await load(cachedOnly: false, refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            if loading {
                HStack(spacing: 8) { ProgressView(); Muted(text: "Looking through your data… (up to a minute)") }
            } else if let i = insight {
                if let h = i.headline, !h.isEmpty { LinkedText(text: h, size: 15, weight: .semibold).padding(.bottom, 2) }
                ForEach(i.insights ?? [], id: \.self) { t in LinkedText(text: t) }
                ForEach(i.sections ?? [], id: \.self) { sec in sectionView(sec) }
                if (i.sections ?? []).isEmpty { ForEach(i.look_at ?? [], id: \.self) { l in lookRow(l) } }
                ForEach(i.caveats ?? [], id: \.self) { c in Muted(text: "⚠︎ " + LinkedText.plain(c)) }
                Muted(text: "Written by Claude from these numbers; may contain mistakes.").font(.system(size: 11))
            } else if let error {
                Muted(text: error)
                Button("Try again") { Task { await load(cachedOnly: false) } }.font(.system(size: 14))
            } else if checked {
                Button { Task { await load(cachedOnly: false) } } label: {
                    Label("Investigate this page with AI", systemImage: "sparkle.magnifyingglass").font(.system(size: 14, weight: .medium))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.aiBg, in: RoundedRectangle(cornerRadius: 12))
        .task(id: page) { await load(cachedOnly: !auto) }
    }

    /// One idea: its type, title and short reasoning, then the trends / relationships to open for it.
    private func sectionView(_ sec: ISection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Pill(text: sec.label, kind: sec.type == "test" ? .good : sec.type == "watch" || sec.type == "hypothesis" ? .warn : .info)
                Text(LinkedText.plain(sec.title)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let r = sec.reason { Text(LinkedText.plain(r)).font(.system(size: 13)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true) }
            ForEach(sec.items, id: \.self) { l in lookRow(l) }
            SectionAsk(page: page, section: sec)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
    }

    private func lookRow(_ l: Look) -> some View { AILookRow(look: l) }

    /// Shows the answer and prepares the AI answers of the pages it points to.
    private func show(_ i: Insight) {
        insight = i
        store.prefetch(((i.sections ?? []).flatMap(\.items) + (i.look_at ?? [])).compactMap(\.route))
    }

    /// An AI look from before follow-up questions existed is being rewritten (the server queued it): the new one replaces
    /// it when stored, about half a minute later.
    private func swapInRewrite(of old: Insight) async {
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let n = try? await store.insight(page, cachedOnly: true), n.ready else { continue }
            if n.cached_at != old.cached_at { show(n); return }
        }
    }

    /// Shows a stored answer; otherwise (or when asked) queues one and waits for it: the PC's Claude Code worker
    /// takes about half a minute.
    private func load(cachedOnly: Bool, refresh: Bool = false) async {
        defer { loading = false; checked = true }
        do {
            error = nil
            var i = try await store.insight(page, cachedOnly: cachedOnly, refresh: refresh)
            if i.ready {
                show(i)
                if i.upgrading == true { await swapInRewrite(of: i) }
                return
            }
            if cachedOnly && i.pending != true {
                if let e = i.error { error = "The last attempt failed: \(e.prefix(160))" }
                return
            }
            loading = true
            for _ in 0..<60 {   // up to 4 minutes
                try await Task.sleep(nanoseconds: 4_000_000_000)
                i = try await store.insight(page, cachedOnly: true)
                if i.ready { show(i); return }
                if i.pending != true {
                    error = i.error.map { "It failed: \($0.prefix(160))" } ?? "No answer: is the PC (HA logger) running?"
                    return
                }
            }
            error = "Still not done: the PC (HA logger) may be off. Try again later."
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One AI item: the claim, one line on why, and a small chart of it; the whole row opens that page.
struct AILookRow: View {
    @EnvironmentObject var store: Store
    let look: Look

    var body: some View {
        CardRow(route: look.route) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LinkedText.plain(look.title ?? name)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LinkedText.plain(look.why)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                MiniTrend(look: look).frame(width: 76, height: 40)
            }
        }
    }

    private var name: String {
        guard let r = store.report else { return "" }
        if look.kind == "metric", let id = look.id { return r.name(id) }
        if let a = look.lever, let b = look.target { return "\(r.name(a)) → \(r.name(b))" }
        return ""
    }
}

/// Under an AI idea: "Ask about this" opens suggested follow-up questions and a box for your own. Each answer comes
/// with its own follow-ups, and the thread so far goes along as context.
struct SectionAsk: View {
    @EnvironmentObject var store: Store
    let page: InsightPage
    let section: ISection
    @State private var expanded = false
    @State private var draft = ""
    @State private var thread: [QA] = []
    @FocusState private var focused: Bool

    struct QA: Identifiable {
        let id = UUID()
        let question: String
        var answer: AskAnswer?
        var error: String?
    }

    private var busy: Bool { thread.last.map { $0.answer == nil && $0.error == nil } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(expanded ? "Hide questions" : thread.isEmpty ? "Ask about this" : "Questions (\(thread.count))")
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            if expanded {
                ForEach(thread) { qa in qaView(qa) }
                if !busy {
                    let next = thread.last?.answer?.followups ?? (thread.isEmpty ? section.followups ?? [] : [])
                    ForEach(next, id: \.self) { q in
                        Button { ask(q) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                                Text(q).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 13)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask a question about this…", text: $draft, axis: .vertical)
                        .font(.system(size: 14)).lineLimit(1...4)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                        .focused($focused)
                    Button { ask(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                        .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func qaView(_ qa: QA) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(qa.question).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let a = qa.answer, let text = a.answer {
                LinkedText(text: text)
                ForEach(a.points ?? [], id: \.self) { p in
                    Text("• " + LinkedText.plain(p)).font(.system(size: 13)).foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(a.items ?? [], id: \.self) { l in AILookRow(look: l) }
            } else if let e = qa.error {
                Muted(text: e)
            } else {
                HStack(spacing: 8) { ProgressView(); Muted(text: "Thinking… (about half a minute)") }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ask(_ q: String) {
        let question = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        let earlier = thread.compactMap { qa in qa.answer?.answer.map { (qa.question, LinkedText.plain($0)) } }
        thread.append(QA(question: question))
        draft = ""
        focused = false
        let idx = thread.count - 1
        Task {
            do {
                var a = try await store.ask(page, section: section.title, question: question, thread: earlier, cachedOnly: false)
                for _ in 0..<80 where !a.ready {   // up to about 4 minutes
                    if a.queued != true && a.pending != true && a.none != true { break }
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    a = try await store.ask(page, section: section.title, question: question, thread: earlier, cachedOnly: true)
                    if !a.ready && a.pending != true && a.error != nil { break }
                }
                if a.ready {
                    thread[idx].answer = a
                    store.prefetch((a.items ?? []).compactMap(\.route))
                } else {
                    thread[idx].error = a.error.map { "It failed: \($0.prefix(160))" } ?? "No answer: is the PC (HA logger) running?"
                }
            } catch {
                thread[idx].error = error.localizedDescription
            }
        }
    }
}

/// A small chart beside an AI item: a metric's last 90 days, or a relationship as the outcome's average by fifths of
/// the lever (low to high) over the raw days.
struct MiniTrend: View {
    @EnvironmentObject var store: Store
    let look: Look
    @State private var line: [DayValue] = []
    @State private var bars: [(Int, Double)] = []

    var body: some View {
        Group {
            if !bars.isEmpty {
                Chart(bars, id: \.0) { b in BarMark(x: .value("Fifth", b.0), y: .value("Mean", b.1)).foregroundStyle(Theme.accent.opacity(0.7)) }
                    .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false))
            } else if !line.isEmpty {
                Sparkline(days: line)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(Theme.line)
            }
        }
        .task(id: look) {
            if look.kind == "metric", let id = look.id {
                line = Array(((try? await store.metricSeries(id)) ?? []).suffix(90))
            } else if let a = look.lever, let t = look.target, let rows = try? await store.pairDays(lever: a, target: t) {
                let same = rows.compactMap { r in r.1.map { ($0, r.2) } }, prev = rows.compactMap { r in r.3.map { ($0, r.2) } }
                let pts = (same.count >= prev.count ? same : prev).sorted { $0.0 < $1.0 }
                guard pts.count >= 10 else { return }
                bars = (0..<5).map { i in
                    let s = pts[(i * pts.count / 5)..<((i + 1) * pts.count / 5)]
                    return (i, s.map(\.1).reduce(0, +) / Double(max(s.count, 1)))
                }
            }
        }
    }
}

/// The daily review at the bottom of the report: what stands out, what's broken or thin, ideas and next steps.
struct ReviewCard: View {
    let review: RReview

    var body: some View {
        Card(title: "Daily review", intro: "Claude's review of this report and the system behind it. May contain mistakes.") {
            if !review.headline.isEmpty {
                Text(review.headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(.bottom, 4)
            }
            ForEach(review.sections, id: \.self) { sec in
                HStack(spacing: 6) {
                    Pill(text: sec.label, kind: sec.type == "data" ? .warn : sec.type == "next" ? .good : .info)
                    Text(sec.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.sub)
                }
                .padding(.top, 10)
                ForEach(sec.items, id: \.self) { i in
                    CardRow {
                        HStack(alignment: .firstTextBaseline) {
                            Text(i.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer(minLength: 4)
                            if i.status != "new" { Pill(text: i.status, kind: i.status == "fixed" ? .good : .warn) }
                        }
                        Text(i.note).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let issues = review.issues, !issues.isEmpty {
                HStack(spacing: 6) {
                    Pill(text: "Issue log", kind: .warn)
                    Text("\(issues.filter { !$0.fixed }.count) open").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.sub)
                }
                .padding(.top, 10)
                Muted(text: "The issue log is under More → Issues.")
            }
        }
    }
}

/// An issue in the log: title, kind, how old it is and today's example.
struct IssueRow: View {
    let issue: RIssue

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("#\(issue.id) \(issue.title)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 4)
                    Pill(text: issue.kindLabel, kind: issue.fixed ? .good : .warn)
                }
                Text(issue.state + ((issue.change ?? "").isEmpty ? "" : " · \(issue.change!)"))
                    .font(.system(size: 12)).foregroundStyle(issue.fixed ? Theme.good : Theme.muted)
                if issue.seenToday == true, let ex = issue.examples?.last, !ex.note.isEmpty {
                    Text(ex.note).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted.opacity(0.6))
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

/// One issue: when it was first and last seen, an example from every day it showed up, and what changed.
struct IssueView: View {
    let issue: RIssue

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Card(title: "#\(issue.id) \(issue.title)") {
                    HStack(spacing: 6) {
                        Pill(text: issue.kindLabel, kind: issue.fixed ? .good : .warn)
                        Text(issue.state).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    .padding(.bottom, 6)
                    CardRow { Muted(text: "First seen \(RIssue.short(issue.firstSeen)) · last seen \(RIssue.short(issue.lastSeen)) · on \(issue.daysSeen ?? 1) days") }
                    if let c = issue.change, !c.isEmpty { CardRow { Text("Today: \(c)").font(.system(size: 13)).foregroundStyle(Theme.text) } }
                }
                if let ex = issue.examples, !ex.isEmpty {
                    Card(title: "Examples", intro: "From each day's report, newest first.") {
                        ForEach(ex.reversed(), id: \.self) { x in
                            CardRow {
                                Text(RIssue.short(x.date)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sub)
                                Text(x.note).font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let h = issue.history, !h.isEmpty {
                    Card(title: "History") {
                        ForEach(h.reversed(), id: \.self) { x in
                            CardRow {
                                Text("\(RIssue.short(x.date)) · \(x.status)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sub)
                                if let n = x.note, !n.isEmpty { Text(n).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.page.ignoresSafeArea())
        .navigationTitle("Issue")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A key metric on the home card: its sparkline, latest value and strongest driver.
struct KeyRow: View {
    @EnvironmentObject var store: Store
    let r: ReportData
    let k: RKey
    @State private var days: [DayValue] = []

    var body: some View {
        let m = r.metric(k.id)
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(m?.name ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    if let g = k.goal { Muted(text: g == "min" ? "· lower is better" : "· higher is better").font(.system(size: 11)) }
                }
                if let d = k.drivers.first {
                    Text("\((d.effect_sd ?? 0) > 0 ? "▲" : "▼") \(r.name(d.lever))\(d.lag > 0 ? " (day before)" : "")")
                        .font(.system(size: 12)).foregroundStyle(d.good == true ? Theme.good : Theme.warn).lineLimit(1)
                } else {
                    Muted(text: "Nothing beyond chance yet").font(.system(size: 12))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Units.format(days.last?.value, m?.unit, weightUnit: r.weightUnit)).font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.text)
                Sparkline(days: Array(days.suffix(30))).frame(width: 70, height: 22)
            }
        }
        .task { days = (try? await store.metricSeries(k.id)) ?? [] }
    }
}

struct Sparkline: View {
    let days: [DayValue]

    var body: some View {
        Chart(days) { LineMark(x: .value("Day", $0.day), y: .value("Value", $0.value)).interpolationMethod(.monotone).foregroundStyle(Theme.accent) }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
    }
}

struct TryRow: View {
    let r: ReportData
    let t: RTry

    var body: some View {
        let u = r.metric(t.lever)?.unit
        HStack(spacing: 6) {
            Text("\(t.more ? "More" : "Less") \(r.name(t.lever))").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Badge(robust: t.robust, strongLabel: "stronger evidence")
        }
        Muted(text: "Aim \(Units.span(t.aim.first ?? nil, t.aim.last ?? nil, u, weightUnit: r.weightUnit))"
              + " \(Self.per(t.horizon)) · your usual \(Units.format(t.usual, u, weightUnit: r.weightUnit))")
        Muted(text: t.targets.prefix(3).map { r.name($0.target) }.joined(separator: ", ")
              + (t.costs.isEmpty ? "" : " · \(t.costs.count) trade-off\(t.costs.count == 1 ? "" : "s")")).lineLimit(1)
    }

    static func per(_ h: String) -> String {
        ["day": "per day", "week": "per week", "month": "over 30 days", "quarter": "over 90 days"][h] ?? ""
    }
}

/// A suggestion: what it would change (each opening the lever -> outcome evidence) and its trade-offs.
struct SuggestionView: View {
    @EnvironmentObject var store: Store
    let r: ReportData
    let t: RTry

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                Card { TryRow(r: r, t: t) }
                InsightCard(page: .suggestion(lever: t.lever, more: t.more, horizon: t.horizon))
                Card(title: "Expected to improve") { ForEach(t.targets, id: \.self) { row($0) } }
                if !t.costs.isEmpty { Card(title: "Trade-offs") { ForEach(t.costs, id: \.self) { row($0) } } }
                Card { CardRow(route: .metric(t.lever)) { Text("About \(r.name(t.lever))").font(.system(size: 14)).foregroundStyle(Theme.text) } }
            }
            .reportPage()
        }
        .navigationTitle(r.name(t.lever))
        .navigationBarTitleDisplayMode(.inline)
        .task { store.prefetch((t.targets + t.costs).map { Route.pair(lever: t.lever, target: $0.target) } + [Route.metric(t.lever)]) }
    }

    private func row(_ x: RTarget) -> some View {
        let unit = x.percent == true ? "percent" : r.metric(x.target)?.unit
        return CardRow(route: .pair(lever: t.lever, target: x.target)) {
            Text(r.name(x.target)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Muted(text: "\(Units.signed(x.expected ?? 0, unit, weightUnit: r.weightUnit)) expected · "
                  // the slope in the suggested direction, so its sign matches the expected change
                  + String(format: "%+.2f SD per SD %@ · p = %.3f", (t.more ? 1 : -1) * (x.effect_sd ?? 0), t.more ? "more" : "less", x.p ?? 1)
                  + (x.trend.map { " · \($0)" } ?? ""))
        }
    }
}

/// Every metric with data, by domain then entity (app_catalog); and every relationship the report found. Searchable.
struct BrowseView: View {
    @EnvironmentObject var store: Store
    let r: ReportData
    @State private var search = ""
    @State private var mode = 0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                Picker("", selection: $mode) { Text("By entity").tag(0); Text("Relationships").tag(1) }.pickerStyle(.segmented)
                if mode == 0 {
                    if store.catalog.isEmpty { ProgressView().padding() }
                    let domains = Dictionary(grouping: store.catalog, by: \.domain).sorted { $0.key < $1.key }
                    ForEach(domains, id: \.key) { dom, groups in
                        let shown = groups.filter { g in search.isEmpty || g.title.localizedCaseInsensitiveContains(search)
                                                    || g.metrics.contains { $0.name.localizedCaseInsensitiveContains(search) } }
                        if !shown.isEmpty {
                            Card(title: dom.replacingOccurrences(of: "_", with: " ").capitalized) {
                                ForEach(shown) { g in
                                    CardRow(route: .entity(g)) {
                                        HStack {
                                            Text(g.title).font(.system(size: 14)).foregroundStyle(Theme.text)
                                            Spacer()
                                            Muted(text: "\(g.metrics.count)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    let shown = r.pairs.filter { search.isEmpty || r.name($0.a).localizedCaseInsensitiveContains(search)
                                                 || r.name($0.b).localizedCaseInsensitiveContains(search) }
                    Card(title: "Relationships", intro: "\(shown.count), strongest first") {
                        ForEach(shown.prefix(300)) { p in CardRow(route: .pair(lever: p.a, target: p.b)) { PairRow(r: r, p: p, focus: nil) } }
                    }
                }
            }
            .reportPage()
        }
        .searchable(text: $search)
        .navigationTitle("Explore")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadCatalog() }
    }
}

/// One entity's metrics.
struct EntityView: View {
    let r: ReportData
    let g: CatalogGroup

    var body: some View {
        ScrollView {
            Card(title: g.title, intro: "\(g.metrics.count) metrics with data in the last year") {
                ForEach(g.metrics) { m in
                    CardRow(route: .metric(m.id)) {
                        Text(m.name).font(.system(size: 14)).foregroundStyle(Theme.text)
                        Muted(text: "\(m.n) days" + (r.pairs(with: m.id).isEmpty ? "" : " · \(r.pairs(with: m.id).count) relationships")
                              + (r.key(m.id) != nil ? " · key metric" : "")).font(.system(size: 12))
                    }
                }
            }
            .reportPage()
        }
        .navigationTitle(g.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PairRow: View {
    let r: ReportData
    let p: RPair
    let focus: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let f = focus {
                Text(r.name(p.other(than: f))).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Muted(text: p.sign > 0 ? "rises with it" : p.sign < 0 ? "moves opposite" : "linked").font(.system(size: 12))
            } else {
                Text("\(r.name(p.a)) · \(r.name(p.b))").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
            }
            Spacer()
            Badge(robust: p.robust)
        }
        Muted(text: p.methods.joined(separator: ", ") + (p.methods.count > 1 ? " agree" : "")
              + ((p.disagree ?? []).isEmpty ? "" : " · \((p.disagree ?? []).joined(separator: ", ")) disagree")).font(.system(size: 12))
    }
}
