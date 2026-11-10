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

    private let dataURL: URL = {
        let base = Bundle.main.object(forInfoDictionaryKey: "DataURL") as? String ?? ""
        return URL(string: base)!
    }()

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    init() {
        starred = Set(UserDefaults.standard.stringArray(forKey: "starred") ?? [])
        loadCache()
    }

    // MARK: Lists

    var newBills: [Bill] {
        bills.filter { $0.changeKind != nil }   // already sorted newest first by the server
    }

    var watching: [Bill] {
        bills.filter { starred.contains($0.id) }
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
            bills = feed.bills
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
            bills = feed.bills
            lastUpdated = feed.generatedAt
        }
        if let d = try? Data(contentsOf: cacheDir.appendingPathComponent("recap.json")) {
            recap = try? JSONDecoder().decode(WeeklyRecap.self, from: d)
        }
    }

    // MARK: Alerts

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
                              title: "\(bill.number) \(bill.changeLabel?.lowercased() ?? "updated")",
                              body: bill.versions.last?.changes ?? "Status: \(bill.status)")
            }
            prints[bill.id] = now
        }
        fingerprints = prints

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
