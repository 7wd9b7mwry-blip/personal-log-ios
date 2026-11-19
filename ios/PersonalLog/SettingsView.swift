import SwiftUI

/// The last taps (a queued one can still be taken back; opened from the Log tab), and the setup.
/// A day's logged events from the database (public.app_events: the Log tab's buttons, from the app, a Shortcut or
/// the watch, and sensor-made ones of the same names), with this phone's still-unsent ones on top (Undo). Swipe to
/// delete one (it stays deleted: nothing makes it again), tap to change its time or value.
struct RecentView: View {
    @EnvironmentObject var store: Store
    @State private var day = LogDay.today()
    @State private var data: EventDay?
    @State private var editing: LoggedEvent?
    @State private var error: String?

    private var isToday: Bool { day == LogDay.today() }

    private func reload() async {
        data = await store.fetchEvents(LogDay.key(day))
    }

    var body: some View {
        List {
            // the day at the top: a bottom toolbar sits under iOS 26's floating tab bar, out of sight
            Section { DayPicker(day: $day).frame(maxWidth: .infinity) } footer: {
                Text("Pick any past day to edit or delete what was logged.")
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
            Section {
                ForEach(data?.events ?? []) { e in
                    Button { editing = e } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(e.title).foregroundStyle(.primary)
                                Text(e.at.formatted(date: .omitted, time: .shortened)
                                     + (e.from == "sensor" ? " · sensor" : e.from == "other" ? " · Shortcut / watch" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
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
            } footer: {
                Text("Swipe to delete, tap to change the time or amount. A deleted event stays deleted.")
            }
        }
        .overlay {
            if (data?.events.isEmpty ?? true) && !(isToday && store.recent.contains { !$0.sent }) {
                ContentUnavailableView("Nothing logged", systemImage: "clock")
            }
        }
        .navigationTitle("History · " + LogDay.title(day))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { e in EventEditView(event: e) }
        .refreshable { await reload() }
        .task(id: day) { await reload() }
    }
}

/// Change a logged event's time (and its amount, for an amount event), or delete it.
struct EventEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let event: LoggedEvent
    @State private var at = Date()
    @State private var value: Double = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Time", selection: $at, in: ...Date())
                    if event.kind == "val" {
                        HStack {
                            TextField("amount", value: $value, format: .number).keyboardType(.decimalPad)
                            Text(event.unit ?? "").foregroundStyle(.secondary)
                        }
                    }
                } header: { Text(event.title) } footer: {
                    if event.guava { Text("Its copy in Guava isn't changed from here.") }
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
                            let e = await store.editEvent(event.id, at: at,
                                                          value: event.kind == "val" ? value : nil)
                            if let e { error = e } else { dismiss() }
                        }
                    }
                }
            }
            .onAppear { at = event.at; value = event.value ?? 0 }
        }
        .presentationDetents([.medium])
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var draft = Credentials()
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("https://<project>.supabase.co", text: $draft.url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Publishable key", text: $draft.key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Ingest token", text: $draft.token)
                Button(testing ? "Connecting…" : "Save and connect") {
                    testing = true
                    Task { await store.saveCredentials(draft); testing = false }
                }
                .disabled(!draft.isComplete || testing)
            } header: {
                Text("Database")
            } footer: {
                Text("The same URL, key and token as the Shortcuts. Stored in the Keychain on this phone.")
            }
            Section("Status") {
                if let m = store.message { Text(m).font(.footnote) }
                LabeledContent("Waiting to send", value: "\(store.queue.count)")
                if let r = store.refreshedAt { LabeledContent("Updated", value: Fmt.ago(r)) }
                Button("Send now") { Task { await store.flush() } }.disabled(store.queue.isEmpty)
                Button("Refresh buttons and recipes") { Task { await store.refresh() } }
            }
            Section {
                if let file = Bundle.main.url(forResource: "Log Foods From App", withExtension: "shortcut") {
                    ShareLink(item: file) { Label("Add the shortcut", systemImage: "square.and.arrow.down") }
                }
                Text("""
                Foods go to MacroFactor through the Shortcut "\(store.config.foodShortcut)". To install it, tap \
                Add the shortcut, then Shortcuts in the share sheet.
                """)
                .font(.footnote)
            } header: {
                Text("MacroFactor")
            }
            Section {
                Text("Buttons come from the database (analysis.setting 'app'); change them there and refresh.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .onAppear { draft = store.creds }
    }
}
