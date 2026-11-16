import SwiftUI

@main
struct PersonalLogApp: App {
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)   // the email's white look
                .onOpenURL { store.handle(url: $0) }
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await store.refresh(); await store.flush() } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var chores = Chores.shared

    var body: some View {
        if store.creds.isComplete {
            tabs
                // the wake alarm's "Take photos" opens the photo steps over whichever tab is showing
                .fullScreenCover(isPresented: $chores.showMorningPhotos) { MorningPhotosView().environmentObject(store) }
        } else {
            NavigationStack { SettingsView() }
        }
    }

    private var tabs: some View {
        TabView {
            LogView().tabItem { Label("Log", systemImage: "square.grid.2x2") }
            ChoresView().tabItem { Label("Chores", systemImage: "checklist") }
            FoodView().tabItem { Label("Food", systemImage: "fork.knife") }
            ReportView().tabItem { Label("Report", systemImage: "chart.xyaxis.line") }
            FindView().tabItem { Label("Find", systemImage: "magnifyingglass") }
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// "Now", or an earlier time for the next tap (then back to now).
struct TimeBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack {
            Image(systemName: "clock")
            if let d = store.backdate {
                DatePicker("", selection: Binding(get: { d }, set: { store.backdate = $0 }), in: ...Date())
                    .labelsHidden()
                Spacer()
                Button("Now") { store.backdate = nil }
            } else {
                Text("Logging at: now").foregroundStyle(.secondary)
                Spacer()
                Button("Earlier…") { store.backdate = Date().addingTimeInterval(-15 * 60) }
            }
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(store.backdate == nil ? Color.clear : Color.orange.opacity(0.15))
    }
}

struct StatusLine: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let m = store.message {
            Text(m).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading)
        } else if !store.queue.isEmpty {
            Text("\(store.queue.count) waiting to send").font(.footnote).foregroundStyle(.orange).padding(.horizontal)
        }
    }
}
