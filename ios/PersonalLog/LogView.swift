import SwiftUI

/// The button groups of the server's `app` setting as a menu (tap one for its buttons), with the sessions running now
/// on top so they can be stopped in one tap. A session button shows how long it has been running; the others when
/// they were last logged.
struct LogView: View {
    @EnvironmentObject var store: Store
    @State private var amountFor: ButtonSpec?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TimeBar()
                StatusLine()
                List {
                    let running = store.config.groups.flatMap(\.buttons).filter { store.running[$0.name] != nil }
                    if !running.isEmpty {
                        Section("Running") {
                            ButtonGrid(buttons: running, amountFor: $amountFor)
                                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        }
                    }
                    Section {
                        ForEach(store.config.groups) { g in
                            NavigationLink(value: g) {
                                LabeledContent {
                                    Text(summary(g))
                                } label: {
                                    Label(g.title, systemImage: Self.icon(g.title))
                                }
                            }
                        }
                    }
                }
                .overlay {
                    if store.config.groups.isEmpty {
                        ContentUnavailableView("No buttons yet", systemImage: "square.grid.2x2",
                                               description: Text("Pull to refresh once connected."))
                    }
                }
                .refreshable { await store.refresh(); await store.flush() }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ButtonGroup.self) { g in
                VStack(spacing: 0) {
                    TimeBar()
                    StatusLine()
                    ScrollView {
                        ButtonGrid(buttons: g.buttons, amountFor: $amountFor).padding()
                    }
                    .refreshable { await store.refresh(); await store.flush() }
                }
                .navigationTitle(g.title)
                .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { RecentView() } label: { Label("History", systemImage: "clock.arrow.circlepath").labelStyle(.titleAndIcon) }
                }
            }
        }
        .sheet(item: $amountFor) { b in AmountSheet(button: b) }
    }

    /// What's running in the group, else the last thing logged in it today.
    private func summary(_ g: ButtonGroup) -> String {
        if let r = g.buttons.first(where: { store.running[$0.name] != nil }) { return "● " + r.name }
        let today = g.buttons.compactMap { b in store.last[b.name].map { (b.name, $0) } }
            .filter { Calendar.current.isDateInToday($0.1) }.max { $0.1 < $1.1 }
        return today?.0 ?? ""
    }

    static func icon(_ title: String) -> String {
        switch title.lowercased() {
        case "day": return "calendar"
        case "sessions": return "stopwatch"
        case "routine": return "checklist"
        case "medication": return "pills"
        case "symptoms": return "cross.case"
        case "supplements": return "leaf"
        default: return "square.grid.2x2"
        }
    }
}

/// Buttons as tiles.
struct ButtonGrid: View {
    @EnvironmentObject var store: Store
    let buttons: [ButtonSpec]
    @Binding var amountFor: ButtonSpec?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(buttons) { b in tile(b, now: ctx.date) }
            }
        }
    }

    @ViewBuilder
    private func tile(_ b: ButtonSpec, now: Date) -> some View {
        let started = store.running[b.name]
        Button {
            if b.kind == "val" { amountFor = b } else { store.tap(b) }
        } label: {
            VStack(spacing: 4) {
                Text(b.name).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                    .minimumScaleFactor(0.8)
                Group {
                    if let s = started {
                        Text("● " + Fmt.elapsed(since: s, now: now))
                    } else if b.kind == "session" {
                        Text("Start")
                    } else if let l = store.last[b.name] {
                        Text(Fmt.ago(l, now: now))
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption2).foregroundStyle(started != nil ? Color.white : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(6)
            .background(started != nil ? Color.red.opacity(0.85) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(started != nil ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct AmountSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let button: ButtonSpec
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Amount", text: $text).keyboardType(.decimalPad).font(.title2)
                    Text(button.unit ?? "").foregroundStyle(.secondary)
                }
                Section { TimeBar() }
            }
            .navigationTitle(button.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { store.logAmount(button, v) }
                        dismiss()
                    }
                    .disabled(Double(text.replacingOccurrences(of: ",", with: ".")) == nil)
                }
            }
            .onAppear { text = button.value.map(Fmt.amount) ?? "" }
        }
        .presentationDetents([.medium])
    }
}
