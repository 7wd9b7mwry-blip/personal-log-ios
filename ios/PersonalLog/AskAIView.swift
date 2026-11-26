import PhotosUI
import SwiftUI

/// One "ask the AI to add it" request (public.app_ai_tasks): open / running on the PC, then done with a summary or
/// an error.
struct AITask: Identifiable, Hashable {
    let id: Int
    let request: String
    let status: String
    let summary: String?
    let error: String?
    let photo: Bool

    init?(_ j: [String: Any]) {
        guard let id = (j["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        request = j["request"] as? String ?? ""
        status = j["status"] as? String ?? "open"
        summary = j["summary"] as? String
        error = j["error"] as? String
        photo = j["photo"] as? Bool ?? false
    }

    var pending: Bool { status == "open" || status == "running" }
}

/// Ask the AI (Claude on the PC, scripts/ai_tasks_worker.py) to add a food (it looks the nutrition facts up on the
/// web and files it in a category), to add / change chores (with their schedule and dependencies) and check them off,
/// or to log the Log tab's events ("naproxen at 9am, TV 8 to 10pm") and fix the ones logged wrong. The recent
/// requests show below, refreshed every few seconds while one is in progress; `onDone` reloads the tab when one
/// finishes.
struct AskAIView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let kind: String   // food | chore | event
    var onDone: () async -> Void = {}
    @State private var text = ""
    @State private var tasks: [AITask] = []
    @State private var error: String?
    @State private var sending = false
    @State private var image: UIImage?
    @State private var pick: PhotosPickerItem?
    @State private var camera = false
    @State private var scanning = false
    @FocusState private var focused: Bool

    private var placeholder: String {
        switch kind {
        case "food": return "e.g. Trader Joe's mandarin orange chicken, 1 cup"
        case "event": return "e.g. Naproxen at 9am, 5 g creatine, TV 8 to 10pm"
        default: return "e.g. Laundry every Sunday afternoon, shower only after garbage"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                    if kind == "food" {
                        HStack {
                            Button { camera = true } label: { Label("Camera", systemImage: "camera") }
                                .buttonStyle(.borderless)
                            Spacer()
                            PhotosPicker(selection: $pick, matching: .images) { Label("Photo", systemImage: "photo") }
                                .buttonStyle(.borderless)
                            if BarcodeScanner.available {
                                Spacer()
                                Button { scanning = true } label: { Label("Barcode", systemImage: "barcode.viewfinder") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if let image {
                            HStack {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                                Spacer()
                                Button("Remove", role: .destructive) { self.image = nil; pick = nil }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    Button {
                        Task { await send() }
                    } label: {
                        Label(sending ? "Sending…" : "Ask", systemImage: "sparkles")
                    }
                    .disabled(sending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil))
                } footer: {
                    Text(kind == "food"
                         ? "Claude finds the nutrition facts online and adds the foods to the right category, with the water a drink holds (to Apple Health). A photo of the food or its label works too, with or without words. It can also log what you had (\"mocha at 12pm, 2 Clif bars at 4pm\"), make combos (\"split a Red Bull and a coconut water\") and delete recipes you name. Takes about a minute."
                         : kind == "event"
                         ? "Claude logs what you tell it with the Log tab's buttons: things taken, amounts, symptoms, the kind of day, and sessions (\"TV 8 to 10pm\", \"started work at 9\", \"stopped gaming\"). It fixes ones logged wrong too (\"the naproxen was at 8, not 9\", \"I didn't have creatine today\")."
                         : "Claude adds or changes chores, with when, where, how long and what goes first. It checks chores off too (\"took out the garbage at 3pm\") and takes back ones checked off by mistake.")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if !tasks.isEmpty {
                    Section("Recent") {
                        ForEach(tasks) { t in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    if t.photo { Image(systemName: "photo").font(.caption).foregroundStyle(.secondary) }
                                    Text(t.request).font(.subheadline)
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    switch t.status {
                                    case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    case "error": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    default: ProgressView().controlSize(.mini)
                                    }
                                    Text(t.summary ?? t.error ?? (t.status == "running" ? "Working on it…" : "Waiting for the PC…"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(kind == "food" ? "Foods" : kind == "event" ? "Log with AI" : "Chores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await poll() }
            .onChange(of: pick) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        image = img
                    }
                }
            }
            .fullScreenCover(isPresented: $camera) {
                CameraPicker(front: false, flash: .auto) { img in
                    if let img { image = img }
                    camera = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $scanning) {
                BarcodeScanner { code in
                    if let code { text = (text.isEmpty ? "" : text + " ") + "barcode \(code)" }
                    scanning = false
                }
                .ignoresSafeArea()
            }
            .onAppear { focused = true }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            var args: [String: Any] = ["p_kind": kind, "p_text": text]
            // ~1280 px is plenty to read a label and see a plate
            if let image, let jpeg = image.resized(width: 1280).jpegData(compressionQuality: 0.75) {
                args["p_image"] = jpeg.base64EncodedString()
            }
            _ = try await API(creds: store.creds).rpc("app_ai_ask", json: args)
            text = ""
            image = nil
            pick = nil
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        guard let data = try? await API(creds: store.creds).rpc("app_ai_tasks", json: ["p_kind": kind]),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let new = rows.compactMap(AITask.init)
        let finished = new.contains { n in !n.pending && tasks.contains { $0.id == n.id && $0.pending } }
        tasks = new
        if finished { await onDone() }
    }

    /// Every 3 s while a request is in progress (else every 30 s), as long as the sheet is open.
    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(nanoseconds: (tasks.contains(where: \.pending) ? 3 : 30) * 1_000_000_000)
        }
    }
}
