import SwiftUI

/// One recipe logged in the app, waiting to reach the food log (food.entry via public.app_food_log; kept on disk, so a
/// log with no signal goes later). The id makes a re-send nothing new.
struct FoodLog: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    let name: String
    let servings: Double
    let at: Date
    var source = "app"   // app | office
}

/// A day of the food log (public.app_food_day): each recipe log with its foods, the totals, the targets and what is
/// left of them.
struct FoodDay: Codable {
    struct Item: Codable, Hashable, Identifiable {
        let id: Int
        let kind: String
        let title: String?
        let serving: String?
        let count: Double?
        let energy: Double?
        let protein: Double?
        let water_ml: Double?
    }
    struct Log: Codable, Hashable, Identifiable {
        let log_id: String
        let at: Date
        let recipe: String?
        let servings: Double?
        let source: String?
        let energy: Double?
        let protein: Double?
        let water_ml: Double?
        let items: [Item]
        var id: String { log_id }
    }
    /// Our energy expenditure estimate (food.tdee): the typical day's burn, today's with the activity so far, and the
    /// target it suggests for the goal.
    struct TDEE: Codable, Hashable {
        let baseline: Double
        let expenditure: Double
        let suggested: Double
        let weight_trend_lb: Double?
    }
    let day: String
    let totals: [String: Double]
    var tdee: TDEE?
    let target: [String: Double?]
    let left: [String: Double]
    let mirror_macrofactor: Bool
    let logs: [Log]

    func goal(_ k: String) -> Double? { target[k] ?? nil }
}

/// The macros the Today screen shows, with their units.
let foodMacros: [(key: String, name: String, unit: String)] = [
    ("energy", "Calories", "kcal"), ("protein", "Protein", "g"), ("carbs", "Carbs", "g"), ("fat", "Fat", "g"),
]

/// The Food tab's Today row: calories so far against the target.
struct FoodTodayRow: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let d = store.foodDay
        let eaten = (d?.totals["energy"] ?? 0) + store.pendingFoodEnergy
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Today", systemImage: "fork.knife.circle")
                Spacer()
                if let goal = d?.goal("energy") {
                    Text("\(Int(eaten.rounded())) / \(Int(goal)) kcal").foregroundStyle(.secondary)
                } else {
                    Text("\(Int(eaten.rounded())) kcal").foregroundStyle(.secondary)
                }
            }
            if let goal = d?.goal("energy"), goal > 0 {
                ProgressView(value: min(eaten / goal, 1))
                    .tint(eaten > goal ? .orange : .accentColor)
                Text(eaten <= goal ? "\(Int((goal - eaten).rounded())) kcal left" : "\(Int((eaten - goal).rounded())) kcal over")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A day of the logs by the day boundary (it starts at 5 AM, like the server's public.event_day: a 2 AM meal counts
/// for the day before).
enum LogDay {
    static let startHour = 5

    static func today() -> Date {
        Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(startHour) * 3600))
    }

    static func key(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func title(_ d: Date) -> String {
        let t = today()
        if d == t { return "Today" }
        if let y = Calendar.current.date(byAdding: .day, value: -1, to: t), d == y { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// ‹ day › with a date picker: any past day, not the future.
struct DayPicker: View {
    @Binding var day: Date

    var body: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
            DatePicker("Day", selection: $day, in: ...LogDay.today(), displayedComponents: .date)
                .labelsHidden()
                .onChange(of: day) { _, d in
                    let start = Calendar.current.startOfDay(for: d)
                    if start != d { day = start }
                }
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(day >= LogDay.today())
        }
    }

    private func step(_ n: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: n, to: day), d <= LogDay.today() { day = d }
    }
}

/// A day's food log (today unless another day is picked): the totals against the targets, each recipe logged (tap
/// for its foods; swipe to edit the amount or delete), the ones still being sent, and the targets.
struct FoodTodayView: View {
    @EnvironmentObject var store: Store
    @State private var editing = false
    @State private var amount: FoodAmountEdit?
    @State private var day = LogDay.today()
    @State private var other: FoodDay?   // a past day's log

    private var isToday: Bool { day == LogDay.today() }
    private var shown: FoodDay? { isToday ? store.foodDay : other }

    private func reload() async {
        if isToday {
            await store.loadFoodDay()
        } else {
            other = await store.fetchFoodDay(LogDay.key(day))
        }
    }

    var body: some View {
        List {
            // the day at the top: a bottom toolbar sits under iOS 26's floating tab bar, out of sight
            Section { DayPicker(day: $day).frame(maxWidth: .infinity) } footer: {
                Text("Pick any past day to edit or delete what was logged.")
            }
            if let d = shown {
                Section {
                    ForEach(foodMacros, id: \.key) { m in
                        let v = d.totals[m.key] ?? 0
                        LabeledContent(m.name) {
                            if let g = d.goal(m.key) {
                                Text("\(Fmt.amount(v.rounded())) / \(Fmt.amount(g)) \(m.unit)")
                            } else {
                                Text("\(Fmt.amount(v.rounded())) \(m.unit)")
                            }
                        }
                    }
                    if let w = d.totals["water_ml"], w > 0 {
                        LabeledContent("Water (from recipes)") { Text("\(Fmt.amount((w / 29.5735).rounded())) fl oz") }
                    }
                } footer: {
                    if let t = d.tdee {
                        Text("Our estimate: you burn about \(Int(t.baseline)) kcal on a typical day (\(Int(t.expenditure)) with today's activity so far)"
                             + (t.weight_trend_lb.map { ", weight trend \(Fmt.amount($0)) lb" } ?? "")
                             + ". For your goal that suggests about \(Int(t.suggested)) kcal a day.")
                    }
                    if d.mirror_macrofactor {
                        Text("Also logged in MacroFactor while we compare the two. Deleting here doesn't delete it there.")
                    }
                }
            }
            if isToday && !store.foodLogs.isEmpty {
                Section("Sending") {
                    ForEach(store.foodLogs) { l in
                        HStack {
                            Text("\(Fmt.amount(l.servings)) × \(l.name)")
                            Spacer()
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
            }
            Section("Logged") {
                ForEach(shown?.logs ?? []) { l in
                    DisclosureGroup {
                        ForEach(l.items) { it in
                            HStack {
                                if it.kind == "water" {
                                    Text("Water")
                                    Spacer()
                                    Text("\(Fmt.amount(((it.water_ml ?? 0) / 29.5735).rounded())) fl oz").foregroundStyle(.secondary)
                                } else {
                                    VStack(alignment: .leading) {
                                        Text(it.title ?? "")
                                        Text("\(Fmt.amount(it.count ?? 0)) × \(it.serving ?? "")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(it.energy.map { "\(Int($0)) kcal" } ?? "?").foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task { await store.deleteFood(entry: it.id); await reload() }
                                }
                                if it.kind == "food", let c = it.count {
                                    Button("Edit") {
                                        amount = FoodAmountEdit(title: it.title ?? "", unit: it.serving ?? "", value: c, entry: it.id)
                                    }.tint(.blue)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(Fmt.amount(l.servings ?? 1)) × \(l.recipe ?? "")")
                                Text(l.at.formatted(date: .omitted, time: .shortened) + (l.source == "watch" ? " · watch" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(l.energy ?? 0)) kcal").foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await store.deleteFood(log: l.log_id); await reload() }
                        }
                        Button("Edit") {
                            amount = FoodAmountEdit(title: l.recipe ?? "", unit: "servings", value: l.servings ?? 1, log: l.log_id)
                        }.tint(.blue)
                    }
                }
            }
        }
        .overlay {
            if !isToday && (shown?.logs.isEmpty ?? true) {
                ContentUnavailableView("Nothing logged", systemImage: "fork.knife")
            }
        }
        .navigationTitle(LogDay.title(day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Targets") { editing = true } }
        }
        .sheet(isPresented: $editing) { FoodTargetsView() }
        .sheet(item: $amount, onDismiss: { Task { await reload() } }) { a in
            FoodAmountView(edit: a, mirror: shown?.mirror_macrofactor ?? false)
        }
        .refreshable { await reload() }
        .task(id: day) { await reload() }
    }
}

/// What the amount sheet edits: a whole log's servings, or one food's count.
struct FoodAmountEdit: Identifiable {
    let title: String
    let unit: String
    let value: Double
    var log: String? = nil
    var entry: Int? = nil
    var id: String { log ?? "entry \(entry ?? 0)" }
}

/// A logged amount, typed or by halves (4 pizzas -> 2: the foods and the water scale with it).
struct FoodAmountView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let edit: FoodAmountEdit
    let mirror: Bool
    @State private var value: Double = 1
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("amount", value: $value, format: .number)
                            .keyboardType(.decimalPad)
                        Text(edit.unit).foregroundStyle(.secondary)
                    }
                    Stepper("By halves", value: $value, in: 0.5...1000, step: 0.5)
                } header: { Text(edit.title) } footer: {
                    if mirror {
                        Text("Change it in MacroFactor too: its copy isn't edited from here.")
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let e = edit.log != nil
                                ? await store.editFood(log: edit.log, servings: value)
                                : await store.editFood(entry: edit.entry, count: value)
                            if let e { error = e } else { dismiss() }
                        }
                    }
                    .disabled(value == edit.value || value <= 0)
                }
            }
            .onAppear { value = edit.value }
        }
        .presentationDetents([.medium])
    }
}

/// The daily targets (calories and macros); empty = none.
struct FoodTargetsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(foodMacros, id: \.key) { m in
                        HStack {
                            Text(m.name)
                            Spacer()
                            TextField("none", text: Binding(get: { values[m.key] ?? "" }, set: { values[m.key] = $0 }))
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                            Text(m.unit).foregroundStyle(.secondary)
                        }
                    }
                } footer: { Text("Your daily targets. Leave one empty for none.") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            var t: [String: Any] = [:]
                            for m in foodMacros {
                                let s = (values[m.key] ?? "").trimmingCharacters(in: .whitespaces)
                                t[m.key] = Double(s) ?? NSNull()
                            }
                            if let e = await store.setFoodTargets(t) { error = e } else { dismiss() }
                        }
                    }
                }
            }
            .onAppear {
                for m in foodMacros {
                    if let g = store.foodDay?.goal(m.key) { values[m.key] = Fmt.amount(g) }
                }
            }
        }
    }
}
