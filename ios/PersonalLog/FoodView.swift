import SwiftUI

/// MacroFactor recipes (macrofactor.recipe, flattened by the server). Logging hands the foods to the "Log Foods From
/// App" Shortcut, which logs each one in MacroFactor and comes back here.
struct FoodView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var chosen: Choice?
    @State private var askAI = false
    @State private var openMore: Set<String> = []

    struct Choice: Identifiable { let name: String; var id: String { name } }
    struct Subgroup: Hashable { let category: String; let name: String? }   // nil: the recipes in none

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TimeBar()
                StatusLine()
                List {
                    if search.isEmpty {
                        Section { NavigationLink { FoodTodayView() } label: { FoodTodayRow() } }
                        // categories first; tap one for its recipes
                        ForEach(store.recipes.sections(matching: ""), id: \.0) { category, names in
                            NavigationLink(value: category) {
                                LabeledContent {
                                    Text("\(names.count)")
                                } label: {
                                    Label(category, systemImage: Self.icon(category))
                                }
                            }
                        }
                    } else {
                        ForEach(store.recipes.sections(matching: search), id: \.0) { category, names in
                            Section(category) { ForEach(names, id: \.self) { row($0) } }
                        }
                    }
                }
                .refreshable { await store.refresh(); await store.flushFood(); await store.loadFoodDay() }
                .task { await store.loadFoodDay() }
                .overlay {
                    if store.recipes.names.isEmpty {
                        ContentUnavailableView("No recipes", systemImage: "fork.knife",
                                               description: Text("Add them in macrofactor.recipe, then pull to refresh."))
                    }
                }
            }
            .searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { askAI = true } label: { Image(systemName: "sparkles") }
                }
            }
            .navigationTitle("Food")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { category in
                VStack(spacing: 0) {
                    TimeBar()
                    List {
                        let names = store.recipes.sections(matching: "").first { $0.0 == category }?.1 ?? []
                        let groups = store.recipes.groups(names)
                        let split = store.recipes.usual(names)
                        let usual = split.0, rest = split.1
                        // the usual few first; everything else (by subgroup when there are some) under More
                        ForEach(usual, id: \.self) { row($0) }
                        if groups.count <= 1 {
                            more(rest, all: usual.isEmpty)
                        } else {
                            Section {
                                DisclosureGroup(isExpanded: expanded(category, all: usual.isEmpty)) {
                                    ForEach(groups, id: \.0) { sub, ns in
                                        NavigationLink(value: Subgroup(category: category, name: sub)) {
                                            LabeledContent { Text("\(ns.count)") } label: { Text(sub ?? "Other") }
                                        }
                                    }
                                } label: { Text("More").foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .navigationTitle(category)
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: Subgroup.self) { g in
                VStack(spacing: 0) {
                    TimeBar()
                    List {
                        let names = store.recipes.sections(matching: "").first { $0.0 == g.category }?.1 ?? []
                        let split = store.recipes.usual(store.recipes.groups(names).first { $0.0 == g.name }?.1 ?? [])
                        let usual = split.0, rest = split.1
                        ForEach(usual, id: \.self) { row($0) }
                        more(rest, all: usual.isEmpty)
                    }
                }
                .navigationTitle(g.name ?? "Other")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $chosen) { c in RecipeSheet(name: c.name) }
        .sheet(isPresented: $askAI) { AskAIView(kind: "food") { await store.refresh() } }
    }

    /// The recipes not used lately, folded under More (open when nothing was used lately).
    @ViewBuilder
    private func more(_ names: [String], all: Bool) -> some View {
        if all {
            ForEach(names, id: \.self) { row($0) }
        } else if !names.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(names, id: \.self) { row($0) }
                } label: { Text("More (\(names.count))").foregroundStyle(.secondary) }
            }
        }
    }

    private func expanded(_ key: String, all: Bool) -> Binding<Bool> {
        Binding(get: { all || openMore.contains(key) },
                set: { if $0 { openMore.insert(key) } else { openMore.remove(key) } })
    }

    private func row(_ name: String) -> some View {
        Button { chosen = Choice(name: name) } label: {
            HStack {
                Text(name).foregroundStyle(Color.primary)
                Spacer()
                if store.recipes.recipes[name]?.items.contains(where: { $0.kind == "water" }) == true {
                    Image(systemName: "drop.fill").foregroundStyle(.blue)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    static func icon(_ category: String) -> String {
        switch category.lowercased() {
        case "breakfast": return "sunrise"
        case "drinks": return "cup.and.saucer"
        case "meals": return "fork.knife"
        case "snacks": return "carrot"
        case "desserts": return "birthday.cake"
        default: return "tag"
        }
    }
}

struct RecipeSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let name: String
    @State private var servings = 1.0

    var body: some View {
        let recipe = store.recipes.recipes[name]
        NavigationStack {
            Form {
                Section(recipe?.prompt ?? "How many?") {
                    Stepper(value: $servings, in: 1...20, step: 1) {
                        Text(Fmt.amount(servings) + (servings == 1 ? " serving" : " servings"))
                            .font(.title3.monospacedDigit())
                    }
                }
                Section("Logs") {
                    ForEach(Array((recipe?.items ?? []).enumerated()), id: \.offset) { _, it in
                        line(it)
                    }
                }
                Section { TimeBar() }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        let url = store.logRecipe(name, servings: servings)
                        dismiss()
                        if let url { openURL(url) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ it: RecipeItem) -> some View {
        switch it.kind {
        case "food":
            HStack {
                Text(it.name ?? "")
                Spacer()
                Text("\(Fmt.amount((it.count ?? 1) * servings)) × \(it.serving ?? "")").foregroundStyle(.secondary)
            }
        case "water":
            HStack { Text("Water"); Spacer(); Text("\(Fmt.amount((it.fl_oz ?? 0) * servings)) fl oz").foregroundStyle(.secondary) }
        default:
            HStack {
                Text(it.prefix ?? "")
                Spacer()
                Text("\(Fmt.amount((it.value ?? 0) * servings)) \(it.unit ?? "")").foregroundStyle(.secondary)
            }
        }
    }
}
