import SwiftUI

/// The setup: the database connection, the send queue, the MacroFactor Shortcut. History is in HistoryView.swift.
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
