import SwiftUI

/// MacroFactor recipes (macrofactor.recipe, flattened by the server). Logging hands the foods to the "Log Foods From
/// App" Shortcut, which logs each one in MacroFactor and comes back here.
struct FoodView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var chosen: Choice?

    struct Choice: Identifiable { let name: String; var id: String { name } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TimeBar()
                StatusLine()
                List {
                    ForEach(store.recipes.sections(matching: search), id: \.0) { category, names in
                        Section(category) {
                            ForEach(names, id: \.self) { name in
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
            .navigationTitle("Food")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $chosen) { c in RecipeSheet(name: c.name) }
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
                    Stepper(value: $servings, in: 0.5...20, step: 0.5) {
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
