import Foundation
import UserNotifications

/// Bill data from the update job, plus stars, the inbox and alerts.
@MainActor
final class BillStore: ObservableObject {
    @Published private(set) var bills: [Bill] = []
    @Published private(set) var recap: WeeklyRecap?
    @Published private(set) var people: [Person] = []
    @Published private(set) var votes: VotesFeed?
    @Published private(set) var calendar: SessionCalendar?
    @Published private(set) var lastUpdated: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var loadError: String?
    @Published var starred: Set<String> {
        didSet { UserDefaults.standard.set(Array(starred), forKey: "starred") }
    }
    @Published var inbox: [InboxItem] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(inbox), forKey: "inbox") }
    }

    private var byId: [String: Bill] = [:]
    private var haystacks: [String: String] = [:]
    private var diffCache: [String: [DiffPair]] = [:]

    private let dataURL: URL = {
        let base = Bundle.main.object(forInfoDictionaryKey: "DataURL") as? String ?? ""
        return URL(string: base)!
    }()

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    init() {
        starred = Set(UserDefaults.standard.stringArray(forKey: "starred") ?? [])
        inbox = Self.savedInbox()
        loadCache()
    }

    // MARK: Lists

    func bill(id: String?) -> Bill? {
        guard let id else { return nil }
        return byId[id]
    }

    func person(id: Int?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    /// Bills with any action in the past 7 days.
    var thisWeek: [Bill] {
        let cutoff = DateText.daysAgo(7)
        return bills.filter { $0.sortDate >= cutoff }
    }

    /// Starred bills, HB then SB in number order.
    var watching: [Bill] {
        bills.filter { starred.contains($0.id) }.sorted { $0.numberOrder < $1.numberOrder }
    }

    /// Bills a legislator sponsors.
    func sponsored(by person: Person) -> [Bill] {
        bills.filter { $0.allSponsors.contains { $0.id == person.id } }
    }

    /// Search by keywords. Every word must appear somewhere; "HB 31", "H.B. 31" and "hb31" all find HB 31.
    func search(_ query: String, in list: [Bill]? = nil, notes: [String: String] = [:]) -> [Bill] {
        let source = list ?? bills
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else { return source }
        let numberTokens = tokens.filter { Self.isBillNumber($0) }
        let wordTokens = tokens.filter { !Self.isBillNumber($0) }
        return source.filter { bill in
            if !numberTokens.isEmpty && !numberTokens.contains(bill.searchNumber) { return false }
            guard !wordTokens.isEmpty else { return true }
            let hay = (haystacks[bill.id] ?? "") + " " + (notes[bill.id] ?? "").lowercased()
            return wordTokens.allSatisfy { hay.contains($0) }
        }
    }

    private static func tokens(_ query: String) -> [String] {
        var q = query.lowercased().replacingOccurrences(of: ".", with: "")
        // "hb 31" -> "hb31"
        q = q.replacingOccurrences(of: #"\b(hb|sb|hr|sr)\s+(\d+)\b"#, with: "$1$2", options: .regularExpression)
        return q.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    private static func isBillNumber(_ token: String) -> Bool {
        token.range(of: #"^(hb|sb|hr|sr)\d+$"#, options: .regularExpression) != nil
    }

    func toggleStar(_ bill: Bill) {
        if starred.contains(bill.id) {
            starred.remove(bill.id)
        } else {
            starred.insert(bill.id)
            rememberFingerprint(bill)
            Notifier.requestPermission()
        }
    }

    func star(_ bill: Bill) {
        if !starred.contains(bill.id) { toggleStar(bill) }
    }

    // MARK: Inbox

    private static func savedInbox() -> [InboxItem] {
        UserDefaults.standard.data(forKey: "inbox")
            .flatMap { try? JSONDecoder().decode([InboxItem].self, from: $0) } ?? []
    }

    var unreadCount: Int { inbox.filter { !$0.read }.count }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        inbox = inbox.map { (item: InboxItem) -> InboxItem in
            var copy = item
            copy.read = true
            return copy
        }
    }

    // MARK: Loading

    func refresh() async {
        inbox = Self.savedInbox()   // pick up alerts saved by a background check
        do {
            let feedData = try await fetch("bills.json")
            let feed = try JSONDecoder().decode(BillFeed.self, from: feedData)
            try? feedData.write(to: cacheDir.appendingPathComponent("bills.json"))
            setBills(feed.bills)
            lastUpdated = feed.generatedAt
            lastChecked = Date()
            loadError = nil

            if let data = try? await fetch("recap.json"), let r = try? JSONDecoder().decode(WeeklyRecap.self, from: data) {
                try? data.write(to: cacheDir.appendingPathComponent("recap.json"))
                recap = r
            }
            if let data = try? await fetch("people.json"), let p = try? JSONDecoder().decode(PeopleFeed.self, from: data) {
                try? data.write(to: cacheDir.appendingPathComponent("people.json"))
                people = p.people.sorted { ($0.last ?? $0.displayName) < ($1.last ?? $1.displayName) }
            }
            if let data = try? await fetch("calendar.json"), let c = try? JSONDecoder().decode(SessionCalendar.self, from: data) {
                try? data.write(to: cacheDir.appendingPathComponent("calendar.json"))
                calendar = c
            }
            votes = nil   // reloaded the next time someone opens a vote
            diffCache = [:]
            checkForAlerts()
        } catch {
            loadError = bills.isEmpty ? "Couldn't load bills. Pull down to try again." : nil
        }
    }

    /// How each legislator voted. Loaded only when needed, since the file is large.
    func loadVotes() async {
        guard votes == nil else { return }
        if let data = try? await fetch("votes.json"), let v = try? JSONDecoder().decode(VotesFeed.self, from: data) {
            try? data.write(to: cacheDir.appendingPathComponent("votes.json"))
            votes = v
        } else if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("votes.json")) {
            votes = try? JSONDecoder().decode(VotesFeed.self, from: data)
        }
    }

    /// How one legislator voted on one roll call: Yes, No, Didn't vote, Absent, or nil.
    func vote(of person: Person, on roll: VoteSummary) -> String? {
        guard let votes, let row = votes.rolls[roll.key], let i = votes.people.firstIndex(of: person.id) else { return nil }
        let chars = Array(row)
        guard i < chars.count else { return nil }
        switch chars[i] {
        case "Y": return "Yes"
        case "N": return "No"
        case "X": return "Didn't vote"
        case "A": return "Absent"
        default: return nil
        }
    }

    /// Everyone's vote on one roll call, grouped.
    func breakdown(of roll: VoteSummary) -> [VoteGroup] {
        ["Yes", "No", "Didn't vote", "Absent"].compactMap { label in
            let list = people.filter { vote(of: $0, on: roll) == label }
            return list.isEmpty ? nil : VoteGroup(label: label, people: list)
        }
    }

    /// What changed between versions of a bill.
    func diffs(for bill: Bill) async -> [DiffPair] {
        if let cached = diffCache[bill.id] { return cached }
        guard let data = try? await fetch("diffs/\(bill.id).json"),
              let file = try? JSONDecoder().decode(DiffFile.self, from: data) else { return [] }
        diffCache[bill.id] = file.pairs
        return file.pairs
    }

    private func setBills(_ list: [Bill]) {
        bills = list.filter(\.isGeorgia).sorted { $0.sortDate > $1.sortDate }
        byId = Dictionary(bills.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var hay: [String: String] = [:]
        for b in bills {
            let sponsors = b.allSponsors.compactMap(\.name).joined(separator: " ")
            hay[b.id] = "\(b.number) \(b.displayNumber) \(b.title) \(b.recap ?? "") \(sponsors) \(b.committee ?? "") \(b.whyHousing ?? "")"
                .lowercased()
        }
        haystacks = hay
    }

    private func fetch(_ name: String) async throws -> Data {
        var req = URLRequest(url: dataURL.appendingPathComponent(name))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func loadCache() {
        if let d = try? Data(contentsOf: cacheDir.appendingPathComponent("bills.json")),
           let feed = try? JSONDecoder().decode(BillFeed.self, from: d) {
            setBills(feed.bills)
            lastUpdated = feed.generatedAt
        }
        if let d = try? Data(contentsOf: cacheDir.appendingPathComponent("recap.json")) {
            recap = try? JSONDecoder().decode(WeeklyRecap.self, from: d)
        }
        if let d = try? Data(contentsOf: cacheDir.appendingPathComponent("people.json")),
           let p = try? JSONDecoder().decode(PeopleFeed.self, from: d) {
            people = p.people.sorted { ($0.last ?? $0.displayName) < ($1.last ?? $1.displayName) }
        }
        if let d = try? Data(contentsOf: cacheDir.appendingPathComponent("calendar.json")) {
            calendar = try? JSONDecoder().decode(SessionCalendar.self, from: d)
        }
    }

    // MARK: Alerts

    /// High priority bills, saved by Workspace so background checks can see them.
    private var priorityIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "priorityIds") ?? [])
    }

    private var fingerprints: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "fingerprints") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "fingerprints") }
    }

    private func rememberFingerprint(_ bill: Bill) {
        fingerprints[bill.id] = bill.alertFingerprint
    }

    /// Shows an alert on the phone. Alerts for starred bills are also saved to the inbox.
    /// High priority bills get a flag, a different sound, and break through Focus where allowed.
    private func notify(billId: String?, title: String, body: String) {
        let priority = billId.map { priorityIds.contains($0) } ?? false
        let fullTitle = priority ? "🚩 HIGH PRIORITY: \(title)" : title
        if let billId, starred.contains(billId) {
            let item = InboxItem(date: Date(), title: fullTitle, body: body, billId: billId)
            inbox = Array(([item] + inbox).prefix(300))
        }
        Notifier.send(id: billId ?? "general", title: fullTitle, body: body, urgent: priority)
    }

    private func checkForAlerts() {
        // Starred bills: every action, new version, hearing or status change.
        var prints = fingerprints
        for bill in watching {
            let now = bill.alertFingerprint
            if let before = prints[bill.id], before != now {
                notify(billId: bill.id, title: "\(bill.displayNumber): \(bill.status)",
                       body: bill.lastAction ?? bill.displayHeadline)
            }
            prints[bill.id] = now
        }
        fingerprints = prints

        alertStageChanges()
        scheduleHearingReminders()

        if let recap, UserDefaults.standard.string(forKey: "lastRecap") != recap.generatedAt {
            if UserDefaults.standard.string(forKey: "lastRecap") != nil && Self.setting("alertRecap") {
                notify(billId: nil, title: "Your weekly housing recap", body: recap.summary)
            }
            UserDefaults.standard.set(recap.generatedAt, forKey: "lastRecap")
        }
    }

    /// Every step of the cycle on housing bills: filed, passed a chamber, passed both, signed, vetoed or failed.
    /// An alert setting from the Reports tab. Everything is on until you turn it off.
    static func setting(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func alertStageChanges() {
        let defaults = UserDefaults.standard
        let housing = bills.filter(\.isHousing)
        let now = Dictionary(housing.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        defer { defaults.set(now, forKey: "statuses") }
        guard let before = defaults.dictionary(forKey: "statuses") as? [String: String] else { return }  // first launch: just remember

        let cutoff = DateText.daysAgo(7)
        var alerts: [(id: String, title: String, body: String)] = []
        let stageAlerts = Self.setting("alertStages"), newAlerts = Self.setting("alertNewBills")
        for bill in housing where !starred.contains(bill.id) {
            if let old = before[bill.id] {
                if old != bill.status && stageAlerts {
                    alerts.append((bill.id, "\(bill.displayNumber) \(bill.stageVerb)", bill.displayHeadline))
                }
            } else if bill.sortDate >= cutoff && newAlerts {
                alerts.append((bill.id, "New housing bill: \(bill.displayNumber)", bill.displayHeadline))
            }
        }
        for a in alerts.prefix(5) {
            notify(billId: a.id, title: a.title, body: a.body)
        }
        if alerts.count > 5 {
            Notifier.send(id: "more", title: "\(alerts.count - 5) more housing bills moved",
                          body: "Open Housing Bills to see them.", urgent: false)
        }
    }

    /// A reminder at 8 AM the day before any hearing or vote on a high priority bill.
    private func scheduleHearingReminders() {
        guard Self.setting("alertHearings") else { return }
        let ids = priorityIds
        for bill in bills where ids.contains(bill.id) {
            for event in bill.upcoming {
                guard let date = DateText.date(event.date),
                      let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: date) else { continue }
                var parts = Calendar.current.dateComponents([.year, .month, .day], from: dayBefore)
                parts.hour = 8
                guard let fire = Calendar.current.date(from: parts), fire > Date() else { continue }
                Notifier.schedule(id: "hearing-\(bill.id)-\(event.date ?? "")",
                                  title: "🚩 Tomorrow: \(bill.displayNumber)",
                                  body: [event.what, event.time, event.`where`].compactMap { $0 }.joined(separator: " · "),
                                  at: parts)
            }
        }
    }
}

struct VoteGroup: Identifiable {
    let label: String
    let people: [Person]
    var id: String { label }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func send(id: String, title: String, body: String, urgent: Bool) {
        let req = UNNotificationRequest(identifier: "\(id)-\(Date().timeIntervalSince1970)",
                                        content: content(id: id, title: title, body: body, urgent: urgent),
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Same id replaces an earlier reminder, so reminders never pile up.
    static func schedule(id: String, title: String, body: String, at parts: DateComponents) {
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        let req = UNNotificationRequest(identifier: id, content: content(id: id, title: title, body: body, urgent: true),
                                        trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    private static func content(id: String, title: String, body: String, urgent: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["billId": id]
        if urgent {
            content.sound = .defaultRingtone
            content.interruptionLevel = .timeSensitive
        } else {
            content.sound = .default
        }
        return content
    }
}
