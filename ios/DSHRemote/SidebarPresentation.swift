import SwiftUI

enum SessionTimeline {
    static func timestamp(_ value: JSON) -> TimeInterval {
        if let number = value.int { return Double(number) / (number > 100_000_000_000 ? 1000 : 1) }
        guard let text = value.string else { return 0 }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970 ?? 0
    }
    static func groups(_ rows: [SessionRow], pinned: [String], now: Date = Date(), calendar: Calendar = .current) -> [SessionGroup] {
        let sorted = rows.sorted { timestamp($0.updatedAt) > timestamp($1.updatedAt) }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? yesterday
        let definitions = [("pinned", L("Pinned", "置顶")), ("today", L("Today", "今天")), ("yesterday", L("Yesterday", "昨天")), ("week", L("This week", "本周")), ("older", L("Earlier", "更早"))]
        var buckets: [String: [SessionRow]] = [:]
        for row in sorted {
            let date = Date(timeIntervalSince1970: timestamp(row.updatedAt))
            let key = pinned.contains(row.id) ? "pinned" : date >= today ? "today" : date >= yesterday ? "yesterday" : date >= week ? "week" : "older"
            buckets[key, default: []].append(row)
        }
        return definitions.compactMap { id, title in
            guard let values = buckets[id], !values.isEmpty else { return nil }
            return SessionGroup(id: id, title: title, sessions: values)
        }
    }
}

@MainActor
final class SidebarReadState: ObservableObject {
    @Published private(set) var dates: [String: Double]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; dates = defaults.dictionary(forKey: "DRP.readSessions") as? [String: Double] ?? [:] }
    func baseline(_ rows: [SessionRow], server: String) {
        let key = "DRP.readBaseline." + server
        guard !defaults.bool(forKey: key) else { return }
        for row in rows where dates[row.id] == nil { dates[row.id] = SessionTimeline.timestamp(row.updatedAt) }
        defaults.set(true, forKey: key); defaults.set(dates, forKey: "DRP.readSessions")
    }
    func mark(_ row: SessionRow) { dates[row.id] = max(Date().timeIntervalSince1970, SessionTimeline.timestamp(row.updatedAt)); defaults.set(dates, forKey: "DRP.readSessions") }
    func unread(_ row: SessionRow) -> Bool { SessionTimeline.timestamp(row.updatedAt) > (dates[row.id] ?? 0) }
}

struct AdaptiveWorkspace<Sidebar: View, Detail: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var visibility: NavigationSplitViewVisibility
    @Binding var column: NavigationSplitViewColumn
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail
    var body: some View {
        if sizeClass == .compact {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    NavigationStack { detail() }
                    if column == .sidebar {
                        Button { column = .detail } label: { Color.black.opacity(0.25).ignoresSafeArea() }
                            .buttonStyle(.plain).accessibilityLabel(L("Close sidebar", "关闭侧栏"))
                    }
                    sidebar().frame(width: min(geometry.size.width * 0.87, 430)).background(.regularMaterial)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28)).shadow(color: .black.opacity(0.15), radius: 20, x: 10)
                        .offset(x: column == .sidebar ? 0 : -geometry.size.width)
                        .opacity(column == .sidebar ? 1 : 0)
                        .allowsHitTesting(column == .sidebar)
                        .accessibilityHidden(column != .sidebar)
                }.animation(.easeOut(duration: 0.2), value: column)
                    .simultaneousGesture(DragGesture().onEnded { value in
                        if value.startLocation.x < 24 && value.translation.width > 70 { column = .sidebar }
                        if column == .sidebar && value.translation.width < -80 { column = .detail }
                    })
            }
        } else { NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $column, sidebar: sidebar, detail: detail).navigationSplitViewStyle(.balanced) }
    }
}
