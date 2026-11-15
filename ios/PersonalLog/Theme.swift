import SwiftUI

/// The emailed report's look (report.STYLE): light gray page, white rounded cards, hairline row separators, soft pills.
enum Theme {
    static let page = Color(red: 0xf4 / 255, green: 0xf5 / 255, blue: 0xf7 / 255)
    static let card = Color.white
    static let text = Color(red: 0x1d / 255, green: 0x23 / 255, blue: 0x30 / 255)
    static let sub = Color(red: 0x37 / 255, green: 0x41 / 255, blue: 0x51 / 255)
    static let muted = Color(red: 0x6b / 255, green: 0x72 / 255, blue: 0x80 / 255)
    static let line = Color(red: 0xee / 255, green: 0xf0 / 255, blue: 0xf3 / 255)
    static let accent = Color(red: 0x37 / 255, green: 0x30 / 255, blue: 0xa3 / 255)
    static let goodBg = Color(red: 0xe7 / 255, green: 0xf6 / 255, blue: 0xec / 255)
    static let good = Color(red: 0x17 / 255, green: 0x66 / 255, blue: 0x3a / 255)
    static let warnBg = Color(red: 0xff / 255, green: 0xf4 / 255, blue: 0xe0 / 255)
    static let warn = Color(red: 0x8a / 255, green: 0x5a / 255, blue: 0x00 / 255)
    static let infoBg = Color(red: 0xee / 255, green: 0xf2 / 255, blue: 0xff / 255)
    static let aiBg = Color(red: 0xee / 255, green: 0xf4 / 255, blue: 0xff / 255)
}

/// A white card with a title and an optional intro line, like the email's sections.
struct Card<Content: View>: View {
    var title: String?
    var intro: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).padding(.bottom, intro == nil ? 6 : 2) }
            if let intro { Text(intro).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.bottom, 6) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

/// A row inside a card: a hairline above it; with a route it opens that page (chevron at the end).
struct CardRow<Content: View>: View {
    var route: Route?
    @ViewBuilder var content: Content

    var body: some View {
        let row = HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) { content }.frame(maxWidth: .infinity, alignment: .leading)
            if route != nil { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted.opacity(0.6)) }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        if let route {
            NavigationLink(value: route) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

struct SubHeader: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub).padding(.top, 10).padding(.bottom, 2)
    }
}

/// robust / tentative / info pills.
struct Pill: View {
    enum Kind { case good, warn, info }
    let text: String
    var kind: Kind = .info

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(kind == .good ? Theme.goodBg : kind == .warn ? Theme.warnBg : Theme.infoBg, in: Capsule())
            .foregroundStyle(kind == .good ? Theme.good : kind == .warn ? Theme.warn : Theme.accent)
    }
}

struct Badge: View {
    let robust: Bool
    var strongLabel = "robust"
    var body: some View { Pill(text: robust ? strongLabel : "tentative", kind: robust ? .good : .warn) }
}

/// The label over a touched chart point: the value, and what it is (a date, or the other axis).
struct ChartTip: View {
    let value: String
    var detail: String = ""

    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

struct Muted: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted) }
}

/// A segmented range: 7 / 30 / 90 days / a year, offering only the ones the data reaches into (a range shows when there
/// is data older than the range below it), and moving off a range that isn't offered.
struct RangePicker: View {
    @Binding var days: Int
    var oldest: Date?

    static let all = [7, 30, 90, 365]

    static func options(oldest: Date?) -> [Int] {
        guard let oldest else { return [7] }
        let span = Date().timeIntervalSince(oldest) / 86400
        return zip(all, [0] + all.dropLast()).filter { _, below in span > Double(below) }.map(\.0)
    }

    var body: some View {
        let opts = Self.options(oldest: oldest)
        Picker("Range", selection: $days) {
            ForEach(opts, id: \.self) { d in Text(d == 365 ? "1 year" : "\(d) days").tag(d) }
        }
        .pickerStyle(.segmented)
        .onAppear { fit(opts) }
        .onChange(of: opts) { _, o in fit(o) }
    }

    /// The chosen range, or the longest offered up to 90 days.
    private func fit(_ opts: [Int]) {
        if !opts.contains(days) { days = opts.filter { $0 <= 90 }.last ?? opts.last ?? 7 }
    }
}

extension View {
    /// A report page: the gray background and card spacing.
    func reportPage() -> some View {
        self.padding(.horizontal, 14).padding(.vertical, 12)
    }
}
