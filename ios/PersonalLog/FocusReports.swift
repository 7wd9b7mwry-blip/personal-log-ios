import SwiftUI
import UIKit

/// A focused report (analysis.report_focus): one question or audience ("for my trainer", "for my doctor", "is caffeine
/// hurting my sleep?") that the AI writes its own report for (app-insight page "focus"), from the same findings as the
/// overview, rewritten with each daily report.
struct FocusReport: Codable, Hashable, Identifiable {
    let id: Int
    var title: String
    var question: String
}

/// The Report tab's list of focused reports, under the overview's AI look.
struct FocusListCard: View {
    @EnvironmentObject var store: Store
    @State private var adding = false

    var body: some View {
        Card(title: "Your reports", intro: "A report written for one question or person (a trainer, a doctor). Each new daily report rewrites them.") {
            ForEach(store.focusReports) { f in
                CardRow(route: .focus(f)) {
                    Text(f.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Muted(text: f.question).font(.system(size: 12)).lineLimit(2)
                }
            }
            Button { adding = true } label: {
                Label("New report from a question", systemImage: "plus.bubble").font(.system(size: 14, weight: .medium))
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $adding) { FocusEditSheet(focus: nil) }
        .task { await store.loadFocusReports() }
    }
}

/// One focused report: its question, the AI's report for it (headline and sections, as on the overview), edit, delete
/// and a PDF.
struct FocusReportView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let r: ReportData
    let focus: FocusReport
    @State private var editing = false
    @State private var confirmDelete = false

    private var current: FocusReport { store.focusReports.first { $0.id == focus.id } ?? focus }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Muted(text: current.question).font(.system(size: 13))
                InsightCard(page: .focus(current.id), auto: true, title: current.title)
                    .id(current.question)   // a changed question loads its new report
            }
            .reportPage()
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { PDFButton(r: r, focus: current) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit the question") { editing = true }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editing) { FocusEditSheet(focus: current) }
        .confirmationDialog("Delete this report?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task { if await store.deleteFocus(current.id) == nil { dismiss() } }
            }
        }
    }
}

/// Add or change a focused report: a short name and the question or audience.
struct FocusEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let focus: FocusReport?
    @State private var title = ""
    @State private var question = ""
    @State private var error: String?
    @State private var saving = false

    static let examples = [
        ("For my trainer", "What would my personal trainer want to know at a high level: training load, recovery, sleep, body composition and what to adjust?"),
        ("For my doctor", "What would my doctor want to know: sleep, heart rate and HRV, weight, symptoms and medications, and anything trending the wrong way?"),
        ("Caffeine and sleep", "How do the amount and timing of caffeine go with my sleep and recovery?"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. For my trainer)", text: $title)
                    TextField("The question, or who it's for and what they care about", text: $question, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("The AI writes a report just for this from your latest daily report: a headline and the sections that matter for it.")
                }
                if focus == nil {
                    Section("Examples") {
                        ForEach(Self.examples, id: \.0) { ex in
                            Button { title = ex.0; question = ex.1 } label: {
                                VStack(alignment: .leading) {
                                    Text(ex.0)
                                    Text(ex.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(focus == nil ? "New report" : "Edit report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(focus == nil ? "Create" : "Save") {
                        saving = true
                        Task {
                            let e = await store.saveFocus(id: focus?.id, title: title, question: question)
                            saving = false
                            if let e { error = e } else { dismiss() }
                        }
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .onAppear { title = focus?.title ?? ""; question = focus?.question ?? "" }
        }
    }
}

// MARK: PDF

/// Makes a PDF of the report (the overview: its AI look, key metrics, Try this, timing) or of one focused report (its
/// question and AI report), then opens the share sheet (save to Files, mail, print).
struct PDFButton: View {
    @EnvironmentObject var store: Store
    let r: ReportData
    var focus: FocusReport? = nil
    @State private var file: SharedFile?
    @State private var making = false
    @State private var error: String?

    var body: some View {
        Button {
            making = true
            Task {
                let page: InsightPage = focus.map { .focus($0.id) } ?? .home
                let insight = try? await store.insight(page, cachedOnly: true)
                file = ReportPDF.make(r: r, focus: focus, insight: insight?.ready == true ? insight : nil)
                making = false
            }
        } label: {
            if making { ProgressView() } else { Image(systemName: "doc.richtext") }
        }
        .accessibilityLabel("PDF")
        .sheet(item: $file) { f in ActivityView(items: [f.url]) }
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

enum ReportPDF {
    static let pageSize = CGSize(width: 612, height: 792)   // US Letter, points
    static let margin: CGFloat = 40

    @MainActor
    static func make(r: ReportData, focus: FocusReport?, insight: Insight?) -> SharedFile? {
        let width = pageSize.width - 2 * margin
        let content = PDFContent(r: r, focus: focus, insight: insight).frame(width: width, alignment: .leading)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let name = (focus?.title ?? "Report") + " " + (r.date ?? "")
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe + ".pdf")
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: pageSize)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            let usable = pageSize.height - 2 * margin
            let pages = max(1, Int(ceil(size.height / usable)))
            for p in 0..<pages {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                // clip to the page's band of the content, then shift the content up by the pages before
                ctx.clip(to: CGRect(x: margin, y: margin, width: width, height: usable))
                ctx.translateBy(x: margin, y: pageSize.height - margin - size.height + CGFloat(p) * usable)
                draw(ctx)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
            ctx.closePDF()
            ok = true
        }
        return ok ? SharedFile(url: url) : nil
    }
}

/// The printed report: plain text on white, no charts or links.
private struct PDFContent: View {
    let r: ReportData
    let focus: FocusReport?
    let insight: Insight?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(focus?.title ?? "Health and habits report").font(.system(size: 20, weight: .bold))
            Text("From the daily report of \(r.date ?? "")").font(.system(size: 11)).foregroundStyle(.secondary)
            if let f = focus { Text(f.question).font(.system(size: 12)).italic() }
            if let i = insight {
                if let h = i.headline { Text(LinkedText.plain(h)).font(.system(size: 14, weight: .semibold)).padding(.top, 6) }
                ForEach(Array((i.sections ?? []).enumerated()), id: \.offset) { _, sec in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(sec.label): \(LinkedText.plain(sec.title))").font(.system(size: 13, weight: .semibold))
                        if let reason = sec.reason { Text(LinkedText.plain(reason)).font(.system(size: 11)) }
                        ForEach(Array(sec.items.enumerated()), id: \.offset) { _, l in
                            Text("• " + LinkedText.plain(l.title ?? "") + (l.why.isEmpty ? "" : ": " + LinkedText.plain(l.why)))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                ForEach(i.caveats ?? [], id: \.self) { c in Text("Note: " + LinkedText.plain(c)).font(.system(size: 10)).foregroundStyle(.secondary) }
            } else {
                Text("The AI report isn't ready yet; open it in the app first.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if focus == nil {
                heading("Key metrics")
                ForEach(r.keyMetrics) { k in
                    let d = k.drivers.first
                    Text("• \(r.name(k.id))" + (k.goal.map { $0 == "min" ? " (lower is better)" : " (higher is better)" } ?? "")
                         + (d.map { ": goes with \(r.name($0.lever))\($0.lag > 0 ? " the day before" : "")" } ?? ""))
                        .font(.system(size: 11))
                }
                if !r.tries.isEmpty {
                    heading("Try this (ideas to test, not proof)")
                    ForEach(r.tries.prefix(8)) { t in
                        Text("• \(t.more ? "More" : "Less") \(r.name(t.lever)), \(t.horizon): may improve "
                             + t.targets.prefix(3).map { r.name($0.target) }.joined(separator: ", "))
                            .font(.system(size: 11))
                    }
                }
                if !r.timing.isEmpty {
                    heading("Timing before bed")
                    ForEach(r.timing.prefix(10)) { t in
                        Text("• \(t.habit) \(ReportHome.span(t)): \(r.name(t.target)) \(t.helps ? "better" : "worse")")
                            .font(.system(size: 11))
                    }
                }
            }
            Text("Observational data from my own tracking; written partly by AI and may contain mistakes. Not medical advice.")
                .font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 12)
        }
        .foregroundStyle(.black)
        .background(Color.white)
    }

    private func heading(_ t: String) -> some View {
        Text(t).font(.system(size: 14, weight: .bold)).padding(.top, 10)
    }
}
