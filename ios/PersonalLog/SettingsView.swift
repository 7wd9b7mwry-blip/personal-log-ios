import SwiftUI

/// The last taps (a queued one can still be taken back; opened from the Log tab), and the setup.
struct RecentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            List {
                ForEach(store.recent) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.name + (e.kind == "start" ? " started" : e.kind == "end" ? " stopped" : ""))
                            Text(e.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if e.kind == "val" { Text("\(Fmt.amount(e.val)) \(e.unit ?? "")").foregroundStyle(.secondary) }
                        Image(systemName: e.sent ? "checkmark.circle.fill" : "arrow.up.circle")
                            .foregroundStyle(e.sent ? Color.green : Color.orange)
                    }
                    .swipeActions {
                        if !e.sent { Button("Undo", role: .destructive) { store.cancel(e) } }
                    }
                }
            }
            .overlay { if store.recent.isEmpty { ContentUnavailableView("Nothing logged yet", systemImage: "clock") } }
            .navigationTitle("Recent")
            .navigationBarTitleDisplayMode(.inline)
        }
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
                Text("""
                Foods go to MacroFactor through the Shortcut "\(store.config.foodShortcut)". Its input is JSON: \
                {"recipe", "time", "items": [{"kind": "food", "name", "serving", "count"} | {"kind": "water", "fl_oz"}]}. \
                See the README (iOS logging app) for its steps.
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
