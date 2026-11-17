import SwiftUI

/// MacroFactor recipes (macrofactor.recipe, flattened by the server). Logging hands the foods to the "Log Foods From
/// App" Shortcut, which logs each one in MacroFactor and comes back here.
struct FoodView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var chosen: Choice?
    @State private var askAI = false

    struct Choice: Identifiable { let name: String; var id: String { name } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TimeBar()
                StatusLine()
                List {
                    if search.isEmpty {
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
                .refreshable { await store.refresh() }
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
                        ForEach(store.recipes.sections(matching: "").first { $0.0 == category }?.1 ?? [], id: \.self) { row($0) }
                    }
                }
                .navigationTitle(category)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $chosen) { c in RecipeSheet(name: c.name) }
        .sheet(isPresented: $askAI) { AskAIView(kind: "food") { await store.refresh() } }
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
