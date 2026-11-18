import SwiftUI

/// A feature request or idea (analysis.feature_request): logged even when it is only an idea, with how sure we are:
/// idea, likely, ready (go ahead: Claude may build it).
struct Feature: Codable, Hashable, Identifiable {
    let id: Int
    var title: String
    var details: String
    var area: String?
    var confidence: String   // idea | likely | ready
    var status: String       // open | in progress | done | declined
    let source: String
    let updated_at: Date

    static let confidences = ["idea", "likely", "ready"]
    static let statuses = ["open", "in progress", "done", "declined"]

    var closed: Bool { status == "done" || status == "declined" }

    static func label(_ c: String) -> String {
        switch c {
        case "ready": return "Ready: go ahead"
        case "likely": return "Likely: needs a decision"
        default: return "Idea"
        }
    }
}

/// The ideas and feature requests (public.app_features): ready ones first, then likely, then ideas; done and declined
/// at the bottom. Swipe right to make one ready, left to delete; tap to edit; + to add one.
struct IdeasView: View {
    @EnvironmentObject var store: Store
    @State private var features: [Feature] = []
    @State private var editing: Feature?
    @State private var adding = false
    @State private var error: String?

    private func reload() async { features = await store.fetchFeatures() }

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            ForEach(Feature.confidences.reversed(), id: \.self) { c in
                let rows = features.filter { !$0.closed && $0.confidence == c }
                if !rows.isEmpty {
                    Section(Feature.label(c)) { ForEach(rows) { row($0) } }
                }
            }
            let closed = features.filter(\.closed)
            if !closed.isEmpty {
                Section("Done or declined") { ForEach(closed) { row($0) } }
            }
        }
        .overlay { if features.isEmpty { ContentUnavailableView("No ideas yet", systemImage: "lightbulb") } }
        .navigationTitle("Ideas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { f in FeatureEditView(feature: f) }
        .sheet(isPresented: $adding, onDismiss: { Task { await reload() } }) { FeatureEditView(feature: nil) }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func row(_ f: Feature) -> some View {
        Button { editing = f } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).foregroundStyle(f.closed ? .secondary : .primary)
                if !f.details.isEmpty {
                    Text(f.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text([f.area, f.status == "open" ? nil : f.status, f.source == "claude" ? "from a conversation" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .swipeActions(edge: .leading) {
            if f.confidence != "ready" && !f.closed {
                Button("Ready") { Task { error = await store.saveFeature(["id": f.id, "confidence": "ready"]); await reload() } }
                    .tint(.green)
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                Task { error = await store.saveFeature(["id": f.id, "delete": true]); await reload() }
            }
            if !f.closed {
                Button("Decline") { Task { error = await store.saveFeature(["id": f.id, "status": "declined"]); await reload() } }
            }
        }
    }
}

/// Add an idea (feature nil) or change one.
struct FeatureEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let feature: Feature?
    @State private var title = ""
    @State private var details = ""
    @State private var area = ""
    @State private var confidence = "idea"
    @State private var status = "open"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What", text: $title)
                    TextField("Details", text: $details, axis: .vertical).lineLimit(3...8)
                    TextField("Area (app, watch, home, food ...)", text: $area)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Picker("How sure", selection: $confidence) {
                        ForEach(Feature.confidences, id: \.self) { Text(Feature.label($0)).tag($0) }
                    }
                    if feature != nil {
                        Picker("Status", selection: $status) {
                            ForEach(Feature.statuses, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                } footer: { Text("Ready means Claude may go ahead and build it.") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(feature == nil ? "New idea" : "Idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            var p: [String: Any] = ["title": title, "details": details, "area": area,
                                                    "confidence": confidence, "status": status]
                            if let feature { p["id"] = feature.id }
                            if let e = await store.saveFeature(p) { error = e } else { dismiss() }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let f = feature {
                    title = f.title; details = f.details; area = f.area ?? ""; confidence = f.confidence; status = f.status
                }
            }
        }
    }
}
