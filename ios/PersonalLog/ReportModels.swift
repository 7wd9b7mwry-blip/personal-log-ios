import Foundation

/// analysis.report.data (report.app_data in analysis/report.py): the report's findings as data. Metrics are ids,
/// described once in `metrics`.
struct ReportData: Codable {
    var date: String?
    var keyMetrics: [RKey] = []
    var tries: [RTry] = []
    var timing: [RTiming] = []
    var pairs: [RPair] = []
    var metrics: [String: RMetric] = [:]
    var ai: RAI?
    var review: RReview?
    var weightUnit = "lb"

    enum CodingKeys: String, CodingKey {
        case date, timing, pairs, metrics, ai, review
        case keyMetrics = "key_metrics", tries = "try", weightUnit = "weight_unit"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        keyMetrics = try c.decodeIfPresent([RKey].self, forKey: .keyMetrics) ?? []
        tries = try c.decodeIfPresent([RTry].self, forKey: .tries) ?? []
        timing = try c.decodeIfPresent([RTiming].self, forKey: .timing) ?? []
        pairs = try c.decodeIfPresent([RPair].self, forKey: .pairs) ?? []
        metrics = try c.decodeIfPresent([String: RMetric].self, forKey: .metrics) ?? [:]
        ai = try c.decodeIfPresent(RAI.self, forKey: .ai)
        review = try? c.decodeIfPresent(RReview.self, forKey: .review)
        weightUnit = try c.decodeIfPresent(String.self, forKey: .weightUnit) ?? "lb"
    }

    /// Without the metrics of hidden domains (the app setting's hidden_domains) and every finding naming one.
    func pruned(hidden: [String]) -> ReportData {
        guard !hidden.isEmpty else { return self }
        var r = self
        r.metrics = metrics.filter { !hidden.contains($0.value.domain ?? "") }
        let ok: (Int) -> Bool = { r.metrics[String($0)] != nil }
        r.pairs = pairs.filter { ok($0.a) && ok($0.b) }
        r.keyMetrics = keyMetrics.filter { ok($0.id) }.map { k in
            var k = k
            k.drivers = k.drivers.filter { ok($0.lever) }
            k.curves = k.curves.filter { ok($0.lever) }
            return k
        }
        r.tries = tries.filter { ok($0.lever) }.map { t in
            var t = t
            t.targets = t.targets.filter { ok($0.target) }
            t.costs = t.costs.filter { ok($0.target) }
            return t
        }.filter { !$0.targets.isEmpty }
        r.timing = timing.filter { ok($0.target) }
        return r
    }

    func metric(_ id: Int) -> RMetric? { metrics[String(id)] }
    func name(_ id: Int) -> String { metric(id)?.name ?? "#\(id)" }
    func key(_ id: Int) -> RKey? { keyMetrics.first { $0.id == id } }
    func pairs(with id: Int) -> [RPair] { pairs.filter { $0.a == id || $0.b == id } }
    func pair(_ x: Int, _ y: Int) -> RPair? { pairs.first { ($0.a == x && $0.b == y) || ($0.a == y && $0.b == x) } }
    /// Key metrics this metric drives (it is one of their drivers).
    func drives(_ id: Int) -> [REffect] { keyMetrics.flatMap { $0.drivers.filter { $0.lever == id } } }
    func driver(_ lever: Int, _ target: Int) -> REffect? { key(target)?.drivers.first { $0.lever == lever } }

    /// Every metric named anywhere, by domain, for browsing.
    var byDomain: [(String, [Int])] {
        var d: [String: [Int]] = [:]
        for (k, m) in metrics { if let id = Int(k) { d[m.domain ?? "other", default: []].append(id) } }
        return d.keys.sorted().map { dom in (dom, d[dom]!.sorted { name($0) < name($1) }) }
    }
}

struct RMetric: Codable, Hashable {
    let key: String
    let name: String
    var unit: String?
    var domain: String?
    var entity: String?
}

/// app_catalog: metrics with data, by domain and entity.
struct CatalogGroup: Identifiable, Hashable {
    let domain: String
    let entity: String
    let metrics: [CatalogMetric]
    var id: String { domain + "/" + entity }
    /// A server-given name (has capitals: "HRV", "Duration & wake") as it is; a raw entity key title-cased.
    var title: String {
        entity.rangeOfCharacter(from: .uppercaseLetters) != nil ? entity : entity.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct CatalogMetric: Identifiable, Hashable {
    let id: Int
    let key: String
    let name: String
    var unit: String?
    let n: Int
}

/// Which page the AI looks at (app-insight).
enum InsightPage: Hashable {
    case home, metric(Int), pair(Int, Int), suggestion(lever: Int, more: Bool, horizon: String), focus(Int)

    var body: [String: Any] {
        switch self {
        case .home: return ["page": "home"]
        case let .metric(id): return ["page": "metric", "id": id]
        case let .pair(lever, target): return ["page": "pair", "lever": lever, "target": target]
        case let .suggestion(lever, more, horizon): return ["page": "try", "lever": lever, "more": more, "horizon": horizon]
        case let .focus(id): return ["page": "focus", "id": id]
        }
    }
}

extension InsightPage {
    init?(route: Route) {
        switch route {
        case let .metric(id): self = .metric(id)
        case let .pair(lever, target): self = .pair(lever, target)
        case let .suggestion(t): self = .suggestion(lever: t.lever, more: t.more, horizon: t.horizon)
        default: return nil
        }
    }
}

struct Insight: Decodable, Hashable {
    var headline: String?
    var sections: [ISection]?
    var insights: [String]?
    var caveats: [String]?
    var look_at: [Look]?
    var cached: Bool?
    var none: Bool?          // nothing stored yet
    var queued: Bool?        // just asked for: the PC's Claude Code worker is making it
    var pending: Bool?       // being made
    var error: String?       // the last attempt failed
    var model: String?
    var cached_at: String?
    var upgrading: Bool?     // written before follow-up questions existed: a rewrite is coming

    var ready: Bool { none != true && queued != true && headline != nil }
}

/// A focused report an overview idea comes from (its id and title).
struct FromFocus: Decodable, Hashable {
    let id: Int
    let title: String
}

/// One idea the AI found: its type, a short title and reasoning, and the trends / relationships to open for it.
struct ISection: Decodable, Hashable {
    let type: String          // pattern | trend | hypothesis | test | watch
    let title: String
    var reason: String?
    var items: [Look] = []
    var followups: [String]?   // questions worth asking next about this idea
    var from: FromFocus?       // the overview's: the perspective report it comes from

    var label: String {
        ["pattern": "Pattern", "trend": "Trend", "hypothesis": "Hypothesis", "test": "Worth testing", "watch": "Watch"][type] ?? type.capitalized
    }

}

/// The answer to a question about one idea of a page's AI look (app-insight "ask").
struct AskAnswer: Decodable, Hashable {
    var question: String?
    var answer: String?
    var points: [String]?
    var items: [Look]?
    var followups: [String]?
    var none: Bool?
    var queued: Bool?
    var pending: Bool?
    var error: String?

    var ready: Bool { answer != nil }
}

struct Look: Decodable, Hashable {
    let kind: String
    var id: Int?
    var lever: Int?
    var target: Int?
    var title: String?       // the reason it is worth a look
    var why: String          // what to check, with inline links

    var route: Route? {
        if kind == "metric", let id { return .metric(id) }
        if kind == "pair", let lever, let target { return .pair(lever: lever, target: target) }
        return nil
    }
}

struct REffect: Codable, Hashable, Identifiable {
    let lever: Int
    let target: Int
    var target_key: String?
    var horizon: String?
    let lag: Int
    var effect_sd: Double?
    var p: Double?
    var q: Double?
    var n: Int?
    var n_controls: Int?
    var factor: Bool?
    var good: Bool?
    var id: String { "\(lever)-\(target)-\(lag)-\(horizon ?? "")" }
    var robust: Bool { (q ?? 1) < 0.1 }
}

struct RCurve: Codable, Hashable {
    let lever: Int
    let lag: Int
    let kind: String
    var vertex: Double?
    var p: Double?
}

struct RWeekday: Codable, Hashable {
    let best: Int
    let worst: Int
    let means: [Double?]
    var p: Double?
    var q: Double?
}

struct RKey: Codable, Hashable, Identifiable {
    let id: Int
    var goal: String?
    var drivers: [REffect] = []
    var curves: [RCurve] = []
    var weekday: [RWeekday] = []
}

struct RTarget: Codable, Hashable {
    let target: Int
    var target_key: String?
    var expected: Double?
    var effect_sd: Double?
    var p: Double?
    var support: [String]?
    var trend: String?
    var percent: Bool?
}

struct RTry: Codable, Hashable, Identifiable {
    let lever: Int
    let more: Bool
    let horizon: String
    let aim: [Double?]
    var usual: Double?
    let robust: Bool
    var targets: [RTarget] = []
    var costs: [RTarget] = []
    var id: String { "\(lever)-\(more)-\(horizon)" }
}

struct RTiming: Codable, Hashable, Identifiable {
    let habit: String
    let target: Int
    var span_from: Double?
    var span_to: Double?
    var typical_effect: Double?
    var typical_amount: String?
    let helps: Bool
    var q: Double?
    var n_span: Int?
    var id: String { "\(habit)-\(target)-\(span_from ?? 0)" }
}

struct REvidence: Codable, Hashable {
    let kind: String
    let robust: Bool
    let sign: Int
    var weight: Double?
    let text: String
}

struct RPair: Codable, Hashable, Identifiable {
    let a: Int
    let b: Int
    let robust: Bool
    let sign: Int
    let methods: [String]   // the methods agreeing with the direction
    var disagree: [String]? = nil   // the ones pointing the other way
    let evidence: [REvidence]
    var id: String { "\(a)-\(b)" }
    func other(than id: Int) -> Int { a == id ? b : a }
}

/// The daily review (analysis/ai_review.py): the report and the system reviewed: findings, data problems,
/// improvements, ideas, next steps.
struct RReview: Codable, Hashable {
    var headline: String = ""
    var sections: [Section] = []
    /// The issue log as of this report (analysis.review_issue): every open issue and the ones fixed that day.
    var issues: [RIssue]?

    struct Section: Codable, Hashable {
        let type: String
        var title: String = ""
        var items: [Item] = []

        var label: String {
            ["finding": "Finding", "data": "Data", "improvement": "Improvement", "idea": "Idea", "next": "Next step"][type] ?? type.capitalized
        }
    }

    struct Item: Codable, Hashable {
        let title: String
        var note: String = ""
        var status: String = "new"
    }
}

/// A problem the daily review keeps across days: how old it is, on how many days it showed up, an example per day and
/// what changed.
struct RIssue: Codable, Hashable, Identifiable {
    let id: Int
    let title: String
    var kind: String?
    var status: String?
    var firstSeen: String?
    var lastSeen: String?
    var daysSeen: Int?
    var ageDays: Int?
    var isNew: Bool?
    var seenToday: Bool?
    var change: String?
    var examples: [Note]?
    var history: [Event]?

    struct Note: Codable, Hashable { let date: String; var note: String = "" }
    struct Event: Codable, Hashable { let date: String; let status: String; var note: String? }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, status, change, examples, history
        case firstSeen = "first_seen", lastSeen = "last_seen", daysSeen = "days_seen", ageDays = "age_days"
        case isNew = "new", seenToday = "seen_today"
    }

    var fixed: Bool { status == "fixed" }
    var kindLabel: String { ["bug": "Bug", "data": "Data", "method": "Method", "display": "Display"][kind ?? ""] ?? (kind ?? "").capitalized }

    /// "new today", "fixed today", "open 6 days, seen on 5" (+ "last Nov 12" when not in today's report).
    var state: String {
        if fixed { return "fixed today" }
        if isNew == true { return "new today" }
        let age = "open \((ageDays ?? 0) + 1) days, seen on \(daysSeen ?? 1)"
        return seenToday == true ? age : "\(age), last \(RIssue.short(lastSeen))"
    }

    static func short(_ day: String?) -> String {
        guard let d = DayParse.day(day) else { return day ?? "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}

struct RAI: Codable, Hashable {
    let headline: String
    var bullets: [String] = []
    var tries: [String] = []
    var watch: [String] = []
}

/// Where a drill-down goes. As a URL (the AI's inline links): pdb://m/<id>, pdb://p/<lever>/<target>.
enum Route: Hashable {
    case metric(Int)
    case pair(lever: Int, target: Int)
    case suggestion(RTry)
    case browse
    case entity(CatalogGroup)
    case focus(FocusReport)

    init?(url: URL) {
        guard url.scheme == "pdb" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }.compactMap { Int($0) }
        switch url.host {
        case "m" where parts.count == 1: self = .metric(parts[0])
        case "p" where parts.count == 2: self = .pair(lever: parts[0], target: parts[1])
        default: return nil
        }
    }

    var url: URL? {
        switch self {
        case let .metric(id): return URL(string: "pdb://m/\(id)")
        case let .pair(lever, target): return URL(string: "pdb://p/\(lever)/\(target)")
        default: return nil
        }
    }
}

enum Units {
    /// Like report.fmt: durations as h / min, kg as lb, percent, counts and scores whole.
    static func format(_ v: Double?, _ unit: String?, weightUnit: String = "lb") -> String {
        guard let v, v.isFinite else { return "–" }
        let u = unit ?? ""
        switch u {
        case "kg": return weightUnit == "lb" ? String(format: "%.1f lb", v * 2.20462) : String(format: "%.1f kg", v)
        case "s":
            let a = abs(v), sign = v < 0 ? "-" : ""
            if a >= 3600 { let m = Int((a / 60).rounded()); return "\(sign)\(m / 60)h \(String(format: "%02d", m % 60))m" }
            if a < 600 { let s = Int(a.rounded()); return s >= 60 ? "\(sign)\(s / 60)m \(String(format: "%02d", s % 60))s" : "\(sign)\(s) s" }
            return "\(sign)\(Int((a / 60).rounded())) min"
        case "h": return clock(v)
        case "celsius": return String(format: "%.2f °C", v)
        case "percent", "%": return String(format: "%.1f%%", v)
        case "count", "score", "integer", "ordinal": return String(format: "%.0f", v)
        case "bpm": return String(format: "%.0f bpm", v)
        case "ms": return String(format: "%.0f ms", v)
        case "ratio": return String(format: "%.3f", v)
        case "boolean": return v >= 0.5 ? "yes" : "no"
        case "breaths_per_min", "breaths/min": return String(format: "%.1f breaths/min", v)
        case "", "level": return String(format: "%.1f", v)   // a setting / sensor level reads as a number
        default: return String(format: "%.1f %@", v, label(u))
        }
    }

    /// Hours after midnight as a clock time, like report.clock; past 24 is after midnight (27.4 -> 3:24 AM).
    static func clock(_ h: Double) -> String {
        let m = ((Int((h * 60).rounded()) % 1440) + 1440) % 1440
        return "\((m / 60) % 12 == 0 ? 12 : (m / 60) % 12):\(String(format: "%02d", m % 60)) \(m < 720 ? "AM" : "PM")"
    }

    /// A change with its sign, like report.Ctx.signed: a clock time's change as a duration.
    static func signed(_ v: Double, _ unit: String?, weightUnit: String = "lb") -> String {
        let (x, u) = unit == "h" ? (v * 3600, "s") : (v, unit)
        return (x >= 0 ? "+" : "−") + format(abs(x), u, weightUnit: weightUnit)
    }

    /// A range lo–hi, one value when both ends read the same ("4", not "4–4"), like report.Ctx.span.
    static func span(_ lo: Double?, _ hi: Double?, _ unit: String?, weightUnit: String = "lb") -> String {
        let a = format(lo, unit, weightUnit: weightUnit), b = format(hi, unit, weightUnit: weightUnit)
        return a == b ? a : "\(a)–\(b)"
    }

    /// A unit key as a label: ml_per_kg_min -> ml/kg/min, breaths_per_min -> breaths/min, finger_widths -> finger widths.
    static func label(_ u: String) -> String {
        if let named = ["fl_oz_us": "fl oz", "fahrenheit": "°F", "degrees": "°", "deg": "°"][u] { return named }
        let per = u.replacingOccurrences(of: "_per_", with: "/")
        return per.replacingOccurrences(of: "_", with: per.contains("/") ? "/" : " ")
    }

    /// The factor and label for a chart axis (seconds in h or min, kg in lb).
    static func axis(_ unit: String?, values: [Double], weightUnit: String = "lb") -> (Double, String) {
        switch unit ?? "" {
        case "s":
            let mid = values.sorted()[values.count / 2]
            return mid >= 3600 ? (1.0 / 3600, "h") : (1.0 / 60, "min")
        case "kg": return weightUnit == "lb" ? (2.20462, "lb") : (1, "kg")
        default: return (1, label(unit ?? ""))
        }
    }
}

/// app_metric / app_pair rows: [day, value, ...] arrays.
struct DayValue: Identifiable, Hashable {
    let day: Date
    let value: Double
    var filled = false
    var id: Date { day }
}

enum DayParse {
    static let f: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func day(_ s: Any?) -> Date? { (s as? String).flatMap { f.date(from: $0) } }
    static func num(_ x: Any?) -> Double? { (x as? NSNumber)?.doubleValue }
}
