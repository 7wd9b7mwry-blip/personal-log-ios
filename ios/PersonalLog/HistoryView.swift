import SwiftUI

/// History (opened from the Log tab): a day's logged events from the database, any past day, with full CRUD:
/// add (+: anything at any time: once, an amount or a session with its start and end), tap to change the name, time,
/// amount or note, swipe to delete (it stays deleted: nothing makes it again). "Mine" shows the app's own and the Log
/// tab's buttons (also from a Shortcut, the watch or a sensor under the same names); "Everything" every event of the
/// day (public.app_events p_all: the watch's, chores, sensors, places, music, devices), grouped by where it came from,
/// with a search. This phone's still-unsent taps sit on top (Undo).
struct RecentView: View {
    @EnvironmentObject var store: Store
    @State private var day = LogDay.today()
    @State private var data: EventDay?
    @State private var editing: LoggedEvent?
    @State private var adding = false
    @State private var error: String?
    @State private var search = ""
    @AppStorage("historyAll") private var all = false

    private var isToday: Bool { day == LogDay.today() }

    private func reload() async {
        data = await store.fetchEvents(LogDay.key(day), all: all)
    }

    private var shown: [LoggedEvent] {
        let ev = data?.events ?? []
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? ev : ev.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    static let sources: [(String, String)] = [
        ("manual", "Added by hand"), ("app", "Logged in the app"), ("chore", "Chores"), ("sensor", "Sensors"),
        ("watch", "Watch"), ("device", "Devices"), ("place", "Places"), ("music", "Music"), ("auto", "Automatic"),
        ("other", "Shortcuts and other"),
    ]

    var body: some View {
        List {
            // the day at the top: a bottom toolbar sits under iOS 26's floating tab bar, out of sight
            Section {
                DayPicker(day: $day).frame(maxWidth: .infinity)
                Picker("Show", selection: $all) {
                    Text("Mine").tag(false)
                    Text("Everything").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Any past day: + adds something, tap an entry to change it, swipe to delete.")
            }
            let unsent = store.recent.filter { !$0.sent }
            if isToday && !unsent.isEmpty {
                Section("Sending") {
                    ForEach(unsent) { e in
                        HStack {
                            Text(e.name + (e.kind == "start" ? " started" : e.kind == "end" ? " stopped" : ""))
                            Spacer()
                            Text(e.at.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.circle").foregroundStyle(.orange)
                        }
                        .swipeActions { Button("Undo", role: .destructive) { store.cancel(e) } }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            if all {
                ForEach(Self.sources, id: \.0) { source in
                    let rows = shown.filter { ($0.source ?? "other") == source.0 }
                    if !rows.isEmpty {
                        Section {
                            DisclosureGroup("\(source.1) (\(rows.count))") {
                                ForEach(rows) { e in row(e) }
                            }
                        }
                    }
                }
            } else {
                Section {
                    ForEach(shown) { e in row(e) }
                }
            }
        }
        .overlay {
            if (data?.events.isEmpty ?? true) && !(isToday && store.recent.contains { !$0.sent }) {
                ContentUnavailableView("Nothing logged", systemImage: "clock",
                                       description: Text("Tap + to add something to this day."))
            }
        }
        .searchable(text: $search, prompt: "Find by name")
        .navigationTitle("History · " + LogDay.title(day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { e in EventEditView(event: e) }
        .sheet(isPresented: $adding, onDismiss: { Task { await reload() } }) { EventAddView(day: day) }
        .refreshable { await reload() }
        .task(id: LogDay.key(day) + (all ? "|all" : "|mine")) { await reload() }
    }

    private func row(_ e: LoggedEvent) -> some View {
        Button { editing = e } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(e.title).foregroundStyle(.primary)
                    Text(e.at.formatted(date: .omitted, time: .shortened) + (e.notes.map { " · " + $0 } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let v = e.value, e.kind == "val" {
                    Text("\(Fmt.amount(v)) \(e.unit ?? "")").foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                Task {
                    error = await store.editEvent(e.id, delete: true)
                    await reload()
                }
            }
        }
    }
}

/// Change a logged event's name, time, amount (an amount event) or note, or delete it.
struct EventEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let event: LoggedEvent
    @State private var name = ""
    @State private var at = Date()
    @State private var value: Double = 0
    @State private var notes = ""
    @State private var error: String?

    private var isSessionPart: Bool { event.kind == "start" || event.kind == "end" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    DatePicker(event.kind == "start" ? "Started" : event.kind == "end" ? "Stopped" : "Time",
                               selection: $at, in: ...Date())
                    if event.kind == "val" {
                        HStack {
                            TextField("amount", value: $value, format: .number).keyboardType(.decimalPad)
                            Text(event.unit ?? "").foregroundStyle(.secondary)
                        }
                    }
                    TextField("Note", text: $notes, axis: .vertical)
                } footer: {
                    if isSessionPart {
                        Text("A session's start and its stop are two entries; change the other one too if needed.")
                    }
                }
                Section {
                    Button("Delete", role: .destructive) {
                        Task {
                            if let e = await store.editEvent(event.id, delete: true) { error = e } else { dismiss() }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let n = name.trimmingCharacters(in: .whitespaces)
                            let e = await store.editEvent(event.id, at: at,
                                                          value: event.kind == "val" ? value : nil,
                                                          name: n != event.name ? n : nil,
                                                          notes: notes != (event.notes ?? "") ? notes : nil)
                            if let e { error = e } else { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = event.name; at = event.at; value = event.value ?? 0; notes = event.notes ?? "" }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Add something to a day after the fact: one of the Log tab's buttons or any name; once, an amount, or a session.
struct EventAddView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var name = ""
    @State private var kind = "log"
    @State private var at = Date()
    @State private var end = Date()
    @State private var value: Double?
    @State private var unit = ""
    @State private var notes = ""
    @State private var error: String?
    @State private var saving = false

    private var matches: [ButtonSpec] {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(store.config.groups.flatMap(\.buttons)
            .filter { $0.name.localizedCaseInsensitiveContains(q) && $0.name != q }.prefix(6))
    }

    private func pick(_ b: ButtonSpec) {
        name = b.name
        kind = b.kind == "session" ? "session" : b.kind == "val" ? "val" : "log"
        unit = b.unit ?? ""
        if let v = b.value { value = v }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (kind != "val" || value != nil)
            && (kind != "session" || end > at)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What: a button's name or anything", text: $name)
                    ForEach(matches) { b in
                        Button { pick(b) } label: { Label(b.name, systemImage: "arrow.up.left") }
                    }
                    Menu {
                        ForEach(store.config.groups) { g in
                            Menu(g.title) { ForEach(g.buttons) { b in Button(b.name) { pick(b) } } }
                        }
                    } label: { Label("Pick a button", systemImage: "square.grid.2x2") }
                }
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Once").tag("log")
                        Text("Amount").tag("val")
                        Text("Session").tag("session")
                    }
                    .pickerStyle(.segmented)
                    DatePicker(kind == "session" ? "Start" : "Time", selection: $at, in: ...Date())
                    if kind == "session" {
                        DatePicker("End", selection: $end, in: ...Date())
                    }
                    if kind == "val" {
                        HStack {
                            TextField("amount", value: $value, format: .number).keyboardType(.decimalPad)
                            TextField("unit", text: $unit).frame(maxWidth: 90).textInputAutocapitalization(.never)
                        }
                    }
                    TextField("Note (optional)", text: $notes, axis: .vertical)
                } footer: {
                    if kind == "session" && end <= at { Text("The end must be after the start.") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Add to " + LogDay.title(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            let e = await store.addEvent(name: name.trimmingCharacters(in: .whitespaces), kind: kind,
                                                         at: at, end: kind == "session" ? end : nil,
                                                         value: kind == "val" ? value : nil, unit: unit, notes: notes)
                            saving = false
                            if let e { error = e } else { dismiss() }
                        }
                    }
                    .disabled(!valid || saving)
                }
            }
            .onAppear {
                // today: the last 30 min; a past day: that day at this time of day (its 5 AM day: before 5 the next
                // calendar morning), a session 30 min long
                let cal = Calendar.current
                let now = Date()
                if day == LogDay.today() {
                    at = now.addingTimeInterval(-30 * 60)
                    end = now
                } else {
                    let h = cal.component(.hour, from: now), m = cal.component(.minute, from: now)
                    let base = cal.date(byAdding: .day, value: h < LogDay.startHour ? 1 : 0, to: day) ?? day
                    at = cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? day
                    end = at.addingTimeInterval(30 * 60)
                }
            }
        }
        .presentationDetents([.large])
    }
}
