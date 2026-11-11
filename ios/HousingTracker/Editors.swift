import EventKit
import EventKitUI
import SwiftUI
import UIKit

// MARK: - Tasks

struct TaskEditor: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    let bill: Bill?
    @State private var title = ""
    @State private var owner = ""
    @State private var hasDue = false
    @State private var due = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs to happen", text: $title, axis: .vertical)
                    Menu("Pick a common task") {
                        ForEach(TaskItem.templates, id: \.self) { t in Button(t) { title = t } }
                    }
                }
                Section {
                    TextField("Who owns it", text: $owner)
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue { DatePicker("Due", selection: $due, displayedComponents: [.date]) }
                }
                if let bill { Section { Text("For \(bill.displayNumber)").foregroundStyle(.secondary) } }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        workspace.addTask(TaskItem(title: title, billId: bill?.id, owner: owner, due: hasDue ? due : nil), bill: bill)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    let task: TaskItem
    var showBill = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { workspace.toggleTask(task, bill: store.bill(id: task.billId)) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(task.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).strikethrough(task.done).foregroundStyle(task.done ? Color.secondary : Color.primary)
                let details = [
                    showBill ? store.bill(id: task.billId)?.displayNumber : nil,
                    task.owner.isEmpty ? nil : task.owner,
                    task.due.map { "Due \($0.formatted(date: .abbreviated, time: .omitted))" },
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption)
                        .foregroundStyle(isOverdue ? Color.red : Color.secondary)
                }
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { workspace.deleteTask(task) }
        }
    }

    private var isOverdue: Bool {
        guard let due = task.due, !task.done else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }
}

// MARK: - Stakeholders and related bills

struct StakeholderEditor: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    let bill: Bill
    @State private var item = Stakeholder(name: "")

    var body: some View {
        NavigationStack {
            Form {
                TextField("Organization", text: $item.name)
                Picker("Stance", selection: $item.stance) {
                    ForEach(Stakeholder.stances, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Public, confirmed position", isOn: $item.confirmed)
                TextField("Note", text: $item.note, axis: .vertical)
            }
            .navigationTitle("Who supports or opposes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        workspace.update(bill) { $0.stakeholders.append(item) }
                        workspace.log("\(item.name): \(item.stance)\(item.confirmed ? "" : " (heard)")", bill: bill)
                        dismiss()
                    }
                    .disabled(item.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct RelatedPicker: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    let bill: Bill
    @State private var query = ""
    @State private var kind = "Similar"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("How they're related", selection: $kind) {
                        ForEach(RelatedBill.kinds, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section(query.isEmpty ? "Type a bill number or keywords" : "Tap a bill to link it") {
                    if !query.isEmpty {
                        ForEach(store.search(query).filter { $0.id != bill.id }.prefix(40)) { other in
                            Button {
                                workspace.update(bill) { $0.related.append(RelatedBill(billId: other.id, kind: kind)) }
                                // Link both ways, so each bill shows the other.
                                workspace.update(other) { $0.related.append(RelatedBill(billId: bill.id, kind: kind)) }
                                workspace.log("Linked \(other.displayNumber) (\(kind.lowercased()))", bill: bill)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(other.displayNumber).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(other.displayHeadline).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Bill number or keywords")
            .navigationTitle("Link a related bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Meetings

struct MeetingEditor: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var meeting = Meeting()
    @State private var billIds: [String]
    @State private var followUp = ""
    @State private var personQuery = ""
    @State private var billQuery = ""

    init(bills: [Bill] = [], person: Person? = nil) {
        var m = Meeting()
        if let person {
            m.personName = person.displayName
            m.personId = person.id
        }
        _meeting = State(initialValue: m)
        _billIds = State(initialValue: bills.map(\.id))
    }

    private var personMatches: [Person] {
        let q = personQuery.lowercased()
        guard !q.isEmpty else { return [] }
        return Array(store.people.filter { $0.displayName.lowercased().contains(q) }.prefix(6))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Who") {
                    Picker("Role", selection: $meeting.role) {
                        ForEach(Meeting.roles, id: \.self) { Text($0).tag($0) }
                    }
                    if meeting.personName.isEmpty || meeting.role != "Legislator" {
                        TextField(meeting.role == "Legislator" ? "Search legislators" : "Name", text: meeting.role == "Legislator" ? $personQuery : $meeting.personName)
                        ForEach(personMatches) { p in
                            Button("\(p.title) \(p.displayName) · \(p.line)") {
                                meeting.personName = p.displayName
                                meeting.personId = p.id
                                personQuery = ""
                            }
                        }
                    } else {
                        HStack {
                            Text(meeting.personName)
                            Spacer()
                            Button("Change") { meeting.personName = ""; meeting.personId = nil }.buttonStyle(.borderless)
                        }
                    }
                    DatePicker("When", selection: $meeting.date)
                }
                Section("Notes") {
                    TextField("What was discussed, what they said", text: $meeting.notes, axis: .vertical)
                        .lineLimit(4...15)
                    TextField("Follow-up task (optional)", text: $followUp)
                }
                Section("Bills discussed") {
                    ForEach(billIds, id: \.self) { id in
                        Text(store.bill(id: id).map { "\($0.displayNumber): \($0.displayHeadline)" } ?? id).lineLimit(1)
                    }
                    .onDelete { billIds.remove(atOffsets: $0) }
                    TextField("Add a bill (number or keywords)", text: $billQuery)
                    if !billQuery.isEmpty {
                        ForEach(store.search(billQuery).prefix(5)) { b in
                            Button("\(b.displayNumber): \(b.displayHeadline)") {
                                if !billIds.contains(b.id) { billIds.append(b.id) }
                                billQuery = ""
                            }
                            .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Log a meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if meeting.personName.isEmpty && !personQuery.isEmpty { meeting.personName = personQuery }
                        meeting.billIds = billIds
                        let bills = billIds.compactMap { store.bill(id: $0) }
                        workspace.addMeeting(meeting, bills: bills)
                        let task = followUp.trimmingCharacters(in: .whitespaces)
                        if !task.isEmpty {
                            workspace.addTask(TaskItem(title: task, billId: billIds.first), bill: bills.first)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var store: BillStore
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(meeting.personName.isEmpty ? meeting.role : meeting.personName).font(.subheadline.weight(.semibold))
                Spacer()
                Text(meeting.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            if !meeting.notes.isEmpty { Text(meeting.notes).font(.caption).lineLimit(3) }
            let numbers = meeting.billIds.compactMap { store.bill(id: $0)?.displayNumber }
            if !numbers.isEmpty {
                Text(numbers.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Deadlines

struct DeadlineEditor: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("What's due, like Position statement to committee", text: $title, axis: .vertical)
                DatePicker("Date", selection: $date, displayedComponents: [.date])
            }
            .navigationTitle("New deadline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        workspace.data.deadlines.append(Deadline(title: title, date: date))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Member action

/// Talking points and a ready-to-send email members can personalize.
struct MemberActionView: View {
    @EnvironmentObject var workspace: Workspace
    let bill: Bill
    @State private var copied = false

    private var subject: String {
        let w = workspace.work(bill)
        return w.emailSubject.isEmpty ? "Please \(w.position == .oppose ? "oppose" : "support") \(bill.displayNumber)" : w.emailSubject
    }

    private var bodyText: String {
        let w = workspace.work(bill)
        if !w.emailBody.isEmpty { return w.emailBody }
        var text = "Dear [Legislator],\n\nAs your constituent and a Georgia real estate professional, I ask you to \(w.position == .oppose ? "oppose" : "support") \(bill.displayNumber), \(bill.displayHeadline).\n\n"
        if !w.talkingPoints.isEmpty { text += w.talkingPoints + "\n\n" }
        text += "Thank you for your time.\n\n[Your name]\n[Your city]"
        return text
    }

    var body: some View {
        Form {
            Section("Subject") {
                TextField("Subject", text: Binding(get: { subject }, set: { v in workspace.update(bill) { $0.emailSubject = v } }))
            }
            Section("Email") {
                TextField("Email", text: Binding(get: { bodyText }, set: { v in workspace.update(bill) { $0.emailBody = v } }), axis: .vertical)
                    .lineLimit(8...30)
            }
            Section {
                Button(copied ? "Copied" : "Copy email", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = "\(subject)\n\n\(bodyText)"
                    copied = true
                }
                if let url = mailURL {
                    Link(destination: url) { Label("Open in Mail", systemImage: "envelope") }
                }
                ShareLink(item: "\(subject)\n\n\(bodyText)") { Label("Share with members", systemImage: "square.and.arrow.up") }
            } footer: {
                Text("Edit the text, then share it with members so they can send it to their own legislators.")
            }
        }
        .navigationTitle("Member action")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var mailURL: URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: bodyText)]
        return parts.url
    }
}

// MARK: - Calendar and sharing

/// Apple's own "add event" screen, filled in. Needs no calendar permission.
struct CalendarEventSheet: UIViewControllerRepresentable {
    let title: String
    let date: Date?
    let notes: String?
    @Environment(\.dismiss) private var dismiss

    init(title: String, date: Date?, notes: String? = nil) {
        self.title = title
        self.date = date
        self.notes = notes
    }

    init(bill: Bill, event: Upcoming) {
        title = "\(bill.displayNumber): \(event.what ?? "Hearing")"
        date = CalendarEventSheet.combine(event.date, event.time)
        notes = [bill.displayHeadline, event.`where`].compactMap { $0 }.joined(separator: "\n")
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        let start = date ?? Date()
        event.startDate = start
        event.endDate = start.addingTimeInterval(60 * 60)
        event.notes = notes
        let vc = EKEventEditViewController()
        vc.eventStore = store
        vc.event = event
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }

    /// "2027-01-15" + "1:00 PM" -> a date. Falls back to 9 AM.
    static func combine(_ day: String?, _ time: String?) -> Date? {
        guard let d = DateText.date(day) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["h:mm a", "h:mma", "HH:mm", "HH:mm:ss"] {
            f.dateFormat = format
            if let time, let t = f.date(from: time.uppercased()) {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: t)
                return Calendar.current.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: d)
            }
        }
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
