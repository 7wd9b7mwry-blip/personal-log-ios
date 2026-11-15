import SwiftUI

/// The buttons, grouped as in the server's `app` setting. A session button shows how long it has been running; the
/// others when they were last logged.
struct LogView: View {
    @EnvironmentObject var store: Store
    @State private var amountFor: ButtonSpec?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TimeBar()
                ScrollView {
                    StatusLine()
                    if store.config.groups.isEmpty {
                        ContentUnavailableView("No buttons yet", systemImage: "square.grid.2x2",
                                               description: Text("Pull to refresh once connected."))
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(store.config.groups) { g in
                                Text(g.title).font(.headline).padding(.horizontal)
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(g.buttons) { b in
                                        tile(b, now: ctx.date)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
                .refreshable { await store.refresh(); await store.flush() }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { RecentView() } label: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
            .sheet(item: $amountFor) { b in AmountSheet(button: b) }
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
