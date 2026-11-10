import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NewView()
                .tabItem { Label("New", systemImage: "sparkles") }
            WatchingView()
                .tabItem { Label("Watching", systemImage: "star") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
    }
}

// MARK: - New

struct NewView: View {
    @EnvironmentObject var store: BillStore
    @State private var filter = "All"

    private var shown: [Bill] {
        store.newBills.filter { filter == "All" || $0.jurisdiction == filter }
    }

    var body: some View {
        NavigationStack {
            List {
                if let recap = store.recap {
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
                Section {
                    Picker("Show", selection: $filter) {
                        Text("All").tag("All")
                        Text("Federal").tag("Federal")
                        Text("Georgia").tag("Georgia")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(shown) { bill in
                        NavigationLink(value: bill) { BillRow(bill: bill) }
                    }
                } footer: {
                    if let updated = store.lastUpdated {
                        Text("Updated \(DateText.pretty(updated))")
                    }
                }
            }
            .overlay { EmptyMessage(text: store.loadError ?? (shown.isEmpty ? "No recent changes." : nil)) }
            .navigationTitle("Housing Bills")
            .navigationDestination(for: Bill.self) { BillDetailView(bill: $0) }
            .refreshable { await store.refresh() }
        }
    }
}

// MARK: - Watching

struct WatchingView: View {
    @EnvironmentObject var store: BillStore

    var body: some View {
        NavigationStack {
            List(store.watching) { bill in
                NavigationLink(value: bill) { BillRow(bill: bill) }
            }
            .overlay {
                EmptyMessage(text: store.watching.isEmpty
                             ? "Tap the star on any bill to watch it. You'll get an alert when it changes."
                             : nil)
            }
            .navigationTitle("Watching")
            .navigationDestination(for: Bill.self) { BillDetailView(bill: $0) }
            .refreshable { await store.refresh() }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var store: BillStore
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(store.search(query)) { bill in
                NavigationLink(value: bill) { BillRow(bill: bill) }
            }
            .searchable(text: $query, prompt: "Bill number or topic")
            .navigationTitle("Search")
            .navigationDestination(for: Bill.self) { BillDetailView(bill: $0) }
        }
    }
}

// MARK: - Shared pieces

struct BillRow: View {
    let bill: Bill

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(bill.isGeorgia ? "GA \(bill.number)" : bill.number)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let label = bill.changeLabel {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
            }
            Text(bill.displayHeadline).font(.body).lineLimit(3)
            HStack(spacing: 8) {
                Text(bill.status)
                if let impact = bill.impact, impact != "Neutral" {
                    Text("·")
                    Text(impact)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct EmptyMessage: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(40)
        }
    }
}

struct RecapView: View {
    let recap: WeeklyRecap

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Week of \(DateText.pretty(recap.weekOf))").font(.subheadline).foregroundStyle(.secondary)
                Text(recap.summary).font(.body)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Weekly recap")
        .navigationBarTitleDisplayMode(.inline)
    }
}
