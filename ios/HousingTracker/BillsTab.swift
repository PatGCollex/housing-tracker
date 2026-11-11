import SwiftUI

/// The legislation: this week's activity, or every bill, with search and filters.
struct BillsTab: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @State private var scope = "This week"
    @State private var query = ""
    @State private var filter = BillFilter()

    private var shown: [Bill] {
        let base = scope == "This week" && query.isEmpty ? store.thisWeek : store.bills
        let found = store.search(query, in: base, notes: workspace.notes)
        return filter.apply(found)
    }

    private var emptyText: String? {
        if let error = store.loadError { return error }
        if !shown.isEmpty { return nil }
        if filter.isActive || !query.isEmpty { return "Nothing matches." }
        return "No bill activity in the past week. This fills up when the session starts in January."
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $scope) {
                        Text("This week").tag("This week")
                        Text("All bills").tag("All bills")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let recap = store.recap, scope == "This week", query.isEmpty, !filter.isActive {
                    Section {
                        NavigationLink { RecapView(recap: recap) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Weekly recap").font(.headline)
                                Text(recap.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                BillSections(bills: shown)
                Section {} footer: { SourceLine() }
            }
            .overlay { EmptyMessage(text: emptyText) }
            .searchable(text: $query, prompt: "Bill number or keywords")
            .navigationTitle("Bills")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { InboxView() } label: {
                        Image(systemName: store.unreadCount > 0 ? "bell.badge.fill" : "bell")
                    }
                    .accessibilityLabel("Inbox")
                }
                ToolbarItem(placement: .topBarTrailing) { FilterMenu(filter: $filter) }
            }
            .appDestinations()
            .refreshable { await store.refresh() }
        }
    }
}

/// Where the data comes from and when it was last updated.
struct SourceLine: View {
    @EnvironmentObject var store: BillStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Source: Georgia General Assembly, via LegiScan.")
            if let updated = store.lastUpdated {
                Text("Data updated \(DateText.pretty(updated)) at \(timeText(updated)).")
            }
        }
        .font(.caption2)
    }

    private func timeText(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return "" }
        return d.formatted(date: .omitted, time: .shortened)
    }
}
