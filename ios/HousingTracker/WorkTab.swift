import SwiftUI

/// Your workspace: starred bills, plus tasks, positions, meetings, journal and floor notes.
struct WorkTab: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @State private var groupBy = "Year"
    @State private var query = ""
    @State private var open: Set<String> = []
    @State private var askingNewFolder = false
    @State private var renaming: Folder?
    @State private var nameText = ""

    private var watched: [Bill] { store.search(query, in: store.watching, notes: workspace.notes) }
    private var priority: [Bill] { watched.filter { workspace.isPriority($0) } }
    private var needsReview: [Bill] { store.watching.filter { workspace.needsReview($0) } }
    private var awaitingApproval: Int {
        workspace.data.bills.values.filter { $0.position != nil && !$0.positionApproved }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        NavigationLink { ActionQueueView() } label: {
                            CountRow(title: "Action queue", icon: "checklist", count: workspace.openTasks.count)
                        }
                        NavigationLink { PositionsView() } label: {
                            CountRow(title: "Positions", icon: "hand.raised",
                                     count: workspace.data.bills.values.filter { $0.position != nil }.count,
                                     note: awaitingApproval > 0 ? "\(awaitingApproval) to approve" : nil)
                        }
                        NavigationLink { MeetingsLogView() } label: {
                            CountRow(title: "Meetings log", icon: "person.2", count: workspace.data.meetings.count)
                        }
                        NavigationLink { FloorNotesView() } label: {
                            CountRow(title: "Floor session notes", icon: "square.and.pencil", count: workspace.data.floorNotes.count)
                        }
                        NavigationLink { JournalView() } label: {
                            CountRow(title: "Activity journal", icon: "book", count: workspace.data.journal.count)
                        }
                    }
                    if !needsReview.isEmpty {
                        Section("New versions to review") {
                            ForEach(needsReview) { bill in NavigationLink(value: bill) { BillRow(bill: bill) } }
                        }
                    }
                }

                if !store.watching.isEmpty {
                    Section {
                        Picker("Group by", selection: $groupBy) {
                            Text("By year").tag("Year")
                            Text("By status").tag("Status")
                            Text("By folder").tag("Folder")
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } header: { Text("Watching (\(store.watching.count))") }
                }

                if !priority.isEmpty {
                    Section("🚩 High priority") {
                        ForEach(priority) { bill in watchedRow(bill) }
                    }
                }

                switch groupBy {
                case "Status":
                    ForEach(Bill.statusGroupOrder, id: \.self) { group in
                        let list = watched.filter { $0.statusGroup == group }
                        if !list.isEmpty {
                            Section { dropdown(key: "s-\(group)", title: group, bills: list) }
                        }
                    }
                case "Folder":
                    ForEach(workspace.data.folders) { folder in
                        Section {
                            dropdown(key: folder.id.uuidString, title: folder.name,
                                     bills: watched.filter { folder.billIds.contains($0.id) }, folder: folder)
                        }
                    }
                    let filed = Set(workspace.data.folders.flatMap(\.billIds))
                    let loose = watched.filter { !filed.contains($0.id) }
                    if !loose.isEmpty {
                        Section {
                            dropdown(key: "none", title: "Not in a folder", bills: loose)
                        } footer: {
                            Text("Press and hold a bill to put it in a folder. Press and hold a folder to rename or delete it.")
                        }
                    }
                default:
                    let years = Array(Set(watched.map(\.year))).sorted(by: >)
                    ForEach(years, id: \.self) { year in
                        Section { dropdown(key: "y-\(year)", title: year, bills: watched.filter { $0.year == year }) }
                    }
                }
            }
            .overlay {
                EmptyMessage(text: store.watching.isEmpty && query.isEmpty
                             ? "Tap Watch on any bill to follow it. You'll get an alert every time it moves."
                             : (!query.isEmpty && watched.isEmpty ? "No starred bills match." : nil))
            }
            .searchable(text: $query, prompt: "Search your bills")
            .onChange(of: query) { _, q in
                // Open every dropdown while searching, so matches are visible.
                if !q.isEmpty { open = allKeys }
            }
            .navigationTitle("My Work")
            .task {
                // Watch for new versions on every starred bill.
                for bill in store.watching where workspace.work(bill).reviewedVersions == 0 && !bill.versions.isEmpty {
                    workspace.startAmendmentWatch(bill)
                }
            }
            .toolbar {
                Button { nameText = ""; askingNewFolder = true } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
            }
            .alert("New folder", isPresented: $askingNewFolder) {
                TextField("Name, like Property tax", text: $nameText)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    workspace.addFolder(nameText)
                    groupBy = "Folder"
                }
            }
            .alert("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $nameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let f = renaming { workspace.renameFolder(f, to: nameText) } }
            }
            .appDestinations()
            .refreshable { await store.refresh() }
        }
    }

    private var allKeys: Set<String> {
        var keys: Set<String> = ["none"]
        for group in Bill.statusGroupOrder { keys.insert("s-\(group)") }
        for folder in workspace.data.folders { keys.insert(folder.id.uuidString) }
        for bill in store.watching { keys.insert("y-\(bill.year)") }
        return keys
    }

    private func watchedRow(_ bill: Bill) -> some View {
        NavigationLink(value: bill) { BillRow(bill: bill) }
            .contextMenu { FolderButtons(bill: bill) }
            .swipeActions {
                Button("Unwatch", role: .destructive) { store.toggleStar(bill) }
            }
    }

    private func dropdown(key: String, title: String, bills: [Bill], folder: Folder? = nil) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { open.contains(key) },
            set: { if $0 { open.insert(key) } else { open.remove(key) } }
        )) {
            ForEach(bills) { bill in watchedRow(bill) }
        } label: {
            Text("\(title) (\(bills.count))").font(.headline)
                .contextMenu {
                    if let folder {
                        Button("Rename", systemImage: "pencil") { nameText = folder.name; renaming = folder }
                        Button("Delete folder", systemImage: "trash", role: .destructive) { workspace.deleteFolder(folder) }
                    }
                }
        }
    }
}

struct CountRow: View {
    let title: String
    let icon: String
    let count: Int
    var note: String? = nil

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            Text("\(count)").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Action queue

struct ActionQueueView: View {
    @EnvironmentObject var workspace: Workspace
    @State private var showNew = false
    @State private var showDone = false

    var body: some View {
        List {
            Section {
                ForEach(workspace.openTasks) { task in TaskRow(task: task, showBill: true) }
            }
            let done = workspace.data.tasks.filter(\.done)
            if !done.isEmpty {
                Section {
                    DisclosureGroup("Done (\(done.count))", isExpanded: $showDone) {
                        ForEach(done) { task in TaskRow(task: task, showBill: true) }
                    }
                }
            }
        }
        .overlay { EmptyMessage(text: workspace.data.tasks.isEmpty ? "No tasks yet. Add one here or from any bill." : nil) }
        .navigationTitle("Action queue")
        .toolbar { Button { showNew = true } label: { Label("New task", systemImage: "plus") } }
        .sheet(isPresented: $showNew) { TaskEditor(bill: nil) }
    }
}

// MARK: - Positions

struct PositionedBill: Identifiable {
    let bill: Bill
    let work: BillWork
    var id: String { bill.id }
}

struct PositionsView: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace

    private var withPosition: [PositionedBill] {
        var list: [PositionedBill] = []
        for (id, work) in workspace.data.bills where work.position != nil {
            if let bill = store.bill(id: id) { list.append(PositionedBill(bill: bill, work: work)) }
        }
        return list.sorted { $0.bill.numberOrder < $1.bill.numberOrder }
    }

    var body: some View {
        List {
            let proposed = withPosition.filter { !$0.work.positionApproved }
            if !proposed.isEmpty {
                Section {
                    ForEach(proposed) { item in
                        NavigationLink(value: item.bill) { BillRow(bill: item.bill) }
                            .swipeActions {
                                Button("Approve") { workspace.approvePosition(item.bill) }.tint(.green)
                            }
                    }
                } header: { Text("Waiting for approval") } footer: { Text("Swipe left to approve.") }
            }
            ForEach(Position.allCases, id: \.self) { p in
                let list = withPosition.filter { $0.work.position == p && $0.work.positionApproved }
                if !list.isEmpty {
                    Section("\(p.rawValue) (\(list.count))") {
                        ForEach(list) { item in NavigationLink(value: item.bill) { BillRow(bill: item.bill) } }
                    }
                }
            }
        }
        .overlay { EmptyMessage(text: withPosition.isEmpty ? "Set a position from the Position button on any bill." : nil) }
        .navigationTitle("Positions")
    }
}

// MARK: - Meetings, journal, floor notes

struct MeetingsLogView: View {
    @EnvironmentObject var workspace: Workspace
    @State private var showNew = false

    var body: some View {
        List {
            ForEach(workspace.data.meetings) { m in MeetingRow(meeting: m) }
                .onDelete { idx in workspace.data.meetings.remove(atOffsets: idx) }
        }
        .overlay { EmptyMessage(text: workspace.data.meetings.isEmpty ? "Log meetings with legislators, committee staff and agencies." : nil) }
        .navigationTitle("Meetings log")
        .toolbar { Button { showNew = true } label: { Label("Log a meeting", systemImage: "plus") } }
        .sheet(isPresented: $showNew) { MeetingEditor() }
    }
}

struct JournalView: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @State private var newEntry = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add an entry", text: $newEntry, axis: .vertical)
                    Button("Add") {
                        let text = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        let bill = BillNumbers.find(in: text).first.flatMap { n in store.bills.first { $0.searchNumber == n } }
                        workspace.log(text, bill: bill)
                        newEntry = ""
                    }
                    .buttonStyle(.borderless)
                }
            } footer: { Text("Positions, tasks, meetings and reviews are added here automatically.") }
            ForEach(workspace.data.journal) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        if let bill = store.bill(id: entry.billId) { Text("· \(bill.displayNumber)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(entry.text).font(.subheadline)
                }
            }
        }
        .navigationTitle("Activity journal")
    }
}

/// Fast, timestamped notes during a House or Senate session. Bill numbers in a note link to the bill.
struct FloorNotesView: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @State private var chamber = "House"
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        List {
            Section {
                Picker("Chamber", selection: $chamber) {
                    Text("House").tag("House")
                    Text("Senate").tag("Senate")
                }
                .pickerStyle(.segmented)
                HStack(alignment: .bottom) {
                    TextField("What just happened? Type HB 123 to link a bill.", text: $text, axis: .vertical)
                        .focused($typing)
                        .lineLimit(1...6)
                    Button {
                        workspace.addFloorNote(text, chamber: chamber)
                        text = ""
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(workspace.data.floorNotes) { note in
                let linked = BillNumbers.find(in: note.text).compactMap { n in store.bills.first { $0.searchNumber == n } }
                if let first = linked.first {
                    NavigationLink(value: first) { FloorNoteRow(note: note, linked: linked) }
                } else {
                    FloorNoteRow(note: note, linked: [])
                }
            }
            .onDelete { idx in workspace.data.floorNotes.remove(atOffsets: idx) }
        }
        .navigationTitle("Floor notes")
        .onAppear { typing = true }
    }
}

struct FloorNoteRow: View {
    let note: FloorNote
    let linked: [Bill]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(note.chamber) · \(note.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Text(note.text).font(.subheadline)
            if !linked.isEmpty {
                Text(linked.map { "\($0.displayNumber): \($0.displayHeadline)" }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}
