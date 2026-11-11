import SwiftUI

/// Four tabs: Bills (the legislation), My Work (your workspace), Capitol (today, calendar, people), Reports.
struct ContentView: View {
    var body: some View {
        TabView {
            BillsTab()
                .tabItem { Label("Bills", systemImage: "doc.text") }
            WorkTab()
                .tabItem { Label("My Work", systemImage: "briefcase") }
            CapitolTab()
                .tabItem { Label("Capitol", systemImage: "building.columns") }
            ReportsTab()
                .tabItem { Label("Reports", systemImage: "chart.bar.doc.horizontal") }
        }
    }
}

// MARK: - Navigation

extension View {
    /// Lets any list open a bill or a legislator.
    func appDestinations() -> some View {
        self
            .navigationDestination(for: Bill.self) { BillDetailView(bill: $0) }
            .navigationDestination(for: Person.self) { LegislatorView(person: $0) }
    }
}

// MARK: - Filters

struct BillFilter: Equatable {
    var type = "All"      // All, House bill, Senate bill, Resolution
    var status = "All"    // All or a status group

    var isActive: Bool { self != BillFilter() }

    func apply(_ bills: [Bill]) -> [Bill] {
        bills.filter {
            (type == "All" || $0.billType == type) && (status == "All" || $0.statusGroup == status)
        }
    }
}

/// One filter button in the top corner, so the screen stays clean.
struct FilterMenu: View {
    @Binding var filter: BillFilter

    var body: some View {
        Menu {
            Picker("Type", selection: $filter.type) {
                Text("All types").tag("All")
                ForEach(["House bill", "Senate bill", "Resolution"], id: \.self) { Text($0 + "s").tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Status", selection: $filter.status) {
                Text("Any status").tag("All")
                ForEach(Bill.statusGroupOrder, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Button("Clear filters", role: .destructive) { filter = BillFilter() }
            }
        } label: {
            Label("Filter", systemImage: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }
}

// MARK: - Bill lists

/// High priority bills, then housing bills, with indirect and other bills tucked in closed dropdowns.
struct BillSections: View {
    @EnvironmentObject var workspace: Workspace
    let bills: [Bill]
    @State private var showIndirect = false
    @State private var showOther = false

    var body: some View {
        let priority = bills.filter { workspace.isPriority($0) }
        let rest = bills.filter { !workspace.isPriority($0) }
        let direct = rest.filter { $0.relevance == "Direct" }
        let indirect = rest.filter(\.isIndirect)
        let other = rest.filter { !$0.isHousing }

        if !priority.isEmpty {
            Section("🚩 High priority") {
                ForEach(priority) { bill in NavigationLink(value: bill) { BillRow(bill: bill) } }
            }
        }
        if !direct.isEmpty {
            Section("Housing") {
                ForEach(direct) { bill in NavigationLink(value: bill) { BillRow(bill: bill) } }
            }
        }
        if !indirect.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showIndirect) {
                    ForEach(indirect) { bill in NavigationLink(value: bill) { BillRow(bill: bill) } }
                } label: {
                    DropdownLabel(title: "Indirectly related", count: indirect.count,
                                  caption: "Bills that touch housing but aren't mainly about it")
                }
            }
        }
        if !other.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showOther) {
                    ForEach(other) { bill in NavigationLink(value: bill) { BillRow(bill: bill) } }
                } label: {
                    DropdownLabel(title: "Other bills", count: other.count, caption: "Not about housing")
                }
            }
        }
    }
}

struct DropdownLabel: View {
    let title: String
    let count: Int
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) (\(count))").font(.headline)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BillRow: View {
    @EnvironmentObject var workspace: Workspace
    let bill: Bill

    var body: some View {
        let work = workspace.work(bill)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(bill.displayNumber)
                if work.priority { Image(systemName: "flag.fill").foregroundStyle(.red) }
                if !work.note.isEmpty { Image(systemName: "note.text") }
                if workspace.needsReview(bill) {
                    Text("New version").foregroundStyle(.orange)
                }
                Spacer()
                if let position = work.position {
                    PositionTag(position: position, approved: work.positionApproved)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                OutcomeDot(bill: bill)
                Text(bill.displayHeadline).font(.body).lineLimit(3)
            }
            HStack(spacing: 6) {
                Text(bill.status)
                if let date = bill.lastActionDate {
                    Text("·")
                    Text(DateText.pretty(date))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct PositionTag: View {
    let position: Position
    var approved = true

    var color: Color {
        switch position {
        case .support: return .green
        case .oppose: return .red
        case .monitor: return .blue
        case .neutral: return .gray
        }
    }

    var body: some View {
        Text(approved ? position.rawValue : "\(position.rawValue)?")
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Green dot when a bill passed, red when it failed or was vetoed.
struct OutcomeDot: View {
    let bill: Bill

    var body: some View {
        if let passed = bill.outcome {
            Circle()
                .fill(passed ? Color.green : Color.red)
                .frame(width: 9, height: 9)
                .accessibilityLabel(passed ? "Passed" : "Failed")
        }
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15), in: Capsule())
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

/// Folder check marks for one bill, used in menus.
struct FolderButtons: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    let bill: Bill

    var body: some View {
        if workspace.data.folders.isEmpty {
            Text("No folders yet")
        }
        ForEach(workspace.data.folders) { folder in
            Button {
                if workspace.toggle(bill, in: folder) { store.star(bill) }
            } label: {
                if workspace.isBill(bill, in: folder) {
                    Label(folder.name, systemImage: "checkmark")
                } else {
                    Text(folder.name)
                }
            }
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

// MARK: - Inbox

/// Alerts for starred bills, newest first.
struct InboxView: View {
    @EnvironmentObject var store: BillStore

    var body: some View {
        List(store.inbox) { item in
            if let bill = store.bill(id: item.billId) {
                NavigationLink(value: bill) { InboxRow(item: item) }
            } else {
                InboxRow(item: item)
            }
        }
        .overlay { EmptyMessage(text: store.inbox.isEmpty ? "Alerts for your starred bills show up here." : nil) }
        .navigationTitle("Inbox")
        .toolbar {
            if !store.inbox.isEmpty {
                Button("Clear", role: .destructive) { store.inbox = [] }
            }
        }
        .onDisappear { store.markAllRead() }
    }
}

struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !item.read {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                }
                Text(item.title).font(.subheadline.weight(item.read ? .regular : .semibold))
                Spacer()
                Text(item.date, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
