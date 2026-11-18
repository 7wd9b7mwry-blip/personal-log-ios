import SwiftUI

/// The issue log on its own (a tab under More): what the daily review keeps finding wrong in the report and the data
/// behind it, open ones by kind (bugs first), then the ones fixed lately. Claude works through the actionable ones
/// every day after the report (scripts/fix_issues.py); a fix shows up here as "fixed".
struct IssuesView: View {
    @EnvironmentObject var store: Store

    private static let order = ["bug", "data", "method", "display"]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.page.ignoresSafeArea()
                let issues = store.report?.review?.issues ?? []
                if issues.isEmpty {
                    Muted(text: store.report == nil ? "The issue log comes with the report." : "No open issues.").padding(32)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            let open = issues.filter { !$0.fixed }
                            ForEach(Self.order + Set(open.compactMap(\.kind)).subtracting(Self.order).sorted(), id: \.self) { kind in
                                let rows = open.filter { ($0.kind ?? "") == kind }
                                if !rows.isEmpty {
                                    Card(title: "\(rows[0].kindLabel) · \(rows.count) open") {
                                        ForEach(rows) { i in
                                            NavigationLink { IssueView(issue: i) } label: { IssueRow(issue: i) }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            let fixed = issues.filter(\.fixed)
                            if !fixed.isEmpty {
                                Card(title: "Fixed today") {
                                    ForEach(fixed) { i in
                                        NavigationLink { IssueView(issue: i) } label: { IssueRow(issue: i) }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Issues")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { IdeasView() } label: { Label("Ideas", systemImage: "lightbulb") }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
