import Foundation
import Network
import UIKit

/// The app's state: buttons and recipes (cached, refreshed from the server), the queue of events not yet sent (kept
/// on disk, so a tap with no signal is sent later), sessions running and the recent taps.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()   // the app and its Shortcuts actions (Intents.swift) share one
    @Published var creds = Credentials.load()
    @Published var config = AppConfig()
    @Published var recipes = RecipeBook()
    @Published var queue: [OutEvent] = []
    @Published var foodLogs: [FoodLog] = []         // recipes logged, not yet in the food log (food_logs.json)
    @Published var foodDay: FoodDay?                // today's food log (app_food_day)
    private var foodFlushing = false
    @Published var recent: [OutEvent] = []          // the last taps, newest first (sent or not)
    @Published var running: [String: Date] = [:]
    @Published var last: [String: Date] = [:]
    @Published var focusReports: [FocusReport] = []      // the Report tab's focused reports
    @Published var backdate: Date?                  // nil = now; set to log something that happened earlier
    @Published var message: String?
    @Published var refreshedAt: Date?
    @Published var report: ReportData?             // the latest report's browsable data (Report tab)
    @Published var reportDate: String?
    @Published var reportError: String?
    private var reportId: Int?
    private var reportFetching = false
    private var series: [Int: [DayValue]] = [:]      // app_metric, this session
    @Published var catalog: [CatalogGroup] = []      // app_catalog, this session
    private var prefetched = Set<InsightPage>()       // AI answers asked for ahead, this session

    private var flushing = false
    private let monitor = NWPathMonitor()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalLog", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        config = read("config.json") ?? AppConfig()
        recipes = read("recipes.json") ?? RecipeBook()
        queue = read("queue.json") ?? []
        foodLogs = read("food_logs.json") ?? []
        foodDay = read("food_day.json")
        recent = read("recent.json") ?? []
        running = config.running
        last = config.last
        applyQueue()
        if let meta: [String: String] = read("report_meta.json") {
            reportId = meta["id"].flatMap { Int($0) }
            reportDate = meta["date"]
            report = (try? Data(contentsOf: dir.appendingPathComponent("report_data.json")))
                .flatMap { try? JSONDecoder().decode(ReportData.self, from: $0) }?.pruned(hidden: config.hiddenDomains)
        }
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in await self?.flush(); await self?.flushFood() }
        }
        monitor.start(queue: DispatchQueue(label: "net"))
    }

    // MARK: taps

    /// The time a tap is logged at: now, or the picked earlier time (used once, then back to now).
    private func takeTime() -> Date {
        defer { backdate = nil }
        return backdate ?? Date()
    }

    func tap(_ b: ButtonSpec) {
        switch b.kind {
        case "session":
            if running[b.name] != nil { enqueue(OutEvent(name: b.name, kind: "end", at: takeTime())) }
            else { enqueue(OutEvent(name: b.name, kind: "start", at: takeTime())) }
        default:
            enqueue(OutEvent(name: b.name, kind: "log", at: takeTime()))
        }
    }

    func logAmount(_ b: ButtonSpec, _ amount: Double) {
        enqueue(OutEvent(name: b.name, kind: "val", at: takeTime(), val: amount, unit: b.unit))
    }

    func enqueue(_ e: OutEvent) {
        queue.append(e)
        recent.insert(e, at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
        applyQueue()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        save()
        Task { await flush() }
    }

    /// Takes back a tap that hasn't been sent yet.
    func cancel(_ e: OutEvent) {
        queue.removeAll { $0.id == e.id }
        recent.removeAll { $0.id == e.id }
        running = config.running
        last = config.last
        applyQueue()
        save()
    }

    /// The server's view plus the taps still queued, in order.
    private func applyQueue() {
        for e in queue.sorted(by: { $0.at < $1.at }) {
            if e.kind == "start" { running[e.name] = e.at }
            if e.kind == "end" { running[e.name] = nil }
            if (last[e.name] ?? .distantPast) < e.at { last[e.name] = e.at }
        }
    }

    // MARK: server

    func flush() async {
        guard !flushing, !queue.isEmpty, creds.isComplete else { return }
        flushing = true
        defer { flushing = false }
        let batch = queue
        do {
            let data = try await API(creds: creds).rpc("ingest_event", json: ["events": batch.map(\.payload)])
            let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard r["received"] != nil else { message = "Not accepted: \(String(data: data, encoding: .utf8) ?? "")"; return }
            let ids = Set(batch.map(\.id))
            queue.removeAll { ids.contains($0.id) }
            for i in recent.indices where ids.contains(recent[i].id) { recent[i].sent = true }
            if let rejected = r["rejected"] as? [[String: Any]], !rejected.isEmpty {
                message = "Rejected: " + rejected.map { "\($0["name"] ?? "?"): \($0["error"] ?? "")" }.joined(separator: "; ")
            } else {
                message = nil
            }
            save()
        } catch {
            message = "Queued (\(queue.count)): \(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard creds.isComplete else { return }
        let api = API(creds: creds)
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let hiddenBefore = config.hiddenDomains
            config = try dec.decode(AppConfig.self, from: try await api.rpc("app_config"))
            if config.hiddenDomains != hiddenBefore {   // the saved report again, with the new hidden domains
                report = (try? Data(contentsOf: dir.appendingPathComponent("report_data.json")))
                    .flatMap { try? JSONDecoder().decode(ReportData.self, from: $0) }?.pruned(hidden: config.hiddenDomains) ?? report
            }
            if let book = try? dec.decode(RecipeBook.self, from: try await api.rpc("macrofactor_recipes")) { recipes = book }
            running = config.running
            last = config.last
            applyQueue()
            refreshedAt = Date()
            if message?.hasPrefix("Queued") != true { message = nil }
            save()
        } catch {
            message = "Offline: \(error.localizedDescription)"
        }
    }

    /// The latest report's data: only downloaded when the server has a newer report than the copy on the phone.
    func refreshReport() async {
        guard creds.isComplete, !reportFetching else { return }
        reportFetching = true
        defer { reportFetching = false }
        do {
            var body: [String: Any] = [:]
            if let id = reportId, report != nil { body["p_known_id"] = id }
            let data = try await API(creds: creds).rpc("app_report", json: body)
            let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            reportError = nil
            guard let id = (r["id"] as? NSNumber)?.intValue else { return }
            if id != reportId { series = [:] }
            reportDate = r["report_date"] as? String
            if let d = r["data"] as? [String: Any], let raw = try? JSONSerialization.data(withJSONObject: d) {
                report = try JSONDecoder().decode(ReportData.self, from: raw).pruned(hidden: config.hiddenDomains)
                reportId = id
                try? raw.write(to: dir.appendingPathComponent("report_data.json"), options: .atomic)
            } else if id != reportId {
                report = nil   // a report from before the app data existed
                reportId = id
            }
            write("report_meta.json", ["id": String(id), "date": reportDate ?? ""])
        } catch {
            reportError = error.localizedDescription
        }
    }

    /// Every metric with data in the last year, by domain and entity (app_catalog), for browsing. Their names also go
    /// into the report's metric list, so any of them can be opened.
    func loadCatalog() async {
        guard catalog.isEmpty, creds.isComplete,
              let data = try? await API(creds: creds).rpc("app_catalog", json: ["p_days": 365]),
              let groups = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        catalog = groups.map { g in
            CatalogGroup(domain: g["domain"] as? String ?? "other", entity: g["entity"] as? String ?? "",
                         metrics: ((g["metrics"] as? [[String: Any]]) ?? []).compactMap { m in
                             guard let id = (m["id"] as? NSNumber)?.intValue else { return nil }
                             return CatalogMetric(id: id, key: m["key"] as? String ?? "", name: m["name"] as? String ?? "#\(id)",
                                                  unit: m["unit"] as? String, n: (m["n"] as? NSNumber)?.intValue ?? 0)
                         })
        }
        for g in catalog { for m in g.metrics where report?.metrics[String(m.id)] == nil {
            report?.metrics[String(m.id)] = RMetric(key: m.key, name: m.name, unit: m.unit, domain: g.domain, entity: g.entity)
        } }
    }

    /// The AI's take on a report page (the app-insight Edge Function). `cachedOnly`: the stored answer, or a status
    /// (none / pending / error); otherwise a new one is queued for the PC's Claude Code worker unless one is stored.
    func insight(_ page: InsightPage, cachedOnly: Bool, refresh: Bool = false) async throws -> Insight {
        var body: [String: Any] = page.body
        if cachedOnly { body["cached_only"] = true }
        if refresh { body["refresh"] = true }
        do {
            let data = try await API(creds: creds).function("app-insight", json: body, timeout: 30)
            return try JSONDecoder().decode(Insight.self, from: data)
        } catch let APIError.http(code, text) {
            let msg = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["error"] as? String
            throw APIError.http(code, msg ?? text)
        }
    }

    /// A question about one idea of a page's AI look: answered by the PC's Claude Code worker with the page's data, the
    /// AI look and the thread so far as context; stored, so the same question again is instant.
    func ask(_ page: InsightPage, section: String, question: String, thread: [(String, String)], cachedOnly: Bool) async throws -> AskAnswer {
        var body: [String: Any] = page.body
        body["ask"] = ["section": section, "question": question, "thread": thread.map { ["q": $0.0, "a": $0.1] }]
        if cachedOnly { body["cached_only"] = true }
        do {
            let data = try await API(creds: creds).function("app-insight", json: body, timeout: 30)
            return try JSONDecoder().decode(AskAnswer.self, from: data)
        } catch let APIError.http(code, text) {
            let msg = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["error"] as? String
            throw APIError.http(code, msg ?? text)
        }
    }

    /// Prepares the AI answers of the pages one tap away (queued behind the pages being looked at; skipped when
    /// answered or queued already). Each page is asked for once per session.
    func prefetch(_ routes: [Route]) {
        let pages = routes.compactMap(InsightPage.init(route:)).filter { prefetched.insert($0).inserted }
        guard !pages.isEmpty, creds.isComplete else { return }
        Task { _ = try? await API(creds: creds).function("app-insight", json: ["prefetch": pages.map(\.body)], timeout: 30) }
    }

    /// The PC's lost-item finder: its state, or start / stop it (app_finder).
    func finder(_ action: String?) async throws -> FinderState {
        var body: [String: Any] = [:]
        if let action { body["p_action"] = action }
        let data = try await API(creds: creds).rpc("app_finder", json: body)
        return try JSONDecoder().decode(FinderState.self, from: data)
    }

    /// A metric's daily values over the last year (app_metric), kept for the session.
    func metricSeries(_ id: Int) async throws -> [DayValue] {
        if let s = series[id] { return s }
        let data = try await API(creds: creds).rpc("app_metric", json: ["p_id": id, "p_days": 365])
        let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if report?.metrics[String(id)] == nil, let name = r["name"] as? String {   // a metric the report doesn't name
            report?.metrics[String(id)] = RMetric(key: r["key"] as? String ?? "", name: name, unit: r["unit"] as? String,
                                                  domain: r["domain"] as? String, entity: nil)
        }
        let rows = (r["days"] as? [[Any]]) ?? []
        let s = rows.compactMap { row -> DayValue? in
            guard row.count >= 2, let d = DayParse.day(row[0]), let v = DayParse.num(row[1]) else { return nil }
            return DayValue(day: d, value: v, filled: (row.count > 2 ? row[2] as? Bool : nil) ?? false)
        }
        series[id] = s
        return s
    }

    /// Both metrics on the days both were measured (app_pair): (day, lever that day, target, lever the day before).
    func pairDays(lever: Int, target: Int) async throws -> [(Date, Double?, Double, Double?)] {
        let data = try await API(creds: creds).rpc("app_pair", json: ["p_a": lever, "p_b": target, "p_days": 365])
        let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((r["days"] as? [[Any]]) ?? []).compactMap { row in
            guard row.count >= 4, let d = DayParse.day(row[0]), let y = DayParse.num(row[2]) else { return nil }
            return (d, DayParse.num(row[1]), y, DayParse.num(row[3]))
        }
    }

    // MARK: MacroFactor

    /// Logs a recipe: habit amounts go straight to the database; the foods and water go to the Shortcut (only a Shortcut
    /// can call MacroFactor's Log Foods), which comes back to the app when done.
    func logRecipe(_ name: String, servings: Double) -> URL? {
        guard recipes.recipes[name] != nil else { return nil }
        let at = takeTime()
        // our food log first (queued, sent when online); MacroFactor gets a copy while the two are compared
        foodLogs.append(FoodLog(name: name, servings: servings, at: at))
        write("food_logs.json", foodLogs)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let api = API(creds: creds)
        Task { _ = try? await api.rpc("app_recipe_used", json: ["p_name": name]) }   // for the usual-first order
        Task { await flushFood() }
        guard let text = recipeInput(name, servings: servings, at: at) else { return nil }
        return (foodDay?.mirror_macrofactor ?? false) || recipeHasWater(name) ? shortcutURL(config.foodShortcut, input: text) : nil
    }

    /// Water still goes to Apple Health through the Shortcut.
    private func recipeHasWater(_ name: String) -> Bool {
        recipes.recipes[name]?.items.contains { $0.kind == "water" } ?? false
    }

    /// Calories of the logs not sent yet (so Today counts them already).
    var pendingFoodEnergy: Double {
        foodLogs.reduce(0) { sum, l in
            sum + (recipes.recipes[l.name]?.items ?? []).reduce(0) { s, it in
                guard it.kind == "food", let g = it.grams, let kcal = it.per_g?["energy"] else { return s }
                return s + kcal * g * (it.count ?? 1) * l.servings
            }
        }
    }

    /// Sends the queued food logs, oldest first; a log the server refuses (a recipe gone) is dropped with a message.
    func flushFood() async {
        guard !foodFlushing, !foodLogs.isEmpty, creds.isComplete else { return }
        foodFlushing = true
        defer { foodFlushing = false }
        let api = API(creds: creds)
        for l in foodLogs {
            do {
                _ = try await api.rpc("app_food_log", json: ["p_name": l.name, "p_servings": l.servings,
                                                             "p_at": Fmt.iso(l.at), "p_log_id": l.id, "p_source": l.source])
                foodLogs.removeAll { $0.id == l.id }
            } catch APIError.http(let code, let body) where (400..<500).contains(code) && code != 401 && code != 408 {
                foodLogs.removeAll { $0.id == l.id }
                message = "Food log refused \(l.name): \(body.prefix(120))"
            } catch {
                break   // offline or the server is busy: the rest wait too
            }
        }
        write("food_logs.json", foodLogs)
        await loadFoodDay()
    }

    /// The server's ISO times, with or without fractions of a second.
    static let isoDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let t = f.date(from: s) { return t }
            f.formatOptions = [.withInternetDateTime]
            if let t = f.date(from: s) { return t }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "date \(s)"))
        }
        return dec
    }()

    func loadFoodDay() async {
        guard let d = await fetchFoodDay(nil) else { return }
        foodDay = d
        write("food_day.json", foodDay)
    }

    /// One day's food log (public.app_food_day; nil = today, by the day boundary).
    func fetchFoodDay(_ day: String?) async -> FoodDay? {
        guard creds.isComplete,
              let data = try? await API(creds: creds).rpc("app_food_day", json: day.map { ["p_day": $0] } ?? [:])
        else { return nil }
        do {
            return try Self.isoDecoder.decode(FoodDay.self, from: data)
        } catch {
            message = "Food: \(error.localizedDescription)"
            return nil
        }
    }

    /// One day's logged events (public.app_events; nil = today, by the day boundary).
    func fetchEvents(_ day: String?, all: Bool = false) async -> EventDay? {
        var args: [String: Any] = ["p_all": all]
        if let day { args["p_day"] = day }
        guard creds.isComplete,
              let data = try? await API(creds: creds).rpc("app_events", json: args)
        else { return nil }
        do {
            return try Self.isoDecoder.decode(EventDay.self, from: data)
        } catch {
            message = "History: \(error.localizedDescription)"
            return nil
        }
    }

    /// Logs anything at a past time (public.app_event_add): kind log (once), val (an amount) or session (start and end).
    func addEvent(name: String, kind: String, at: Date, end: Date? = nil, value: Double? = nil, unit: String? = nil,
                  notes: String? = nil) async -> String? {
        var args: [String: Any] = ["p_name": name, "p_kind": kind, "p_at": Fmt.iso(at)]
        if let end { args["p_end_at"] = Fmt.iso(end) }
        if let value { args["p_value"] = value }
        if let unit, !unit.isEmpty { args["p_unit"] = unit }
        if let notes, !notes.isEmpty { args["p_notes"] = notes }
        do {
            _ = try await API(creds: creds).rpc("app_event_add", json: args)
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The focused reports (public.app_focus_list).
    func loadFocusReports() async {
        guard creds.isComplete, let data = try? await API(creds: creds).rpc("app_focus_list"),
              let list = try? JSONDecoder().decode([FocusReport].self, from: data) else { return }
        focusReports = list
    }

    /// Adds (id nil) or changes a focused report; nil, or the error.
    func saveFocus(id: Int?, title: String, question: String) async -> String? {
        var args: [String: Any] = ["p_title": title, "p_question": question]
        if let id { args["p_id"] = id }
        do {
            _ = try await API(creds: creds).rpc("app_focus_save", json: args)
            await loadFocusReports()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deleteFocus(_ id: Int) async -> String? {
        do {
            _ = try await API(creds: creds).rpc("app_focus_save", json: ["p_id": id, "p_delete": true])
            await loadFocusReports()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The ideas and feature requests (public.app_features).
    func fetchFeatures() async -> [Feature] {
        guard creds.isComplete, let data = try? await API(creds: creds).rpc("app_features", json: [:]) else { return [] }
        return (try? Self.isoDecoder.decode([Feature].self, from: data)) ?? []
    }

    /// Add, change or delete an idea (public.app_feature_save); nil when saved, else the error.
    func saveFeature(_ p: [String: Any]) async -> String? {
        do {
            _ = try await API(creds: creds).rpc("app_feature_save", json: ["p": p])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Delete a logged event, or change its time / value; nil when saved, else the error.
    func editEvent(_ id: Int, delete: Bool = false, at: Date? = nil, value: Double? = nil,
                   name: String? = nil, notes: String? = nil) async -> String? {
        var args: [String: Any] = ["p_id": id, "p_delete": delete]
        if let at { args["p_at"] = Fmt.iso(at) }
        if let value { args["p_value"] = value }
        if let name { args["p_name"] = name }
        if let notes { args["p_notes"] = notes }
        do {
            _ = try await API(creds: creds).rpc("app_event_edit", json: args)
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deleteFood(log: String? = nil, entry: Int? = nil) async {
        var args: [String: Any] = [:]
        if let log { args["p_log_id"] = log }
        if let entry { args["p_entry_id"] = entry }
        _ = try? await API(creds: creds).rpc("app_food_delete", json: args)
        await loadFoodDay()
    }

    /// A log's servings (every food and its water scaled), or one food's amount; nil when saved, else the error.
    func editFood(log: String? = nil, servings: Double? = nil, entry: Int? = nil, count: Double? = nil) async -> String? {
        var args: [String: Any] = [:]
        if let log { args["p_log_id"] = log }
        if let servings { args["p_servings"] = servings }
        if let entry { args["p_entry_id"] = entry }
        if let count { args["p_count"] = count }
        do {
            _ = try await API(creds: creds).rpc("app_food_edit", json: args)
            await loadFoodDay()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// nil when saved, else the error.
    func setFoodTargets(_ t: [String: Any]) async -> String? {
        do {
            _ = try await API(creds: creds).rpc("app_food_target", json: ["p_target": t])
            await loadFoodDay()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The Shortcut's input for a recipe (its habit amounts are queued here); nil without foods or water.
    func recipeInput(_ name: String, servings: Double, at: Date) -> String? {
        guard let recipe = recipes.recipes[name] else { return nil }
        // off MacroFactor (food.mirror_macrofactor false): the Shortcut only takes the water to Apple Health
        let mirror = foodDay?.mirror_macrofactor ?? false
        var items: [[String: Any]] = []
        for it in recipe.items {
            switch it.kind {
            case "food":
                guard mirror else { continue }
                let count = (it.count ?? 1) * servings
                var line: [String: Any] = ["kind": "food", "name": it.name ?? "", "serving": it.serving ?? "", "count": count]
                if let mf = it.macroFactorJSON(count: count) { line["mf"] = mf }   // the Shortcut logs it by JSON
                items.append(line)
            case "water":
                let oz = (it.fl_oz ?? 0) * servings
                items.append(["kind": "water", "fl_oz": oz, "ml": (oz * 29.5735).rounded()])   // Apple Health, in mL
            default:
                if let p = it.prefix {
                    enqueue(OutEvent(name: p, kind: "val", at: at, val: (it.value ?? 0) * servings, unit: it.unit))
                }
            }
        }
        guard !items.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: ["recipe": name, "time": Fmt.iso(at), "items": items]),
              let text = String(data: json, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: office day (Intents.swift; iOS automations)

    /// Today's stays at Work as [start, end] (end 0 while there), from the Arrive / Leave automations.
    private var workStays: [[Double]] {
        get {
            guard UserDefaults.standard.string(forKey: "workStaysDay") == dayKey(Date()) else { return [] }
            return UserDefaults.standard.array(forKey: "workStays") as? [[Double]] ?? []
        }
        set {
            UserDefaults.standard.set(dayKey(Date()), forKey: "workStaysDay")
            UserDefaults.standard.set(newValue, forKey: "workStays")
        }
    }

    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func arrivedAtWork(now: Date = Date()) { workStays.append([now.timeIntervalSince1970, 0]) }

    func leftWork(now: Date = Date()) {
        var s = workStays
        if let i = s.indices.last, s[i][1] == 0 { s[i][1] = now.timeIntervalSince1970; workStays = s }
    }

    /// The "Office Food" action (a weekday time automation, e.g. 10:00, then Run Shortcut Log Foods From App with its
    /// result): on a working day (not Saturday, Sunday or one of the `holidays`), once a stay at Work that began before
    /// `day_type.office_before` (14:00) has lasted `office_min_minutes` (20; walking by isn't an office day), logs
    /// Office at that arrival (unless logged today) and, once a day, returns the office food (`day_type.office_food`)
    /// as the Shortcut's input. MacroFactor logs it at the current time. Otherwise an empty list of items.
    func officeFood(now: Date = Date()) -> String {
        let none = #"{"items": []}"#
        let day = dayKey(now)
        if Calendar.current.isDateInWeekend(now) || config.holidays.contains(day) { return none }
        let cutoff = (Calendar.current.date(bySettingHour: config.officeBefore.hour, minute: config.officeBefore.minute,
                                            second: 0, of: now) ?? now).timeIntervalSince1970
        let minStay = Double(config.officeMinMinutes * 60)
        guard let stay = workStays.first(where: { $0[0] < cutoff && ($0[1] == 0 ? now.timeIntervalSince1970 : $0[1]) - $0[0] >= minStay })
        else { return none }
        let arrived = Date(timeIntervalSince1970: stay[0])
        if !(last["Office"].map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false) {
            enqueue(OutEvent(name: "Office", kind: "log", at: arrived))
        }
        guard UserDefaults.standard.string(forKey: "officeFoodDay") != day,
              let text = recipeInput(config.officeFood, servings: 1, at: now) else { return none }
        UserDefaults.standard.set(day, forKey: "officeFoodDay")
        foodLogs.append(FoodLog(name: config.officeFood, servings: 1, at: now, source: "office"))
        write("food_logs.json", foodLogs)
        Task { await flushFood() }
        return (foodDay?.mirror_macrofactor ?? false) || recipeHasWater(config.officeFood) ? text : none
    }

    private func shortcutURL(_ shortcut: String, input: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let q = ["name=" + enc(shortcut), "input=text", "text=" + enc(input),
                 "x-success=" + enc("personallog://food-done"), "x-cancel=" + enc("personallog://food-cancel"),
                 "x-error=" + enc("personallog://food-error")]
        return URL(string: "shortcuts://x-callback-url/run-shortcut?" + q.joined(separator: "&"))
    }

    func handle(url: URL) {
        switch url.host {
        case "food-done": message = "Logged in MacroFactor"
        case "food-cancel": message = "MacroFactor logging cancelled"
        case "food-error": message = "The Shortcut failed: is \"\(config.foodShortcut)\" set up?"
        default: break
        }
    }

    // MARK: settings / storage

    func saveCredentials(_ c: Credentials) async {
        c.save()
        creds = Credentials.load()
        await refresh()
        await flush()
    }

    private func save() {
        write("config.json", config)
        write("recipes.json", recipes)
        write("queue.json", queue)
        write("recent.json", recent)
    }

    private func read<T: Decodable>(_ file: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ file: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
        }
    }
}
