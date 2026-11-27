import SwiftUI

/// What I watched on Stremio, to rate (public.app_watched / app_rate): movies seen most of the way and shows paused two
/// weeks come up to rate (0-100, Criticker's scale), shows still going can be rated early. A rating goes to Trakt
/// from the PC (scripts/trakt_worker.py; its first connection code shows here) and to Criticker by one tap (it has no
/// API). "For you": the similar-users model's predictions (analysis/movie_taste.py), filtered by genre.
struct WatchedView: View {
    @EnvironmentObject var store: Store
    @State private var data: [String: Any] = [:]
    @State private var section = 0
    @State private var rating: Title?
    @State private var genre = "All"
    @State private var error: String?

    struct Title: Identifiable {
        let id: String
        let name: String
        let kind: String
        let year: String?
        let state: String?
        let score: Int?
        let dismissed: Bool
        let trakt: Bool
        let traktError: String?
        let predicted: Int?
        let neighbours: Int?
        let genres: [String]
        let hours: Double?
        let progress: Double?
        let lastWatched: String?

        init(_ j: [String: Any]) {
            id = j["imdb"] as? String ?? UUID().uuidString
            name = j["name"] as? String ?? "?"
            kind = j["kind"] as? String ?? "movie"
            year = j["year"] as? String
            state = j["state"] as? String
            score = j["score"] as? Int
            dismissed = j["dismissed"] as? Bool ?? false
            trakt = j["trakt"] as? Bool ?? false
            traktError = j["trakt_error"] as? String
            predicted = j["predicted"] as? Int
            neighbours = j["neighbours"] as? Int
            genres = j["genres"] as? [String] ?? []
            hours = (j["hours"] as? NSNumber)?.doubleValue
            progress = (j["progress"] as? NSNumber)?.doubleValue
            lastWatched = j["last_watched"] as? String
        }

        var subtitle: String {
            [kind == "series" ? "Show" : "Movie", year].compactMap { $0 }.joined(separator: " · ")
        }

        /// Criticker has no API: its page for the title, found by a search (DuckDuckGo's first hit on criticker.com).
        var critickerURL: URL? {
            let q = "!ducky site:criticker.com \(name) \(year ?? "")"
            return URL(string: "https://duckduckgo.com/?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
        }
    }

    private func list(_ key: String) -> [Title] { (data[key] as? [[String: Any]] ?? []).map(Title.init) }

    var body: some View {
        NavigationStack {
            List {
                trakt
                Picker("", selection: $section) {
                    Text("To rate").tag(0)
                    Text("Rated").tag(1)
                    Text("For you").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                switch section {
                case 0: toRate
                case 1: rated
                default: picks
                }
            }
            .navigationTitle("Watched")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $rating, onDismiss: { Task { await load() } }) { t in RateSheet(title: t) }
        }
    }

    @ViewBuilder private var trakt: some View {
        let t = data["trakt"] as? [String: Any] ?? [:]
        if let code = t["user_code"] as? String, (t["connected"] as? Bool) != true {
            Section {
                Link(destination: URL(string: t["url"] as? String ?? "https://trakt.tv/activate")!) {
                    Label("Connect Trakt: enter \(code) at trakt.tv/activate", systemImage: "link")
                }
            } footer: { Text("Ratings go to Trakt once it's connected. The code changes every 10 minutes; pull to refresh.") }
        }
    }

    @ViewBuilder private var toRate: some View {
        let titles = list("titles")
        let done = titles.filter { $0.state == "done" }
        let going = titles.filter { $0.state != "done" }
        if titles.isEmpty { Muted(text: "Nothing to rate. Movies come here once watched most of the way, shows once paused for two weeks.") }
        if !done.isEmpty {
            Section("Watched") { ForEach(done) { t in row(t) } }
        }
        if !going.isEmpty {
            Section("Still watching") { ForEach(going) { t in row(t) } }
        }
    }

    @ViewBuilder private var rated: some View {
        let titles = list("rated")
        if titles.isEmpty { Muted(text: "No ratings yet.") }
        ForEach(titles) { t in
            Button { rating = t } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.subheadline.weight(.semibold))
                        Text(t.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if t.dismissed {
                        Text("Skipped").font(.caption).foregroundStyle(.secondary)
                    } else {
                        if t.traktError != nil {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                        } else if t.trakt {
                            Image(systemName: "checkmark.circle").foregroundStyle(.green).font(.caption)
                        }
                        Text("\(t.score ?? 0)").font(.title3.monospacedDigit().weight(.semibold))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var picks: some View {
        let all = list("picks")
        let genres = ["All"] + Array(Set(all.flatMap(\.genres))).filter { $0 != "(no genres listed)" }.sorted()
        let shown = genre == "All" ? all : all.filter { $0.genres.contains(genre) }
        let taste = data["taste"] as? [String: Any]
        if all.isEmpty {
            Muted(text: "Predictions come once about 10 movies are rated (the Criticker history import is the quick start).")
        } else {
            Picker("Genre", selection: $genre) { ForEach(genres, id: \.self) { Text($0).tag($0) } }
            Section {
                ForEach(shown) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.subheadline.weight(.semibold))
                            Text(([t.year].compactMap { $0 } + t.genres.prefix(3)).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(t.predicted ?? 0)").font(.title3.monospacedDigit().weight(.semibold))
                            Text("\(t.neighbours ?? 0) like you").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Seen it") { rating = t }.tint(.blue)
                    }
                }
            } footer: {
                if let cv = taste?["cv"] as? [String: Any], let mae = cv["mae"] {
                    Text("Predicted from the \(taste?["neighbours"] ?? 0) MovieLens raters closest to your taste. On your own ratings it's off by \(mae) points on average (each film's plain average: \(cv["baseline_mae"] ?? "?")). Swipe a film you've seen to rate it.")
                }
            }
        }
    }

    private func row(_ t: Title) -> some View {
        Button { rating = t } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.subheadline.weight(.semibold))
                    Text(t.subtitle + (t.hours.map { String(format: " · %.1f h", $0) } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Rate").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        do {
            let d = try await API(creds: store.creds).rpc("app_watched")
            data = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let title: WatchedView.Title
    @State private var score: Double = 70
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(Int(score))").font(.system(size: 56, weight: .bold).monospacedDigit()).frame(maxWidth: .infinity)
                    Slider(value: $score, in: 0...100, step: 1)
                    HStack {
                        ForEach([20, 40, 60, 75, 90], id: \.self) { v in
                            Button("\(v)") { score = Double(v) }.buttonStyle(.bordered)
                        }
                    }
                } footer: { Text("0-100, Criticker's scale. Trakt gets it as 1-10.") }
                Section {
                    Button {
                        Task { await save(dismissing: false) }
                    } label: { Label("Save", systemImage: "checkmark") }
                    Button {
                        Task {
                            if await save(dismissing: false), let u = title.critickerURL { openURL(u) }
                        }
                    } label: { Label("Save and rate on Criticker", systemImage: "arrow.up.right.square") }
                    Button("Not rating this one") { Task { await save(dismissing: true) } }
                        .foregroundStyle(.secondary)
                    if title.score != nil || title.dismissed {
                        Button("Take the rating back", role: .destructive) { Task { await remove() } }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle(title.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if let s = title.score ?? title.predicted { score = Double(s) } }
        }
        .presentationDetents([.medium, .large])
    }

    @discardableResult
    private func save(dismissing skip: Bool) async -> Bool {
        saving = true
        defer { saving = false }
        var args: [String: Any] = ["p_imdb": title.id, "p_name": title.name, "p_kind": title.kind]
        if let y = title.year { args["p_year"] = y }
        if skip { args["p_dismiss"] = true } else { args["p_score"] = Int(score) }
        do {
            _ = try await API(creds: store.creds).rpc("app_rate", json: args)
            dismiss()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func remove() async {
        do {
            _ = try await API(creds: store.creds).rpc("app_rate", json: ["p_imdb": title.id, "p_delete": true])
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
