import Foundation
import SwiftUI

/// Everything you record: positions, priorities, notes, folders, tasks, meetings, journal,
/// floor notes, deadlines and report presets. Saved in a file on the phone.
struct WorkspaceData: Codable {
    var bills: [String: BillWork] = [:]
    var folders: [Folder] = []
    var tasks: [TaskItem] = []
    var meetings: [Meeting] = []
    var journal: [JournalEntry] = []
    var floorNotes: [FloorNote] = []
    var deadlines: [Deadline] = []
    var reports: [ReportPreset] = []
    var orgName = ""

    init() {}

    // Read each part on its own, so a newer or older file never fails to load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bills = (try? c.decode([String: BillWork].self, forKey: .bills)) ?? [:]
        folders = (try? c.decode([Folder].self, forKey: .folders)) ?? []
        tasks = (try? c.decode([TaskItem].self, forKey: .tasks)) ?? []
        meetings = (try? c.decode([Meeting].self, forKey: .meetings)) ?? []
        journal = (try? c.decode([JournalEntry].self, forKey: .journal)) ?? []
        floorNotes = (try? c.decode([FloorNote].self, forKey: .floorNotes)) ?? []
        deadlines = (try? c.decode([Deadline].self, forKey: .deadlines)) ?? []
        reports = (try? c.decode([ReportPreset].self, forKey: .reports)) ?? []
        orgName = (try? c.decode(String.self, forKey: .orgName)) ?? ""
    }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var data: WorkspaceData {
        didSet { save() }
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspace.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode(WorkspaceData.self, from: d) {
            data = saved
        } else {
            var fresh = WorkspaceData()
            // Bring over folders from the earlier version of the app.
            if let d = UserDefaults.standard.data(forKey: "folders"), let old = try? JSONDecoder().decode([Folder].self, from: d) {
                fresh.folders = old
            }
            fresh.reports = [ReportPreset(name: "Weekly update", source: "Starred"),
                             ReportPreset(name: "High priority bills", source: "High priority",
                                          fields: ["Status", "Latest action", "Position", "Next hearing", "Talking points"])]
            data = fresh
            save()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(data) {
            try? d.write(to: Self.fileURL, options: .atomic)
        }
        // Alerts run outside the app's screens, so they read high priority bills from here.
        let ids = data.bills.filter { $0.value.priority }.map(\.key)
        UserDefaults.standard.set(ids, forKey: "priorityIds")
    }

    // MARK: Bill work

    func work(_ bill: Bill) -> BillWork { data.bills[bill.id] ?? BillWork() }

    func update(_ bill: Bill, _ change: (inout BillWork) -> Void) {
        var w = work(bill)
        change(&w)
        data.bills[bill.id] = w
    }

    /// A two-way link for a text field on a bill.
    func binding(_ bill: Bill, _ path: WritableKeyPath<BillWork, String>) -> Binding<String> {
        Binding(get: { self.work(bill)[keyPath: path] },
                set: { value in self.update(bill) { $0[keyPath: path] = value } })
    }

    func isPriority(_ bill: Bill) -> Bool { work(bill).priority }

    func setPriority(_ bill: Bill, _ on: Bool) {
        update(bill) { $0.priority = on }
        log(on ? "Marked high priority" : "Removed high priority", bill: bill)
    }

    func setPosition(_ bill: Bill, _ position: Position?, approved: Bool) {
        update(bill) {
            $0.position = position
            $0.positionApproved = approved
        }
        if let position {
            log("Position \(approved ? "set" : "proposed"): \(position.rawValue)", bill: bill)
        } else {
            log("Position cleared", bill: bill)
        }
    }

    func approvePosition(_ bill: Bill) {
        update(bill) { $0.positionApproved = true }
        log("Position approved: \(work(bill).position?.rawValue ?? "")", bill: bill)
    }

    /// True when a version came out that you haven't marked reviewed.
    func needsReview(_ bill: Bill) -> Bool {
        let w = data.bills[bill.id]
        return w != nil && bill.versions.count > (w?.reviewedVersions ?? 0) && (w?.reviewedVersions ?? 0) > 0
    }

    func markReviewed(_ bill: Bill) {
        update(bill) { $0.reviewedVersions = bill.versions.count }
        log("Reviewed \(bill.versions.last?.name ?? "latest version")", bill: bill)
    }

    /// Start watching versions from now on, so only newer ones ask for review.
    func startAmendmentWatch(_ bill: Bill) {
        update(bill) { if $0.reviewedVersions == 0 { $0.reviewedVersions = bill.versions.count } }
    }

    var priorityIds: Set<String> { Set(data.bills.filter { $0.value.priority }.map(\.key)) }

    var notes: [String: String] { data.bills.compactMapValues { $0.note.isEmpty ? nil : $0.note } }

    // MARK: Journal

    func log(_ text: String, bill: Bill? = nil) {
        data.journal.insert(JournalEntry(billId: bill?.id, text: text), at: 0)
    }

    func journal(for bill: Bill) -> [JournalEntry] { data.journal.filter { $0.billId == bill.id } }

    // MARK: Tasks

    func addTask(_ task: TaskItem, bill: Bill?) {
        data.tasks.insert(task, at: 0)
        log("Task added: \(task.title)\(task.owner.isEmpty ? "" : " (\(task.owner))")", bill: bill)
    }

    func toggleTask(_ task: TaskItem, bill: Bill?) {
        guard let i = data.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        data.tasks[i].done.toggle()
        if data.tasks[i].done { log("Task done: \(task.title)", bill: bill) }
    }

    func deleteTask(_ task: TaskItem) {
        data.tasks.removeAll { $0.id == task.id }
    }

    var openTasks: [TaskItem] {
        data.tasks.filter { !$0.done }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    func tasks(for bill: Bill) -> [TaskItem] { data.tasks.filter { $0.billId == bill.id } }

    // MARK: Meetings

    func addMeeting(_ meeting: Meeting, bills: [Bill]) {
        data.meetings.insert(meeting, at: 0)
        let who = meeting.personName.isEmpty ? meeting.role : meeting.personName
        if bills.isEmpty {
            log("Met with \(who)")
        }
        for bill in bills { log("Met with \(who)", bill: bill) }
    }

    func deleteMeeting(_ meeting: Meeting) {
        data.meetings.removeAll { $0.id == meeting.id }
    }

    func meetings(for bill: Bill) -> [Meeting] { data.meetings.filter { $0.billIds.contains(bill.id) } }

    func meetings(with person: Person) -> [Meeting] {
        data.meetings.filter { $0.personId == person.id || (!$0.personName.isEmpty && $0.personName == person.displayName) }
    }

    // MARK: Folders

    @discardableResult
    func addFolder(_ name: String) -> Folder? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let folder = Folder(name: name)
        data.folders.append(folder)
        data.folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = data.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        data.folders[i].name = name
    }

    func deleteFolder(_ folder: Folder) {
        data.folders.removeAll { $0.id == folder.id }
    }

    func isBill(_ bill: Bill, in folder: Folder) -> Bool {
        data.folders.first { $0.id == folder.id }?.billIds.contains(bill.id) ?? false
    }

    /// Adds or removes a bill from a folder. Returns true if it was added.
    @discardableResult
    func toggle(_ bill: Bill, in folder: Folder) -> Bool {
        guard let i = data.folders.firstIndex(where: { $0.id == folder.id }) else { return false }
        if data.folders[i].billIds.contains(bill.id) {
            data.folders[i].billIds.removeAll { $0 == bill.id }
            return false
        }
        data.folders[i].billIds.append(bill.id)
        return true
    }

    // MARK: Floor notes and deadlines

    func addFloorNote(_ text: String, chamber: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        data.floorNotes.insert(FloorNote(chamber: chamber, text: text), at: 0)
    }

    var upcomingDeadlines: [Deadline] {
        let today = Calendar.current.startOfDay(for: Date())
        return data.deadlines.filter { $0.date >= today }.sorted { $0.date < $1.date }
    }
}

/// Finds bill numbers like "HB 31" or "SB12" in typed text, for linking floor notes to bills.
enum BillNumbers {
    static func find(in text: String) -> [String] {
        let pattern = #"\b(HB|SB|HR|SR)\s*(\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)) + ns.substring(with: $0.range(at: 2))).lowercased()
        }
    }
}
