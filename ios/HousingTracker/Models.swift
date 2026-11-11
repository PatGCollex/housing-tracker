import Foundation

// MARK: - Data from the update job (read-only)

struct BillFeed: Codable {
    let generatedAt: String?
    let bills: [Bill]
}

struct WeeklyRecap: Codable {
    let generatedAt: String
    let weekOf: String
    let summary: String
    let billIds: [String]
}

struct Bill: Codable, Identifiable, Hashable {
    let id: String
    let jurisdiction: String
    let number: String
    let title: String
    let session: String?
    let sponsor: String?
    let sponsors: [Sponsor]?
    let committee: String?
    let status: String
    let lastAction: String?
    let lastActionDate: String?
    let introduced: String?
    let timeline: [TimelineItem]
    let versions: [BillVersion]
    let votes: [VoteSummary]?
    let upcoming: [Upcoming]
    let link: String?
    let recap: String?
    let relevance: String?            // "Direct", "Indirect", or nil when it isn't about housing
    let whyHousing: String?
    let changeKind: String?
    let updatedAt: String?

    var displayHeadline: String { title }
    var isGeorgia: Bool { jurisdiction == "Georgia" }
    var isHousing: Bool { relevance != nil }
    var isIndirect: Bool { relevance == "Indirect" }
    var isLaw: Bool { status == "Signed into law" }
    var url: URL? { link.flatMap(URL.init(string:)) }
    var allSponsors: [Sponsor] { sponsors ?? [] }
    var allVotes: [VoteSummary] { votes ?? [] }

    /// "HB 31" from "HB31".
    var displayNumber: String {
        let letters = number.prefix { $0.isLetter }
        let rest = number.dropFirst(letters.count)
        return rest.isEmpty ? number : "\(letters) \(rest)"
    }

    /// "hb31", for matching searches like "HB 31", "H.B. 31" or "hb31".
    var searchNumber: String { number.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Date used to put the most recent bills first.
    var sortDate: String { lastActionDate ?? updatedAt ?? "" }

    /// Year the bill was filed.
    var year: String {
        String((introduced ?? timeline.first?.date ?? lastActionDate ?? updatedAt ?? "").prefix(4))
    }

    /// "House bill", "Senate bill" or "Resolution".
    var billType: String {
        let letters = number.uppercased().filter { $0.isLetter }
        return letters == "HB" ? "House bill" : letters == "SB" ? "Senate bill" : "Resolution"
    }

    /// HB first, then SB, then resolutions, each in number order.
    var numberOrder: (Int, Int) {
        let letters = number.uppercased().filter { $0.isLetter }
        let typeRank = ["HB": 0, "SB": 1, "HR": 2, "SR": 3][letters] ?? 4
        return (typeRank, Int(number.filter { $0.isNumber }) ?? 0)
    }

    /// Green when the bill passed a step, red when it failed or was vetoed, nil otherwise.
    var outcome: Bool? {
        switch status {
        case "Vetoed", "Failed": return false
        case "Introduced", "In committee": return nil
        default: return true
        }
    }

    /// Words for an alert, like "HB 31 passed both chambers".
    var stageVerb: String {
        switch status {
        case "Passed one chamber": return "passed its first chamber"
        case "Passed both chambers": return "passed both chambers"
        case "Signed into law": return "was signed into law"
        case "Vetoed": return "was vetoed"
        case "Failed": return "failed"
        default: return "is now: \(status.lowercased())"
        }
    }

    /// Simple status groups for filters and the Watching "By status" view, in cycle order.
    var statusGroup: String {
        switch status {
        case "Signed into law": return "Became law"
        case "Passed both chambers": return "Passed both chambers"
        case "Passed one chamber": return "Passed one chamber"
        case "Vetoed", "Failed": return "Vetoed or failed"
        default: return "In committee"
        }
    }
    static let statusGroupOrder = ["Became law", "Passed both chambers", "Passed one chamber", "In committee", "Vetoed or failed"]

    /// The fields that, when they change, deserve an alert on a starred bill.
    var alertFingerprint: String {
        "\(status)|\(versions.count)|\(timeline.count)|\(upcoming.first?.date ?? "")"
    }

    /// Where the bill is in the process, for the progress tracker.
    var stage: BillStage { BillStage(bill: self) }
}

struct Sponsor: Codable, Hashable {
    let id: Int?
    let name: String?
    let party: String?
    let chamber: String?
    let district: String?
    let primary: Bool?
}

struct VoteSummary: Codable, Hashable, Identifiable {
    let id: Int?
    let date: String?
    let desc: String?
    let chamber: String?
    let yea: Int?
    let nay: Int?
    let nv: Int?
    let absent: Int?
    let passed: Bool?

    var key: String { id.map(String.init) ?? "" }
}

struct TimelineItem: Codable, Hashable {
    let date: String?
    let text: String?
}

struct BillVersion: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let date: String?
    let url: String?
}

struct Upcoming: Codable, Hashable {
    let date: String?
    let time: String?
    let what: String?
    let `where`: String?
}

extension Upcoming: Identifiable {
    var id: String { "\(date ?? "")|\(time ?? "")|\(what ?? "")" }
}

/// A file to hand to the share sheet.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct Person: Codable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let first: String?
    let last: String?
    let party: String?
    let chamber: String?
    let district: String?
    let ballotpedia: String?

    var displayName: String { name ?? "Unknown" }
    var title: String { chamber == "Senate" ? "Sen." : "Rep." }
    var line: String {
        [chamber, district.map { "District \($0)" }, party].compactMap { $0 }.joined(separator: " · ")
    }
}

struct PeopleFeed: Codable {
    let people: [Person]
}

/// One letter per legislator in people order: Y, N, X (no vote), A (absent), "." (other chamber).
struct VotesFeed: Codable {
    let people: [Int]
    let rolls: [String: String]
}

struct DiffFile: Codable {
    let pairs: [DiffPair]
}

struct DiffPair: Codable, Identifiable {
    let key: String
    let from: String?
    let fromDate: String?
    let to: String?
    let toDate: String?
    let pieces: [[String]]
    let changes: Int

    var id: String { key }
}

struct SessionCalendar: Codable {
    let milestones: [Milestone]
    let days: [SessionDay]
}

struct Milestone: Codable, Hashable {
    let date: String
    let title: String
}

struct SessionDay: Codable, Hashable {
    let date: String
    let kind: String      // "session" or "committee"
    let label: String?
}

// MARK: - Progress tracker

struct BillStage {
    static let steps = ["Filed", "Committee", "Passed 1st chamber", "2nd chamber", "Passed both", "Governor", "Law"]

    /// Index into steps of the furthest step reached.
    let reached: Int
    /// True when the bill was vetoed or failed at that step.
    let stopped: Bool

    init(bill: Bill) {
        let text = bill.timeline.compactMap { $0.text?.lowercased() }
        func any(_ words: [String]) -> Bool { text.contains { t in words.contains { t.contains($0) } } }
        var step = 0
        if any(["committee", "second read", "referred"]) { step = 1 }
        if any(["passed/adopted"]) || ["Passed one chamber", "Passed both chambers", "Signed into law", "Vetoed"].contains(bill.status) { step = 2 }
        let passes = text.filter { $0.contains("passed/adopted") }
        let houseFirst = passes.first.map { $0.hasPrefix("h") } ?? true
        let otherChamberTouched = text.contains { t in
            (houseFirst ? t.hasPrefix("s") : t.hasPrefix("h")) && (t.contains("read and referred") || t.contains("first read"))
        }
        if step >= 2 && otherChamberTouched { step = 3 }
        if ["Passed both chambers", "Signed into law", "Vetoed"].contains(bill.status) { step = 4 }
        if any(["sent to governor"]) { step = 5 }
        if bill.status == "Signed into law" { step = 6 }
        reached = step
        stopped = bill.status == "Vetoed" || bill.status == "Failed"
    }
}

// MARK: - Things you keep (saved on the phone)

/// A folder on Watching, such as "Property tax" or "Rentals".
struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var billIds: [String] = []
}

/// One alert, kept in the in-app inbox (starred bills only).
struct InboxItem: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let title: String
    let body: String
    let billId: String?
    var read = false
}

enum Position: String, Codable, CaseIterable {
    case support = "Support", oppose = "Oppose", monitor = "Monitor", neutral = "Neutral"
}

struct Stakeholder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var stance: String = "Undecided"       // Support, Oppose, Neutral, Undecided
    var confirmed = false                  // true = public position, false = what we've heard
    var note = ""
    static let stances = ["Support", "Oppose", "Neutral", "Undecided"]
}

struct RelatedBill: Codable, Identifiable, Hashable {
    var id = UUID()
    var billId: String
    var kind: String = "Similar"           // Companion, Competing, Similar, Amends same law
    static let kinds = ["Companion", "Competing", "Similar", "Amends same law"]
}

/// Everything you record about one bill.
struct BillWork: Codable, Hashable {
    var priority = false
    var position: Position?
    var positionApproved = false
    var positionReason = ""
    var note = ""
    var assignedTo = ""
    var nextAction = ""
    var talkingPoints = ""
    var questions = ""
    var watchSections = ""                 // sections to check when a new version comes out
    var reviewedVersions = 0               // versions you've marked reviewed
    var emailSubject = ""
    var emailBody = ""
    var stakeholders: [Stakeholder] = []
    var related: [RelatedBill] = []
}

struct TaskItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var billId: String?
    var owner = ""
    var due: Date?
    var done = false
    var created = Date()
    static let templates = ["Contact committee chair", "Review substitute", "Prepare testimony",
                            "Request fiscal note", "Notify members", "Schedule meeting with sponsor"]
}

struct Meeting: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var personName = ""
    var personId: Int?
    var role = "Legislator"                // Legislator, Committee staff, Agency, Other
    var notes = ""
    var billIds: [String] = []
    static let roles = ["Legislator", "Committee staff", "Agency", "Other"]
}

struct JournalEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var billId: String?
    var text: String
}

struct FloorNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var chamber = "House"
    var text: String
}

struct Deadline: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var date: Date
    var billId: String?
}

struct ReportPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var source = "Starred"                 // Starred, High priority, With a position, or a folder name
    var fields: [String] = ReportPreset.defaultFields
    var includeInternal = false            // notes, assignments and next actions
    static let allFields = ["Status", "Latest action", "Summary", "Position", "Sponsor", "Committee",
                            "Next hearing", "Next action", "Assigned to", "Talking points", "My notes"]
    static let defaultFields = ["Status", "Latest action", "Position", "Next hearing"]
    static let internalFields: Set<String> = ["Next action", "Assigned to", "My notes"]
}

// MARK: - Dates

enum DateText {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: String(s.prefix(10)))
    }

    static func pretty(_ s: String?) -> String {
        guard let d = date(s) else { return s ?? "" }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func string(_ d: Date) -> String { iso.string(from: d) }

    /// The date n days ago as "yyyy-MM-dd", for "past week" checks.
    static func daysAgo(_ n: Int) -> String {
        string(Date(timeIntervalSinceNow: -Double(n) * 24 * 60 * 60))
    }
}
