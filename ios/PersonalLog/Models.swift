import Foundation

/// A button from the server's `app` setting (public.app_config): kind `log`, `session` (start / stop) or `val` (an
/// amount, `value` suggested, in `unit`).
struct ButtonSpec: Codable, Hashable, Identifiable {
    let name: String
    let kind: String
    var unit: String?
    var value: Double?
    var id: String { name }
}

struct ButtonGroup: Codable, Hashable, Identifiable {
    let title: String
    let buttons: [ButtonSpec]
    var id: String { title }
}

/// public.app_config(): the buttons, the latest event per button and the sessions running now (UTC times).
struct AppConfig: Codable {
    var groups: [ButtonGroup] = []
    var last: [String: Date] = [:]
    var running: [String: Date] = [:]
    var foodShortcut: String = "Log Foods From App"
    var hiddenDomains: [String] = ["appearance"]   // left out of the Report tab
    var holidays: [String] = []                     // 'YYYY-MM-DD', counted as weekend days
    var dayType: DayTypeConfig?

    struct DayTypeConfig: Codable { var office_food: String?; var office_before: String?; var office_min_minutes: Int? }
    var officeFood: String { dayType?.office_food ?? "Office Food" }
    var officeMinMinutes: Int { dayType?.office_min_minutes ?? 20 }
    /// An arrival at Work from this time on (HH:mm) isn't an office day (an evening stop by).
    var officeBefore: (hour: Int, minute: Int) {
        let p = (dayType?.office_before ?? "14:00").split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 14, p.count > 1 ? p[1] : 0)
    }

    enum CodingKeys: String, CodingKey {
        case groups, last, running, foodShortcut = "food_shortcut", hiddenDomains = "hidden_domains", holidays, dayType = "day_type"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([ButtonGroup].self, forKey: .groups) ?? []
        last = try c.decodeIfPresent([String: Date].self, forKey: .last) ?? [:]
        running = try c.decodeIfPresent([String: Date].self, forKey: .running) ?? [:]
        foodShortcut = try c.decodeIfPresent(String.self, forKey: .foodShortcut) ?? "Log Foods From App"
        hiddenDomains = try c.decodeIfPresent([String].self, forKey: .hiddenDomains) ?? ["appearance"]
        holidays = try c.decodeIfPresent([String].self, forKey: .holidays) ?? []
        dayType = try? c.decodeIfPresent(DayTypeConfig.self, forKey: .dayType)
    }
}

/// public.macrofactor_recipes(): every recipe flattened to its foods, water and habit amounts.
struct RecipeItem: Codable, Hashable {
    let kind: String          // food | water | habit
    var name: String?         // food: its MacroFactor name
    var serving: String?
    var count: Double?
    var fl_oz: Double?        // water
    var prefix: String?       // habit: the event name
    var value: Double?
    var unit: String?
    var brand: String?        // food, from the MacroFactor history: for "Log by JSON"
    var per_g: [String: Double]?   // nutrients per gram, keyed and in the units of MacroFactor's JSON
    var grams: Double?        // grams in one `serving`

    /// MacroFactor's "Log by JSON" input for `count` servings (github.com/MacroFactor/apple-shortcuts): the food from
    /// its own data, so it logs even when it wasn't eaten lately. Nil without nutrients (then Find Recent Food).
    func macroFactorJSON(count: Double) -> String? {
        guard kind == "food", let name, let per_g, let grams, grams > 0, count > 0 else { return nil }
        let total = grams * count
        var food: [String: Any] = [
            "source": "personal-db-log-app", "icon": "foodDefault", "name": name,
            "nutrients": per_g.mapValues { ($0 * total * 1000).rounded() / 1000 },
            // one serving of the whole amount, labelled like "2 waffle", so the amount and its weight can't be misread
            "serving": ["amount": 1, "label": "\(Fmt.num(count)) \(serving ?? "serving")", "weight": (total * 10).rounded() / 10],
        ]
        if let brand, !brand.isEmpty { food["brand"] = brand }
        guard let data = try? JSONSerialization.data(withJSONObject: food, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct Recipe: Codable, Hashable {
    var category: String?
    var subcategory: String?  // the AI's second level under the category (none while the category is small)
    var score: Double?        // how much it is used lately (recency-weighted logs, macrofactor.recipe_score)
    var prompt: String?       // the recipe's own "how many" question (e.g. How many waffles?)
    let items: [RecipeItem]
}

struct RecipeBook: Codable {
    var names: [String] = []
    var categories: [String] = []   // display order
    var recipes: [String: Recipe] = [:]

    enum CodingKeys: String, CodingKey { case names, categories, recipes }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        recipes = try c.decodeIfPresent([String: Recipe].self, forKey: .recipes) ?? [:]
    }

    /// The ones used lately (score 1+, most used first, at most 6) and the rest (alphabetical).
    func usual(_ names: [String]) -> ([String], [String]) {
        let top = names.filter { (recipes[$0]?.score ?? 0) >= 1 }
            .sorted { (recipes[$0]?.score ?? 0) > (recipes[$1]?.score ?? 0) }
            .prefix(6)
        return (Array(top), names.filter { !top.contains($0) })
    }

    /// A category's recipes by subcategory (alphabetical; recipes in none last, under nil).
    func groups(_ names: [String]) -> [(String?, [String])] {
        let subs = Set(names.compactMap { recipes[$0]?.subcategory }).sorted()
        var out: [(String?, [String])] = subs.map { s in (s, names.filter { recipes[$0]?.subcategory == s }) }
        let rest = names.filter { recipes[$0]?.subcategory == nil }
        if !rest.isEmpty { out.append((nil, rest)) }
        return out
    }

    /// (category, its recipe names), in the server's category order; recipes in no listed category under Other.
    func sections(matching search: String) -> [(String, [String])] {
        let names = self.names.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        var order = categories
        for n in names {
            let c = recipes[n]?.category ?? "Other"
            if !order.contains(c) { order.append(c) }
        }
        return order.compactMap { c in
            let ns = names.filter { (recipes[$0]?.category ?? "Other") == c }
            return ns.isEmpty ? nil : (c, ns)
        }
    }
}

/// One event waiting to be sent (or sent): the body of public.ingest_event. `id` makes a re-send a duplicate.
struct OutEvent: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    let name: String
    let kind: String          // log | start | end | val
    let at: Date
    var val: Double = 0
    var unit: String?
    var sent = false

    var payload: [String: Any] {
        var p: [String: Any] = ["id": "app-" + id, "name": name, "kind": kind, "time": Fmt.iso(at), "val": val]
        if let unit { p["unit"] = unit }
        return p
    }
}

/// A day's logged events (public.app_events).
struct EventDay: Codable {
    let day: String
    let events: [LoggedEvent]
}

struct LoggedEvent: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let kind: String          // log | start | end | val
    let at: Date
    let value: Double?
    let unit: String?
    let editable: Bool
    let from: String          // app | sensor | other
    let guava: Bool

    var title: String { name + (kind == "start" ? " started" : kind == "end" ? " stopped" : "") }
}

enum Fmt {
    /// A count without trailing zeros: 2, 0.6, 1.25.
    static func num(_ x: Double) -> String {
        let s = String(format: "%.2f", x)
        return s.contains(".") ? String(s.reversed().drop { $0 == "0" }.reversed()).trimmingCharacters(in: CharacterSet(charactersIn: ".")) : s
    }

    /// ISO 8601 with the phone's offset, e.g. 2026-11-14T20:39:22-05:00.
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: now)
    }

    static func elapsed(since d: Date, now: Date = Date()) -> String {
        let m = max(0, Int(now.timeIntervalSince(d) / 60))
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    static func amount(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}
