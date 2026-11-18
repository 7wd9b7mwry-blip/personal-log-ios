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

/// Today's food log: the totals against the targets, each recipe logged (tap for its foods; swipe to delete), the
/// ones still being sent, and the targets.
struct FoodTodayView: View {
    @EnvironmentObject var store: Store
    @State private var editing = false

    var body: some View {
        List {
            if let d = store.foodDay {
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
            if !store.foodLogs.isEmpty {
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
                ForEach(store.foodDay?.logs ?? []) { l in
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
                            .swipeActions { Button("Delete", role: .destructive) { Task { await store.deleteFood(entry: it.id) } } }
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
                    .swipeActions { Button("Delete", role: .destructive) { Task { await store.deleteFood(log: l.log_id) } } }
                }
            }
        }
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Targets") { editing = true } }
        .sheet(isPresented: $editing) { FoodTargetsView() }
        .refreshable { await store.loadFoodDay() }
        .task { await store.loadFoodDay() }
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
