import Foundation
import UserNotifications

@MainActor
final class BillStore: ObservableObject {
    @Published private(set) var bills: [Bill] = []
    @Published private(set) var recap: WeeklyRecap?
    @Published private(set) var lastUpdated: String?
    @Published private(set) var loadError: String?
    @Published var starred: Set<String> {
        didSet { UserDefaults.standard.set(Array(starred), forKey: "starred") }
    }
    @Published var folders: [Folder] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(folders), forKey: "folders") }
    }

    private let dataURL: URL = {
        let base = Bundle.main.object(forInfoDictionaryKey: "DataURL") as? String ?? ""
        return URL(string: base)!
    }()

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    init() {
        starred = Set(UserDefaults.standard.stringArray(forKey: "starred") ?? [])
        folders = UserDefaults.standard.data(forKey: "folders")
            .flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
        loadCache()
    }

    // MARK: Lists

    /// Bills with any action in the past 7 days.
    var newBills: [Bill] {
        let weekAgo = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        let cutoff = String(ISO8601DateFormatter().string(from: weekAgo).prefix(10))
        return bills.filter { $0.sortDate >= cutoff }
    }

    /// Starred bills, HB then SB in number order.
    var watching: [Bill] {
        bills.filter { starred.contains($0.id) }.sorted { $0.numberOrder < $1.numberOrder }
    }

    // MARK: Folders

    @discardableResult
    func addFolder(_ name: String) -> Folder? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let folder = Folder(name: name)
        folders.append(folder)
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].name = name
    }

    func deleteFolder(_ folder: Folder) {
        folders.removeAll { $0.id == folder.id }
    }

    func isBill(_ bill: Bill, in folder: Folder) -> Bool {
        folders.first { $0.id == folder.id }?.billIds.contains(bill.id) ?? false
    }

    /// Adds or removes a bill from a folder. Adding also stars it.
    func toggle(_ bill: Bill, in folder: Folder) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        if folders[i].billIds.contains(bill.id) {
            folders[i].billIds.removeAll { $0 == bill.id }
        } else {
            folders[i].billIds.append(bill.id)
            if !starred.contains(bill.id) { toggleStar(bill) }
        }
    }

    func bills(in folder: Folder) -> [Bill] {
        watching.filter { folder.billIds.contains($0.id) }
    }

    var watchingWithoutFolder: [Bill] {
        let filed = Set(folders.flatMap(\.billIds))
        return watching.filter { !filed.contains($0.id) }
    }

    func search(_ query: String) -> [Bill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return bills }
        return bills.filter {
            "\($0.number) \($0.title) \($0.headline ?? "") \($0.recap ?? "") \($0.sponsor ?? "")"
                .lowercased().contains(q)
        }
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

    // MARK: Loading

    func refresh() async {
        do {
            let feedData = try await fetch("bills.json")
            let feed = try JSONDecoder().decode(BillFeed.self, from: feedData)
            try? feedData.write(to: cacheDir.appendingPathComponent("bills.json"))
            bills = Self.newestFirst(feed.bills)
            lastUpdated = feed.generatedAt
            loadError = nil

            if let recapData = try? await fetch("recap.json"),
               let r = try? JSONDecoder().decode(WeeklyRecap.self, from: recapData) {
                try? recapData.write(to: cacheDir.appendingPathComponent("recap.json"))
                recap = r
            }
            checkForAlerts()
        } catch {
            loadError = bills.isEmpty ? "Couldn't load bills. Pull down to try again." : nil
        }
    }

    /// Georgia bills only, newest first.
    private static func newestFirst(_ list: [Bill]) -> [Bill] {
        list.filter(\.isGeorgia).sorted { $0.sortDate > $1.sortDate }
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
            bills = Self.newestFirst(feed.bills)
            lastUpdated = feed.generatedAt
        }
        if let d = try? Data(contentsOf: cacheDir.appendingPathComponent("recap.json")) {
            recap = try? JSONDecoder().decode(WeeklyRecap.self, from: d)
        }
    }

    // MARK: Alerts

    /// Alerts for every step of the cycle on any tracked bill: newly filed, passed a chamber,
    /// passed both, signed, vetoed or failed. Starred bills get even more (see checkForAlerts).
    private func alertStageChanges() {
        let defaults = UserDefaults.standard
        let now = Dictionary(bills.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        defer { defaults.set(now, forKey: "statuses") }
        guard let before = defaults.dictionary(forKey: "statuses") as? [String: String] else { return }  // first launch: just remember

        let weekAgo = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        let cutoff = String(ISO8601DateFormatter().string(from: weekAgo).prefix(10))
        var alerts: [(id: String, title: String, body: String)] = []
        for bill in bills where !starred.contains(bill.id) {
            if let old = before[bill.id] {
                if old != bill.status {
                    alerts.append((bill.id, "\(bill.number) \(bill.stageVerb)", bill.displayHeadline))
                }
            } else if bill.sortDate >= cutoff {
                alerts.append((bill.id, "New bill: \(bill.number)", bill.displayHeadline))
            }
        }
        for a in alerts.prefix(5) {
            Notifier.send(id: a.id, title: a.title, body: a.body)
        }
        if alerts.count > 5 {
            Notifier.send(id: "more", title: "\(alerts.count - 5) more housing bills moved",
                          body: "Open Housing Bills to see them.")
        }
    }

    private var fingerprints: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "fingerprints") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "fingerprints") }
    }

    private func rememberFingerprint(_ bill: Bill) {
        fingerprints[bill.id] = bill.alertFingerprint
    }

    /// Alerts for starred bills that moved, and for a new weekly recap.
    private func checkForAlerts() {
        var prints = fingerprints
        for bill in watching {
            let now = bill.alertFingerprint
            if let before = prints[bill.id], before != now {
                Notifier.send(id: bill.id,
                              title: "\(bill.number): \(bill.status)",
                              body: bill.lastAction ?? bill.displayHeadline)
            }
            prints[bill.id] = now
        }
        fingerprints = prints
        alertStageChanges()

        if let recap, UserDefaults.standard.string(forKey: "lastRecap") != recap.generatedAt {
            if UserDefaults.standard.string(forKey: "lastRecap") != nil {
                Notifier.send(id: "recap", title: "Your weekly housing recap", body: recap.summary)
            }
            UserDefaults.standard.set(recap.generatedAt, forKey: "lastRecap")
        }
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["billId": id]
        let req = UNNotificationRequest(identifier: "\(id)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
