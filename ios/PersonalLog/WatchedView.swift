import SwiftUI

/// What I watched on Stremio, to rate (public.app_watched / app_rate): movies seen most of the way and shows paused two
/// weeks come up to rate (0-100, Criticker's scale), shows still going can be rated early. A rating goes to Trakt
/// from the PC (scripts/trakt_worker.py; its first connection code shows here) and to Criticker by one tap (it has no
/// API). "For you": live recommendation lists in their own order (Couchmoney's lists on my Trakt account, Trakt's own
/// recommendations, Steam's More like this for games), with IMDb / Rotten Tomatoes / Steam review % and the effect on
/// me. Search (Stremio's catalog, Steam's store search) shows where any title sits in those lists, and rates it.
struct WatchedView: View {
    @EnvironmentObject var store: Store
    @State private var data: [String: Any] = [:]
    @State private var section = 0
    @State private var rating: Title?
    @State private var listIndex = 0
    @State private var byPredicted = false
    @State private var ai: [String: [String: Any]] = [:]   // the AI picks per For you list (app-insight "watched:<list>")
    @State private var query = ""
    @State private var results: [Title] = []
    @State private var looking: Title?
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
        let rank: Int?
        let why: String?
        let imdbRating: Double?
        let rtCritics: Int?
        let rtAudience: Int?
        let reviewPct: Double?
        let effect: Double?
        let combined: Int?
        let parts: [String: Int]
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
            rank = j["rank"] as? Int
            why = j["why"] as? String
            imdbRating = (j["imdb_rating"] as? NSNumber)?.doubleValue ?? Double(j["imdbRating"] as? String ?? "")
            rtCritics = j["rt_critics"] as? Int
            rtAudience = j["rt_audience"] as? Int
            reviewPct = (j["review_pct"] as? NSNumber)?.doubleValue
            effect = (j["effect"] as? NSNumber)?.doubleValue
            combined = (j["combined"] as? NSNumber)?.intValue
            parts = (j["parts"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
            hours = (j["hours"] as? NSNumber)?.doubleValue
            progress = (j["progress"] as? NSNumber)?.doubleValue
            lastWatched = j["last_watched"] as? String
        }

        var isGame: Bool { kind == "game" }

        var subtitle: String {
            [kind == "series" ? "Show" : isGame ? "Game" : "Movie", year].compactMap { $0 }.joined(separator: " · ")
        }

        /// What people think, in one line: IMDb, Rotten Tomatoes (critics / audience), Steam review %, effect on me.
        var scores: String {
            var s: [String] = []
            if let r = imdbRating { s.append(String(format: "IMDb %.1f", r)) }
            if let c = rtCritics { s.append("RT \(c)%" + (rtAudience.map { " / \($0)%" } ?? "")) }
            if let p = reviewPct { s.append(String(format: "Steam %.0f%%", p)) }
            if let e = effect { s.append(String(format: "on me %+.1f", e)) }
            return s.joined(separator: " · ")
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
                if !query.isEmpty && !results.isEmpty {
                    Section("Search") {
                        ForEach(results) { t in
                            Button { looking = t } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.subheadline.weight(.semibold))
                                    Text([t.subtitle, t.scores].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                switch section {
                case 0: toRate
                case 1: rated
                default: picks
                }
            }
            .searchable(text: $query, prompt: "Any movie, show or game")
            .onSubmit(of: .search) { Task { await search() } }
            .sheet(item: $looking) { t in LookupSheet(title: t, rate: {
                looking = nil   // one sheet at a time: the rating sheet once this one is gone
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { rating = t }
            }) }
            .navigationTitle("Media")
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
        Text("Personal Log uses Trakt but is not endorsed or certified by Trakt.")
            .font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
    }

    /// The AI's picks from the ranked lists, made on the PC like the report's pages (once per daily report).
    @ViewBuilder private func aiPicks(_ list: String) -> some View {
        let ai = self.ai[list] ?? [:]
        let picks = ai["picks"] as? [[String: Any]] ?? []
        if !picks.isEmpty {
            Section {
                if let h = ai["headline"] as? String, !h.isEmpty { Text(h).font(.subheadline.weight(.semibold)) }
                ForEach(Array(picks.enumerated()), id: \.offset) { _, p in
                    Button { looking = Title(p) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p["name"] as? String ?? "?").font(.subheadline.weight(.semibold))
                                Spacer()
                                if let c = p["combined"] as? Int { Text("\(c)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                            }
                            Text(p["why"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array((ai["avoid"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skip: " + (p["name"] as? String ?? "?")).font(.subheadline)
                        Text(p["why"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Label("AI picks", systemImage: "sparkles") }
        } else if ai["queued"] as? Bool == true || ai["pending"] as? Bool == true {
            Section { HStack { ProgressView(); Text("The AI is picking from your lists…").foregroundStyle(.secondary) } }
                header: { Label("AI picks", systemImage: "sparkles") }
        }
    }

    @ViewBuilder private var picks: some View {
        let lists = data["lists"] as? [[String: Any]] ?? []
        if lists.isEmpty {
            Muted(text: "Lists come from Trakt (Couchmoney's lists and Trakt's own picks) and Steam once they've synced.")
        } else {
            let i = min(listIndex, lists.count - 1)
            Picker("List", selection: $listIndex) {
                ForEach(lists.indices, id: \.self) { k in Text(lists[k]["label"] as? String ?? "?").tag(k) }
            }
            aiPicks(lists[i]["list"] as? String ?? "films")
            if lists[i]["combined"] as? Bool != true {
                Toggle("Sort by my predicted score", isOn: $byPredicted)
            }
            Section {
                let items = (lists[i]["items"] as? [[String: Any]] ?? []).map(Title.init)
                ForEach(byPredicted ? items.sorted { ($0.predicted ?? -1) > ($1.predicted ?? -1) } : items) { t in
                    Button { looking = t } label: {
                        HStack(alignment: .top) {
                            Text("\(t.rank ?? 0)").font(.subheadline.monospacedDigit().weight(.semibold))
                                .frame(width: 30, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.subheadline.weight(.semibold))
                                Text(([t.year].compactMap { $0 } + t.genres.prefix(3)).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !t.scores.isEmpty { Text(t.scores).font(.caption2).foregroundStyle(.secondary) }
                                if let w = t.why { Text(w).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                            }
                            Spacer()
                            if let c = t.combined {
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text("\(c)").font(.title3.monospacedDigit().weight(.semibold))
                                    Text("overall").font(.caption2).foregroundStyle(.secondary)
                                }
                            } else if let p = t.predicted {
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text("\(p)").font(.title3.monospacedDigit().weight(.semibold))
                                    Text(t.isGame ? "fit" : "for me").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions { Button("Seen it") { rating = t }.tint(.blue) }
                }
            } footer: {
                if lists[i]["combined"] as? Bool == true {
                    Text("Overall 0-100: where similar-taste lists put it (45%), my predicted score (45%; it weighs critics and audiences as much as my own ratings show they matter), its effect on my key markers (10%), over the parts each title has. Tap one for the breakdown; swipe one you've seen to rate it.")
                } else {
                    Text("The number on the left is the list's own rank; on the right, my trait model's predicted score. Tap one to see where it sits in every list; swipe one you've seen to rate it.")
                }
            }
        }
    }

    /// Stremio's catalog (movies, shows) and Steam's store search (games), no keys.
    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
        var out: [Title] = []
        for kind in ["movie", "series"] {
            if let u = URL(string: "https://v3-cinemeta.strem.io/catalog/\(kind)/top/search=\(enc).json"),
               let resp = try? await URLSession.shared.data(from: u),
               let j = try? JSONSerialization.jsonObject(with: resp.0) as? [String: Any] {
                for m in (j["metas"] as? [[String: Any]] ?? []).prefix(6) {
                    var x = m
                    x["imdb"] = m["imdb_id"] ?? m["id"]
                    x["kind"] = kind
                    x["year"] = (m["releaseInfo"] as? String).map { String($0.prefix(4)) }
                    out.append(Title(x))
                }
            }
        }
        if let qq = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let u = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(qq)&cc=us&l=en"),
           let resp = try? await URLSession.shared.data(from: u),
           let j = try? JSONSerialization.jsonObject(with: resp.0) as? [String: Any] {
            for g in (j["items"] as? [[String: Any]] ?? []).prefix(5) {
                out.append(Title(["imdb": "steam:\(g["id"] ?? "")", "name": g["name"] ?? "?", "kind": "game"]))
            }
        }
        results = out
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
        // the AI picks for each list: made on the PC after each daily report (asked for here if they're missing)
        for list in ["films", "shows", "movies", "games"] {
            if let d = try? await API(creds: store.creds).function("app-insight", json: ["page": "watched", "list": list], timeout: 30),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                ai[list] = j
            }
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
                } footer: { Text(title.isGame ? "0-100. Game ratings steer the game list." : "0-100, Criticker's scale. Trakt gets it as 1-10.") }
                Section {
                    Button {
                        Task { await save(dismissing: false) }
                    } label: { Label("Save", systemImage: "checkmark") }
                    if !title.isGame {
                        Button {
                            Task {
                                if await save(dismissing: false), let u = title.critickerURL { openURL(u) }
                            }
                        } label: { Label("Save and rate on Criticker", systemImage: "arrow.up.right.square") }
                    }
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

/// One title from a list or the search: where it sits in every list, my rating, what people think, rate it.
struct LookupSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let title: WatchedView.Title
    let rate: () -> Void
    @State private var info: [String: Any] = [:]
    @State private var meta: [String: Any] = [:]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(title.subtitle).foregroundStyle(.secondary)
                    if !title.scores.isEmpty { Text(title.scores) }
                    if title.imdbRating == nil, let r = meta["imdbRating"] as? String, !r.isEmpty { Text("IMDb \(r)") }
                    if let g = meta["genres"] as? [String], !g.isEmpty { Text(g.joined(separator: " · ")).font(.caption) }
                    if let d = meta["description"] as? String { Text(d).font(.caption).foregroundStyle(.secondary) }
                    if let f = info["film"] as? [String: Any], let rt = f["rt_critics"] as? Int {
                        Text("Rotten Tomatoes \(rt)%" + ((f["rt_audience"] as? Int).map { ", audience \($0)%" } ?? ""))
                    }
                    if let g = info["game"] as? [String: Any], let h = (g["playtime_h"] as? NSNumber)?.doubleValue {
                        Text(String(format: "You've played %.1f h", h))
                    }
                }
                if (info["scoring"] as? Bool) == true && overall == nil {
                    Section {
                        HStack { ProgressView(); Text("Scoring this title on the PC: a minute or two.").foregroundStyle(.secondary) }
                    }
                }
                if let c = overall {
                    Section {
                        Text("Overall for you: \(c)").font(.headline)
                        let names = ["discovery": "Where similar-taste lists put it", "model": "My predicted score",
                                     "effect": "Effect on my key markers"]
                        ForEach(["discovery", "model", "effect"], id: \.self) { k in
                            HStack {
                                Text(names[k] ?? k)
                                Spacer()
                                Text(parts[k].map { "\($0)" } ?? "–").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let p = predicted {
                    Section {
                        Text("Predicted for you: \(p)").font(.headline)
                    } footer: {
                        Text(title.isGame ? "From Steam's voted tags, fitted to what you play most (0-100 among your games)."
                                          : "From what Rotten Tomatoes audience and critic reviews, Trakt comments, Wikipedia and the description say it's like, its genres and IMDb rating, fitted to your ratings.")
                    }
                }
                Section("In your lists") {
                    let ranks = info["ranks"] as? [[String: Any]] ?? []
                    if ranks.isEmpty {
                        Text("Not on any list: Couchmoney, Trakt and Steam don't rank it for you.").foregroundStyle(.secondary)
                    }
                    ForEach(ranks.indices, id: \.self) { k in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(ranks[k]["rank"] as? Int ?? 0) of \(ranks[k]["of"] as? Int ?? 0) in \(label(ranks[k]))")
                            // what of mine put it there (related / Steam lists: "Like Review, Silicon Valley, ...")
                            if let w = ranks[k]["why"] as? String, !w.isEmpty {
                                Text(w).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    if let r = info["rating"] as? [String: Any], let s = r["score"] as? Int {
                        Text("You rated it \(s)")
                    }
                    Button { rate() } label: { Label("Rate it", systemImage: "star") }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle(title.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private var overall: Int? { (info["combined"] as? NSNumber)?.intValue ?? title.combined }

    private var parts: [String: Int] {
        let p = (info["parts"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        return p.isEmpty ? title.parts : p
    }

    private var predicted: Int? {
        (info["film"] as? [String: Any])?["predicted"] as? Int ?? (info["game"] as? [String: Any])?["predicted"] as? Int
            ?? title.predicted
    }

    private func label(_ r: [String: Any]) -> String {
        let source = r["source"] as? String ?? "", list = r["list"] as? String ?? ""
        switch source {
        case "couchmoney": return list
        case "trakt": return "Trakt \(list)"
        case "related": return "related to my favourite \(list)"
        case "steam": return list == "upcoming" ? "upcoming games" : "Steam games"
        default: return list
        }
    }

    private func lookup() async {
        do {
            let d = try await API(creds: store.creds).rpc("app_title_lookup", json: ["p_imdb": title.id])
            info = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        await lookup()
        // not scored yet (a search result the PC hasn't seen): ask the PC, then look again while the sheet is open
        if !title.isGame && (info["film"] as? [String: Any]) == nil && error == nil {
            _ = try? await API(creds: store.creds).rpc("app_title_score", json: ["p_imdb": title.id, "p_kind": title.kind,
                                                                                 "p_name": title.name])
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { return }
                await lookup()
                if overall != nil && (info["scoring"] as? Bool) != true { break }
            }
        }
        // what it is (Stremio's catalog, no key), for titles the PC hasn't looked up
        if !title.isGame, let u = URL(string: "https://v3-cinemeta.strem.io/meta/\(title.kind)/\(title.id).json"),
           let resp = try? await URLSession.shared.data(from: u),
           let j = try? JSONSerialization.jsonObject(with: resp.0) as? [String: Any] {
            meta = j["meta"] as? [String: Any] ?? [:]
        }
    }
}
