import EventKit
import SwiftUI

/// One chore from public.app_chores(): how often (every N days, on weekdays, once, or when a sensor says so), when
/// (after / by a clock time), where, what goes first, and its state (last done, deferred).
struct Chore: Identifiable, Hashable {
    var id: Int?
    var name = ""
    var room = ""
    var minutes = 10
    var everyDays: Double?
    var weekdays: [Int] = []          // ISO: 1 = Monday
    var dueDate: Date?
    var afterTime: String?            // HH:mm
    var byTime: String?
    var priority = "normal"           // must | normal | low
    var dependsOn: [String] = []
    var doneEvent = ""
    var source = "user"               // user | sensor (set up from a sensor; its trigger stays)
    var active = true
    var notes = ""
    var lastDone: Date?
    var deferredUntil: Date?

    var isSensor: Bool { source == "sensor" }

    /// How often, in words.
    var schedule: String {
        if isSensor { return notes.isEmpty ? "when its sensor says so" : notes }
        if !weekdays.isEmpty {
            let names = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            return weekdays.sorted().map { names[$0] }.joined(separator: ", ")
        }
        if let n = everyDays { return n == 1 ? "daily" : n == 7 ? "weekly" : "every \(Fmt.amount(n)) days" }
        if let d = dueDate { return "once, by " + d.formatted(.dateTime.weekday(.abbreviated).month().day()) }
        return "once"
    }

    init() {}

    init(_ j: [String: Any]) {
        id = (j["id"] as? NSNumber)?.intValue
        name = j["name"] as? String ?? ""
        room = j["room"] as? String ?? ""
        minutes = (j["minutes"] as? NSNumber)?.intValue ?? 10
        everyDays = (j["every_days"] as? NSNumber)?.doubleValue
        weekdays = (j["weekdays"] as? [NSNumber])?.map(\.intValue) ?? []
        dueDate = (j["due_date"] as? String).flatMap(ChoreTime.day)
        afterTime = (j["after_time"] as? String).map(ChoreTime.short)
        byTime = (j["by_time"] as? String).map(ChoreTime.short)
        priority = j["priority"] as? String ?? "normal"
        dependsOn = j["depends_on"] as? [String] ?? []
        doneEvent = j["done_event"] as? String ?? ""
        source = j["source"] as? String ?? "user"
        active = j["active"] as? Bool ?? true
        notes = j["notes"] as? String ?? ""
        lastDone = (j["last_done"] as? String).flatMap(ChoreTime.instant)
        deferredUntil = (j["deferred_until"] as? String).flatMap(ChoreTime.instant)
    }

    /// The body of public.app_chore_save.
    var payload: [String: Any] {
        var p: [String: Any] = ["name": name, "room": room, "minutes": minutes, "priority": priority,
                                "weekdays": weekdays, "depends_on": dependsOn, "done_event": doneEvent,
                                "active": active, "notes": notes]
        if let id { p["id"] = id }
        p["every_days"] = everyDays.map { $0 as Any } ?? ""
        p["due_date"] = dueDate.map(ChoreTime.dayString) ?? ""
        p["after_time"] = afterTime ?? ""
        p["by_time"] = byTime ?? ""
        return p
    }
}

/// A chore placed in the plan.
struct PlanItem: Identifiable, Hashable {
    let choreId: Int
    let name: String
    let room: String?
    let minutes: Int
    let priority: String
    let start: Date
    let end: Date
    let late: Bool
    let moved: Bool
    let reason: String
    var id: String { "\(choreId)-\(start.timeIntervalSince1970)" }

    init?(_ j: [String: Any]) {
        guard let c = (j["chore_id"] as? NSNumber)?.intValue, let s = (j["start"] as? String).flatMap(ChoreTime.instant),
              let e = (j["end"] as? String).flatMap(ChoreTime.instant) else { return nil }
        choreId = c; start = s; end = e
        name = j["name"] as? String ?? ""
        room = j["room"] as? String
        minutes = (j["minutes"] as? NSNumber)?.intValue ?? 0
        priority = j["priority"] as? String ?? "normal"
        late = j["late"] as? Bool ?? false
        moved = j["moved"] as? Bool ?? false
        reason = j["reason"] as? String ?? ""
    }
}

struct DoneChore: Identifiable, Hashable {
    let name: String
    let at: Date
    var id: String { name + "\(at.timeIntervalSince1970)" }
}

struct PlanDay: Identifiable, Hashable {
    let day: Date
    let weekend: Bool
    let freeMinutes: Int
    let plannedMinutes: Int
    let items: [PlanItem]
    var id: Date { day }
}

enum ChoreTime {
    static func instant(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ s: String) -> Date? { dayFormat.date(from: String(s.prefix(10))) }
    static func dayString(_ d: Date) -> String { dayFormat.string(from: d) }

    /// "21:30:00" -> "21:30"
    static func short(_ s: String) -> String { String(s.prefix(5)) }

    /// "21:30" as a time today, for a picker.
    static func clock(_ s: String?) -> Date {
        let p = (s ?? "21:00").split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 21, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// The chores' state on the phone: the plan (public.app_chores), the actions on it, the calendar's busy times
/// (sent with app_busy on each refresh, so the plan only uses free time) and the shared Reminders list "Chores".
@MainActor
final class Chores: ObservableObject {
    static let shared = Chores()
    @Published var days: [PlanDay] = []
    @Published var chores: [Chore] = []
    @Published var rooms: [String] = []
    @Published var doneToday: [DoneChore] = []
    @Published var holdUntil: Date?
    @Published var error: String?
    @Published var loadedAt: Date?
    private let calendar = EKEventStore()

    private var api: API { API(creds: Store.shared.creds) }

    func refresh() async {
        await syncCalendar()
        await call("app_chores", [:])
    }

    func save(_ c: Chore) async { await call("app_chore_save", ["p_chore": c.payload]) }
    func delete(_ c: Chore) async { if let id = c.id { await call("app_chore_delete", ["p_id": id]) } }

    /// done | undo | tomorrow | later (minutes)
    func act(_ choreId: Int, _ action: String, minutes: Int? = nil) async {
        var body: [String: Any] = ["p_id": choreId, "p_action": action]
        if let minutes { body["p_minutes"] = minutes }
        if action == "done" { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        await call("app_chore_action", body)
    }

    /// "Need N min first" (0 ends the hold).
    func hold(_ minutes: Int) async { await call("app_claim", ["p_minutes": minutes]) }

    /// A refresh if the last one is over 15 min old (the Log Event action calls it, so the shared list stays current).
    func refreshIfStale() async {
        if loadedAt.map({ Date().timeIntervalSince($0) > 900 }) ?? true { await refresh() }
    }

    private func call(_ rpc: String, _ body: [String: Any]) async {
        guard Store.shared.creds.isComplete else { return }
        do {
            let data = try await api.rpc(rpc, json: body)
            apply((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            error = nil
            await syncReminders()
        } catch let APIError.http(_, text) {
            error = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["message"] as? String ?? text
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ r: [String: Any]) {
        let plan = r["plan"] as? [String: Any] ?? [:]
        days = ((plan["days"] as? [[String: Any]]) ?? []).compactMap { d in
            guard let day = (d["day"] as? String).flatMap(ChoreTime.day) else { return nil }
            return PlanDay(day: day, weekend: d["weekend"] as? Bool ?? false,
                           freeMinutes: (d["free_minutes"] as? NSNumber)?.intValue ?? 0,
                           plannedMinutes: (d["planned_minutes"] as? NSNumber)?.intValue ?? 0,
                           items: ((d["items"] as? [[String: Any]]) ?? []).compactMap(PlanItem.init))
        }
        holdUntil = ((plan["claim"] as? [String: Any])?["end"] as? String).flatMap(ChoreTime.instant)
        chores = ((r["chores"] as? [[String: Any]]) ?? []).map(Chore.init)
        rooms = r["rooms"] as? [String] ?? []
        doneToday = ((r["done_today"] as? [[String: Any]]) ?? []).compactMap { x in
            guard let n = x["name"] as? String, let at = (x["at"] as? String).flatMap(ChoreTime.instant) else { return nil }
            return DoneChore(name: n, at: at)
        }
        loadedAt = Date()
    }

    /// The next 8 days' busy events from every calendar on the phone (not all-day ones, not ones marked free).
    private func syncCalendar() async {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await calendar.requestFullAccessToEvents()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, Store.shared.creds.isComplete else { return }
        let from = Calendar.current.startOfDay(for: Date())
        let to = from.addingTimeInterval(8 * 86400)
        let events = calendar.events(matching: calendar.predicateForEvents(withStart: from, end: to, calendars: nil))
        let blocks: [[String: Any]] = events.filter { !$0.isAllDay && $0.availability != .free }
            .map { ["start": Fmt.iso($0.startDate), "end": Fmt.iso($0.endDate)] }
        _ = try? await api.rpc("app_busy", json: ["p_from": Fmt.iso(from), "p_to": Fmt.iso(to), "p_blocks": blocks])
    }

    // MARK: the shared Reminders list

    private var syncingReminders = false

    /// The Reminders list "Chores" (made in the default reminders account, iCloud, the first time; share it from the
    /// Reminders app): the next `listDays` days of the plan, one reminder per chore and day, titled with its planned
    /// time and room, in plan order, without due dates (no alerts). Each carries personallog://chore/<id>/<day>, so a
    /// reminder checked off there (by anyone the list is shared with) marks the chore done here, once; ones no longer
    /// in the plan are removed, completed ones after 3 days.
    private func syncReminders(listDays: Int = 3) async {
        guard !syncingReminders else { return }
        syncingReminders = true
        defer { syncingReminders = false }
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try? await calendar.requestFullAccessToReminders()
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let list = choresList() else { return }

        var reported = Set(UserDefaults.standard.stringArray(forKey: "choreRemindersDone") ?? [])
        var open: [String: EKReminder] = [:]
        var doneIds = Set<Int>()
        for r in await reminders(in: list) {
            guard let url = r.url, url.scheme == "personallog", url.host == "chore" else { continue }
            let key = url.absoluteString
            if r.isCompleted {
                if !reported.contains(key), url.pathComponents.count > 1, let id = Int(url.pathComponents[1]) {
                    doneIds.insert(id)
                    reported.insert(key)
                }
                if let c = r.completionDate, Date().timeIntervalSince(c) > 3 * 86400 { try? calendar.remove(r, commit: false) }
            } else {
                open[key] = r
            }
        }
        UserDefaults.standard.set(Array(reported.suffix(300)), forKey: "choreRemindersDone")
        for id in doneIds {   // checked off in the shared list: done (and the plan reloaded)
            if let data = try? await api.rpc("app_chore_action", json: ["p_id": id, "p_action": "done"]) {
                apply((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            }
        }

        var wanted: [(key: String, title: String, notes: String)] = []
        for d in days.prefix(listDays) {
            let today = Calendar.current.isDateInToday(d.day)
            for it in d.items {
                let key = "personallog://chore/\(it.choreId)/\(ChoreTime.dayString(d.day))"
                guard !wanted.contains(where: { $0.key == key }) else { continue }
                let when = (today ? "" : d.day.formatted(.dateTime.weekday(.abbreviated)) + " ")
                    + it.start.formatted(date: .omitted, time: .shortened)
                wanted.append((key, "\(when) · \(it.name)" + (it.room.map { $0.isEmpty ? "" : " (\($0))" } ?? ""),
                               "\(it.minutes) min" + (it.priority == "must" ? ", must do" : "")))
            }
        }
        for (key, r) in open where !wanted.contains(where: { $0.key == key }) { try? calendar.remove(r, commit: false) }
        for w in wanted {
            if let r = open[w.key] {
                if r.title != w.title || r.notes != w.notes {
                    r.title = w.title
                    r.notes = w.notes
                    try? calendar.save(r, commit: false)
                }
            } else {
                let r = EKReminder(eventStore: calendar)
                r.calendar = list
                r.title = w.title
                r.notes = w.notes
                r.url = URL(string: w.key)
                try? calendar.save(r, commit: false)
            }
        }
        try? calendar.commit()
    }

    private func choresList() -> EKCalendar? {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "choresListId"), let c = calendar.calendar(withIdentifier: id) { return c }
        if let c = calendar.calendars(for: .reminder).first(where: { $0.title == "Chores" }) {
            d.set(c.calendarIdentifier, forKey: "choresListId")
            return c
        }
        guard let source = calendar.defaultCalendarForNewReminders()?.source else { return nil }
        let c = EKCalendar(for: .reminder, eventStore: calendar)
        c.title = "Chores"
        c.source = source
        guard (try? calendar.saveCalendar(c, commit: true)) != nil else { return nil }
        d.set(c.calendarIdentifier, forKey: "choresListId")
        return c
    }

    private func reminders(in list: EKCalendar) async -> [EKReminder] {
        await withCheckedContinuation { cont in
            calendar.fetchReminders(matching: calendar.predicateForReminders(in: [list])) { cont.resume(returning: $0 ?? []) }
        }
    }
}

/// Today's plan (what's next, in order, with Done / later / tomorrow), a "need N min first" hold, and the next days.
struct ChoresView: View {
    @StateObject private var chores = Chores.shared
    @State private var editing: Chore?
    @State private var askAI = false

    var body: some View {
        NavigationStack {
            List {
                if let e = chores.error {
                    Text(e).font(.footnote).foregroundStyle(.red)
                }
                holdSection
                if let today = chores.days.first {
                    Section {
                        if today.items.isEmpty {
                            Text("Nothing left today").foregroundStyle(.secondary)
                        }
                        ForEach(today.items) { it in row(it, today: true) }
                    } header: {
                        Text("Today")
                    } footer: {
                        Text("\(today.plannedMinutes) of \(today.freeMinutes) free min planned")
                    }
                }
                if !chores.doneToday.isEmpty {
                    Section("Done today") {
                        ForEach(chores.doneToday) { d in
                            LabeledContent(d.name, value: d.at.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(chores.days.dropFirst()) { d in
                    if !d.items.isEmpty {
                        Section {
                            ForEach(d.items) { it in row(it, today: false) }
                        } header: {
                            Text(d.day.formatted(.dateTime.weekday(.wide).month().day()))
                        } footer: {
                            Text("\(d.plannedMinutes) of \(d.freeMinutes) free min")
                        }
                    }
                }
            }
            .refreshable { await chores.refresh() }
            .navigationTitle("Chores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { ChoreListView() } label: { Image(systemName: "list.bullet") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { askAI = true } label: { Image(systemName: "sparkles") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Chore() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { c in ChoreEditView(chore: c) }
            .sheet(isPresented: $askAI) { AskAIView(kind: "chore") { await chores.refresh() } }
            .task { if chores.loadedAt == nil || Date().timeIntervalSince(chores.loadedAt!) > 60 { await chores.refresh() } }
        }
    }

    @ViewBuilder
    private var holdSection: some View {
        Section {
            if let until = chores.holdUntil {
                HStack {
                    Label("Holding until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "pause.circle")
                    Spacer()
                    Button("End") { Task { await chores.hold(0) } }
                }
            } else {
                HStack {
                    Text("Need first").foregroundStyle(.secondary)
                    Spacer()
                    ForEach([15, 30, 60], id: \.self) { m in
                        Button("\(m) min") { Task { await chores.hold(m) } }.buttonStyle(.bordered)
                    }
                }
            }
        } footer: {
            Text("A hold moves the plan after it; opening a distracting app ends it.")
        }
    }

    private func row(_ it: PlanItem, today: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(it.start.formatted(date: .omitted, time: .shortened))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.name).fontWeight(it.priority == "must" ? .semibold : .regular)
                HStack(spacing: 6) {
                    Text("\(it.minutes) min")
                    if let r = it.room, !r.isEmpty { Text(r) }
                    if it.late { Text("late").foregroundStyle(.orange) }
                    if it.moved { Text("moved").foregroundStyle(.orange) }
                    if it.reason == "overdue" { Text("overdue").foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if today {
                Button { Task { await chores.act(it.choreId, "done") } } label: {
                    Image(systemName: "checkmark.circle").font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Tomorrow") { Task { await chores.act(it.choreId, "tomorrow") } }.tint(.indigo)
            Button("1 h") { Task { await chores.act(it.choreId, "later", minutes: 60) } }.tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button("Done") { Task { await chores.act(it.choreId, "done") } }.tint(.green)
        }
        .contextMenu {
            Button("Done") { Task { await chores.act(it.choreId, "done") } }
            Button("In 1 hour") { Task { await chores.act(it.choreId, "later", minutes: 60) } }
            Button("In 3 hours") { Task { await chores.act(it.choreId, "later", minutes: 180) } }
            Button("Tomorrow") { Task { await chores.act(it.choreId, "tomorrow") } }
            if let c = chores.chores.first(where: { $0.id == it.choreId }) {
                Button("Edit…") { editing = c }
            }
        }
    }
}

/// Every chore, by room, to edit or add.
struct ChoreListView: View {
    @ObservedObject private var chores = Chores.shared
    @State private var editing: Chore?

    var body: some View {
        List {
            let rooms = Array(Set(chores.chores.map(\.room))).sorted { ($0.isEmpty ? "~" : $0) < ($1.isEmpty ? "~" : $1) }
            ForEach(rooms, id: \.self) { room in
                Section(room.isEmpty ? "Anywhere" : room.capitalized) {
                    ForEach(chores.chores.filter { $0.room == room }) { c in
                        Button { editing = c } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(c.name).foregroundStyle(c.active ? Color.primary : Color.secondary)
                                    if c.isSensor { Image(systemName: "sensor").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text([c.schedule, "\(c.minutes) min", c.lastDone.map { "done " + Fmt.ago($0) } ?? ""]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("All chores")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { editing = Chore() } label: { Image(systemName: "plus") } }
        }
        .sheet(item: $editing) { c in ChoreEditView(chore: c) }
    }
}

/// Add or edit a chore. A sensor chore keeps its trigger: only where, how long, priority and on / off change.
struct ChoreEditView: View {
    @ObservedObject private var chores = Chores.shared
    @Environment(\.dismiss) private var dismiss
    @State var chore: Chore
    @State private var mode = "every"     // every | weekdays | once
    @State private var hasAfter = false
    @State private var hasBy = false
    @State private var hasDue = false
    @State private var confirmDelete = false

    private let weekdayNames = [(1, "M"), (2, "T"), (3, "W"), (4, "T"), (5, "F"), (6, "S"), (7, "S")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $chore.name)
                    HStack {
                        TextField("Room", text: $chore.room).textInputAutocapitalization(.never)
                        Menu {
                            ForEach(Array(Set(chores.rooms + ["kitchen", "bathroom", "bedroom", "living room", "outside"])).sorted(),
                                    id: \.self) { r in Button(r) { chore.room = r } }
                        } label: { Image(systemName: "chevron.down.circle") }
                    }
                    Stepper("\(chore.minutes) min", value: $chore.minutes, in: 1...240, step: chore.minutes < 10 ? 1 : 5)
                    Picker("Priority", selection: $chore.priority) {
                        Text("Must").tag("must")
                        Text("Normal").tag("normal")
                        Text("Low").tag("low")
                    }
                }
                if chore.isSensor {
                    Section("Due") { Text(chore.schedule).foregroundStyle(.secondary) }
                } else {
                    Section("How often") {
                        Picker("Repeat", selection: $mode) {
                            Text("Every N days").tag("every")
                            Text("Weekdays").tag("weekdays")
                            Text("Once").tag("once")
                        }
                        .pickerStyle(.segmented)
                        switch mode {
                        case "every":
                            Stepper(chore.everyDays.map { $0 == 1 ? "Daily" : "Every \(Fmt.amount($0)) days" } ?? "Every day",
                                    value: Binding(get: { chore.everyDays ?? 1 }, set: { chore.everyDays = $0 }), in: 1...180, step: 1)
                        case "weekdays":
                            HStack {
                                ForEach(weekdayNames, id: \.0) { d in
                                    let on = chore.weekdays.contains(d.0)
                                    Button(d.1) {
                                        if on { chore.weekdays.removeAll { $0 == d.0 } } else { chore.weekdays.append(d.0) }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(on ? Color.accentColor : Color(.secondarySystemBackground), in: Circle())
                                    .foregroundStyle(on ? Color.white : Color.primary)
                                    .buttonStyle(.plain)
                                }
                            }
                        default:
                            Toggle("By a date", isOn: $hasDue)
                            if hasDue {
                                DatePicker("Due", selection: Binding(get: { chore.dueDate ?? Date() }, set: { chore.dueDate = $0 }),
                                           displayedComponents: .date)
                            }
                        }
                    }
                    Section {
                        Toggle("Not before", isOn: $hasAfter)
                        if hasAfter {
                            DatePicker("After", selection: Binding(get: { ChoreTime.clock(chore.afterTime) },
                                                                   set: { chore.afterTime = ChoreTime.hhmm($0) }),
                                       displayedComponents: .hourAndMinute)
                        }
                        Toggle("Deadline", isOn: $hasBy)
                        if hasBy {
                            DatePicker("By", selection: Binding(get: { ChoreTime.clock(chore.byTime) },
                                                                set: { chore.byTime = ChoreTime.hhmm($0) }),
                                       displayedComponents: .hourAndMinute)
                        }
                    } header: { Text("When") } footer: {
                        Text("A 'must' chore past its deadline sets off an alarm; the others only buzz.")
                    }
                }
                Section {
                    let others = chores.chores.map(\.name).filter { $0 != chore.name }.sorted()
                    if others.isEmpty { Text("No other chores yet").foregroundStyle(.secondary) }
                    ForEach(others, id: \.self) { n in
                        Button {
                            if chore.dependsOn.contains(n) { chore.dependsOn.removeAll { $0 == n } } else { chore.dependsOn.append(n) }
                        } label: {
                            HStack {
                                Text(n).foregroundStyle(Color.primary)
                                Spacer()
                                if chore.dependsOn.contains(n) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } header: { Text("After these (same day)") }
                Section {
                    TextField("Done when this event is logged", text: $chore.doneEvent)
                    Toggle("Active", isOn: $chore.active)
                    if !chore.isSensor { TextField("Notes", text: $chore.notes, axis: .vertical) }
                } footer: {
                    Text("An event name (e.g. Night Supplements, logged by the bottle sensor) marks it done by itself.")
                }
                if chore.id != nil {
                    Section {
                        Button(chore.isSensor ? "Turn off" : "Delete", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(chore.id == nil ? "New chore" : chore.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var c = chore
                        if !c.isSensor {
                            if mode != "every" { c.everyDays = nil }
                            if mode != "weekdays" { c.weekdays = [] }
                            if mode != "once" || !hasDue { c.dueDate = nil }
                            if mode == "every" && c.everyDays == nil { c.everyDays = 1 }
                            if !hasAfter { c.afterTime = nil }
                            if !hasBy { c.byTime = nil }
                        }
                        Task { await chores.save(c); dismiss() }
                    }
                    .disabled(chore.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Remove \(chore.name)?", isPresented: $confirmDelete) {
                Button(chore.isSensor ? "Turn off" : "Delete", role: .destructive) {
                    Task { await chores.delete(chore); dismiss() }
                }
            }
            .onAppear {
                mode = !chore.weekdays.isEmpty ? "weekdays" : (chore.everyDays != nil || chore.id == nil) ? "every" : "once"
                hasAfter = chore.afterTime != nil
                hasBy = chore.byTime != nil
                hasDue = chore.dueDate != nil
            }
        }
    }
}
