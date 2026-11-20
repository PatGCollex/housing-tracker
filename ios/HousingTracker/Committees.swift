import SwiftUI

// MARK: - Data

struct CommitteeMember: Codable, Hashable, Identifiable {
    let name: String
    let district: String
    let position: String
    let party: String?
    let personId: Int?
    let note: String?
    let leaving: Leaving?

    var id: String { "\(name)-\(district)" }
    var isLeader: Bool { ["Chairman", "Vice Chairman", "Secretary"].contains(position) }
}

struct Leaving: Codable, Hashable {
    let status: String?
    let label: String?
    let detail: String?
    let successor: String?
    let source: String?
    let sourceDate: String?

    /// Lost, retiring or gone for sure (red); still being decided (orange).
    var isFinal: Bool { !["undecided", "runoff"].contains(status ?? "") }
}

struct Committee: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let chamber: String?
    let url: String?
    let office: String?
    let phone: String?
    let chair: String?
    let viceChair: String?
    let secretary: String?
    let leavingCount: Int?
    let partyCount: [String: Int]?
    let members: [CommitteeMember]

    var leaders: [CommitteeMember] { members.filter(\.isLeader) }
    var others: [CommitteeMember] { members.filter { !$0.isLeader } }
}

struct Departure: Codable, Hashable, Identifiable {
    let chamber: String
    let district: String
    let name: String
    let party: String?
    let status: String
    let label: String
    let detail: String?
    let successor: String?
    let source: String?
    let sourceDate: String?

    var id: String { "\(chamber)-\(district)" }
}

struct NextSession: Codable, Hashable {
    let session: String?
    let checkedAt: String?
    let house: [Committee]?
    let senate: [Committee]?
}

struct CommitteesFeed: Codable {
    let generatedAt: String?
    let session: String?
    let source: String?
    let house: [Committee]
    let senate: [Committee]
    let departures: [Departure]
    let departuresUpdated: String?
    let next: NextSession?
}

struct Leader: Codable, Hashable, Identifiable {
    let chamber: String
    let role: String
    let name: String
    let party: String?
    let district: String?
    let status: String?
    let source: String?
    let sourceDate: String?
    let note: String?

    var id: String { "\(chamber)-\(role)" }
}

struct Leadership2027: Codable, Hashable {
    let updated: String?
    let sessionStarts: String?
    let summary: String?
    let leaders: [Leader]?
}

struct ReportSource: Codable, Hashable, Identifiable {
    let source: String?
    let url: String
    let title: String?
    let date: String?
    let quote: String?
    let level: String?

    var id: String { url }
}

struct AssignmentReport: Codable, Hashable, Identifiable {
    let chamber: String
    let committee: String
    let role: String
    let name: String
    let district: String?
    let party: String?
    let memberElect: Bool?
    let level: String
    let outlets: Int?
    let firstSeen: String?
    let lastSeen: String?
    let leaving: String?
    let sources: [ReportSource]

    var id: String { "\(chamber)|\(committee)|\(name)|\(role)" }
}

struct OutlookCommittee: Codable, Hashable, Identifiable {
    let chamber: String
    let name: String
    let reports: [AssignmentReport]

    var id: String { "\(chamber)|\(name)" }
}

struct Outlook2027: Codable {
    let generatedAt: String?
    let leadership: Leadership2027?
    let officialPosted: Bool?
    let committees: [OutlookCommittee]
    let how: String?
}

struct CapitolNewsItem: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let url: String
    let outlet: String
    let date: String
    let kinds: [String]
    let people: [String]?
    let assignments: Int?
    let snippet: String?
    let social: Bool?
}

struct CapitolNewsFeed: Codable {
    let generatedAt: String?
    let items: [CapitolNewsItem]
}

// MARK: - Store

/// Committees now, the 2027 outlook and Capitol news. Updated 4 times a day by the GitHub job.
@MainActor
final class CommitteeStore: ObservableObject {
    @Published private(set) var feed: CommitteesFeed?
    @Published private(set) var outlook: Outlook2027?
    @Published private(set) var news: [CapitolNewsItem] = []

    private let dataURL: URL = {
        let base = Bundle.main.object(forInfoDictionaryKey: "DataURL") as? String ?? ""
        return URL(string: base)!
    }()

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    init() {
        feed = load("committees.json")
        outlook = load("outlook2027.json")
        news = (load("capitol-news.json") as CapitolNewsFeed?)?.items ?? []
    }

    var allReports: [AssignmentReport] { outlook?.committees.flatMap(\.reports) ?? [] }

    func reports(for committee: Committee) -> [AssignmentReport] {
        let key = Self.key(committee.name)
        return allReports.filter { $0.chamber == committee.chamber && Self.key($0.committee) == key }
    }

    func committees(of person: Person) -> [(Committee, CommitteeMember)] {
        let list = person.chamber == "Senate" ? feed?.senate ?? [] : feed?.house ?? []
        return list.compactMap { c in
            c.members.first { $0.personId == person.id || ($0.district == person.district && person.displayName.contains($0.name.split(separator: " ").last.map(String.init) ?? "-")) }
                .map { (c, $0) }
        }
    }

    func refresh() async {
        if let f: CommitteesFeed = await fetch("committees.json") { feed = f }
        if let o: Outlook2027 = await fetch("outlook2027.json") { outlook = o }
        if let n: CapitolNewsFeed = await fetch("capitol-news.json") { news = n.items }
        checkForAlerts()
    }

    private static func key(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "&", with: "and").filter { $0.isLetter }
    }

    private func fetch<T: Decodable>(_ name: String) async -> T? {
        var req = URLRequest(url: dataURL.appendingPathComponent(name))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        try? data.write(to: cacheDir.appendingPathComponent(name))
        return value
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: cacheDir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Alerts for new 2027 assignment reports and new staff or leadership news. The first load only remembers.
    private func checkForAlerts() {
        guard BillStore.setting("alertCommittees") else { return }
        let defaults = UserDefaults.standard
        let firstTime = defaults.object(forKey: "seenReports") == nil
        var seenReports = Set(defaults.stringArray(forKey: "seenReports") ?? [])
        var seenNews = Set(defaults.stringArray(forKey: "seenNews") ?? [])
        var alerts: [(String, String)] = []

        for r in allReports where !seenReports.contains(r.id) {
            seenReports.insert(r.id)
            let who = "\(r.chamber == "Senate" ? "Sen." : "Rep.") \(r.name)"
            alerts.append(("2027 \(r.level): \(r.committee)", "\(who) reported as \(r.role). Source: \(r.sources.first?.source ?? "news")"))
        }
        for n in news where !seenNews.contains(n.id) {
            seenNews.insert(n.id)
            if n.kinds.contains("staff") {
                alerts.append(("Capitol staff news", "\(n.title) (\(n.outlet))"))
            } else if n.kinds.contains("leadership") && !n.kinds.contains("assignment") {
                alerts.append(("Leadership news", "\(n.title) (\(n.outlet))"))
            }
        }
        defaults.set(Array(seenReports), forKey: "seenReports")
        defaults.set(Array(Array(seenNews).suffix(2000)), forKey: "seenNews")
        guard !firstTime else { return }
        for a in alerts.prefix(5) {
            Notifier.send(id: "committees", title: a.0, body: a.1, urgent: a.0.hasPrefix("2027 Official") || a.0.hasPrefix("2027 Announced"))
        }
        if alerts.count > 5 {
            Notifier.send(id: "committees", title: "\(alerts.count - 5) more committee and staff updates",
                          body: "Open Capitol > Committees to see them.", urgent: false)
        }
    }
}

// MARK: - Main screen

struct CommitteesView: View {
    @EnvironmentObject var committees: CommitteeStore
    @AppStorage("committeesTab") private var tab = "Now"

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Now").tag("Now")
                Text("2027").tag("2027")
                Text("News").tag("News")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.bottom, 6)
            switch tab {
            case "2027": OutlookView()
            case "News": CapitolNewsView()
            default: CurrentCommitteesView()
            }
        }
        .navigationTitle("Committees")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await committees.refresh() }
    }
}

// MARK: - Now

struct CurrentCommitteesView: View {
    @EnvironmentObject var committees: CommitteeStore
    @AppStorage("committeeChamber") private var chamber = "House"
    @State private var query = ""

    private var list: [Committee] {
        let all = chamber == "Senate" ? committees.feed?.senate ?? [] : committees.feed?.house ?? []
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { c in
            c.name.lowercased().contains(q) || c.members.contains { $0.name.lowercased().contains(q) || $0.district == q }
        }
    }

    private var leaving: [Departure] {
        (committees.feed?.departures ?? []).filter { $0.chamber == chamber }
    }

    var body: some View {
        List {
            Section {
                Picker("Chamber", selection: $chamber) {
                    Text("House").tag("House")
                    Text("Senate").tag("Senate")
                }
                .pickerStyle(.segmented)
                NavigationLink {
                    DeparturesView(chamber: chamber)
                } label: {
                    Label("Leaving after 2026 (\(leaving.count))", systemImage: "door.left.hand.open")
                        .foregroundStyle(.red)
                }
            } footer: {
                if let f = committees.feed {
                    Text("\(f.session ?? "Current session") · from \(f.source ?? "legis.ga.gov") · updated \(DateText.pretty(f.generatedAt))")
                }
            }
            ForEach(list) { c in
                NavigationLink { CommitteeDetailView(committee: c) } label: { CommitteeRow(committee: c) }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Committee, member or district")
        .overlay { EmptyMessage(text: committees.feed == nil ? "Committees load after the next update. Pull down to try." : nil) }
    }
}

struct CommitteeRow: View {
    let committee: Committee

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(committee.name).font(.subheadline.weight(.semibold))
            Text([committee.chair.map { "Chair: \($0)" }, committee.viceChair.map { "Vice: \($0)" }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("\(committee.members.count) members").font(.caption2).foregroundStyle(.secondary)
                if let pc = committee.partyCount {
                    Text("R \(pc["R"] ?? 0) · D \(pc["D"] ?? 0)").font(.caption2).foregroundStyle(.secondary)
                }
                if let n = committee.leavingCount, n > 0 {
                    ColorTag(text: "\(n) leaving", color: .red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct CommitteeDetailView: View {
    @EnvironmentObject var committees: CommitteeStore
    @EnvironmentObject var store: BillStore
    let committee: Committee

    var body: some View {
        let reports = committees.reports(for: committee)
        List {
            Section("Leadership") {
                ForEach(committee.leaders) { MemberRow(member: $0, showPosition: true) }
            }
            if !reports.isEmpty {
                Section("Reported for 2027") {
                    ForEach(reports) { r in NavigationLink { ReportDetailView(report: r) } label: { ReportRow(report: r) } }
                }
            }
            Section("Members (\(committee.others.count))") {
                ForEach(committee.others) { m in
                    if let p = store.person(id: m.personId) {
                        NavigationLink(value: p) { MemberRow(member: m, showPosition: m.position != "Member") }
                    } else {
                        MemberRow(member: m, showPosition: m.position != "Member")
                    }
                }
            }
            Section {
                if let pc = committee.partyCount {
                    LabeledContent("Party split", value: "\(pc["R"] ?? 0) Republicans · \(pc["D"] ?? 0) Democrats")
                }
                if let office = committee.office { LabeledContent("Office", value: office) }
                if let phone = committee.phone, let url = URL(string: "tel:\(phone.filter(\.isNumber))") {
                    Link(destination: url) { Label(phone, systemImage: "phone") }
                }
                if let s = committee.url, let url = URL(string: s) {
                    Link(destination: url) { Label("Committee page on legis.ga.gov", systemImage: "safari") }
                }
            }
        }
        .navigationTitle(committee.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MemberRow: View {
    let member: CommitteeMember
    var showPosition = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PartyDot(party: member.party)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name).font(.subheadline.weight(member.isLeader ? .semibold : .regular))
                    if let l = member.leaving, let label = l.label {
                        ColorTag(text: label, color: l.isFinal ? .red : .orange)
                    }
                }
                Text([showPosition ? member.position : nil, "District \(member.district)", member.note]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let l = member.leaving {
                    Text([l.detail, l.successor.map { "Next: \($0)" }].compactMap { $0 }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PartyDot: View {
    let party: String?

    var body: some View {
        Text(party ?? "?")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(party == "R" ? Color.red : party == "D" ? Color.blue : Color.gray, in: Circle())
    }
}

struct ColorTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct DeparturesView: View {
    @EnvironmentObject var committees: CommitteeStore
    let chamber: String

    private var groups: [(String, [Departure])] {
        let list = (committees.feed?.departures ?? []).filter { $0.chamber == chamber }
        let order = ["Lost Nov 3", "Lost primary", "Race undecided", "In Dec 1 runoff", "Retiring",
                     "Elected to other office", "Ran for other office"]
        return order.compactMap { label in
            let l = list.filter { $0.label == label }.sorted { (Int($0.district) ?? 0) < (Int($1.district) ?? 0) }
            return l.isEmpty ? nil : (label, l)
        }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { group in
                Section("\(group.0) (\(group.1.count))") {
                    ForEach(group.1) { d in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                PartyDot(party: d.party)
                                Text(d.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("District \(d.district)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let detail = d.detail { Text(detail).font(.caption) }
                            if let s = d.successor { Text("Next: \(s)").font(.caption).foregroundStyle(.secondary) }
                            if let src = d.source, let url = URL(string: src) {
                                Link("Source (\(DateText.pretty(d.sourceDate)))", destination: url).font(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section {
                Text("Checked by hand from election results and news, last on \(DateText.pretty(committees.feed?.departuresUpdated)). Results are certified Nov 20; close races can still change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("\(chamber): leaving")
    }
}

// MARK: - 2027

struct OutlookView: View {
    @EnvironmentObject var committees: CommitteeStore
    @AppStorage("outlookChamber") private var chamber = "House"

    private var leaders: [Leader] { (committees.outlook?.leadership?.leaders ?? []).filter { $0.chamber == chamber } }
    private var list: [OutlookCommittee] { (committees.outlook?.committees ?? []).filter { $0.chamber == chamber } }

    var body: some View {
        List {
            Section {
                Picker("Chamber", selection: $chamber) {
                    Text("House").tag("House")
                    Text("Senate").tag("Senate")
                }
                .pickerStyle(.segmented)
                if let summary = committees.outlook?.leadership?.summary {
                    Text(summary).font(.callout)
                }
                if committees.outlook?.officialPosted == true {
                    Label("Official 2027 committee lists are posted on legis.ga.gov", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Committee assignments reported for 2027") {
                if list.isEmpty {
                    Text("None reported yet. The new Speaker names House chairs after the Jan 11 vote. This is checked 4 times a day, and you'll get an alert when one appears.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(list) { c in
                Section(c.name) {
                    ForEach(c.reports) { r in NavigationLink { ReportDetailView(report: r) } label: { ReportRow(report: r) } }
                }
            }

            Section("2027 leadership") {
                ForEach(leaders) { l in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.role).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            PartyDot(party: l.party)
                            Text(l.name).font(.subheadline.weight(.semibold))
                            if let d = l.district { Text("District \(d)").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let s = l.status { Text(s).font(.caption) }
                        if let n = l.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                        if let src = l.source, let url = URL(string: src) {
                            Link("Source (\(DateText.pretty(l.sourceDate)))", destination: url).font(.caption)
                        }
                    }
                }
            }

            if let how = committees.outlook?.how {
                Section {
                    Text(how).font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("How this works")
                } footer: {
                    Text("Updated \(DateText.pretty(committees.outlook?.generatedAt))")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct ReportRow: View {
    let report: AssignmentReport

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PartyDot(party: report.party)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(report.role): \(report.name)").font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    ColorTag(text: report.level, color: LevelColor.of(report.level))
                    Text("\(report.outlets ?? report.sources.count) source\((report.outlets ?? report.sources.count) == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                    if report.memberElect == true { ColorTag(text: "Member-elect", color: .purple) }
                    if let l = report.leaving { ColorTag(text: l, color: .red) }
                }
                Text("Latest: \(report.sources.first?.source ?? "") · \(DateText.pretty(report.lastSeen))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

enum LevelColor {
    static func of(_ level: String) -> Color {
        switch level {
        case "Official": return .green
        case "Announced": return .blue
        case "Reported": return .teal
        case "Speculation": return .orange
        default: return .gray
        }
    }
}

struct ReportDetailView: View {
    let report: AssignmentReport

    var body: some View {
        List {
            Section {
                Text("\(report.chamber) \(report.committee)").font(.headline)
                Text("\(report.role): \(report.name)\(report.district.map { ", District \($0)" } ?? "")")
                ColorTag(text: report.level, color: LevelColor.of(report.level))
            }
            Section("Sources (\(report.sources.count))") {
                ForEach(report.sources) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(s.source ?? "") · \(DateText.pretty(s.date))").font(.caption).foregroundStyle(.secondary)
                        if let t = s.title { Text(t).font(.subheadline.weight(.semibold)) }
                        if let q = s.quote { Text("“\(q)”").font(.callout).italic() }
                        if let url = URL(string: s.url) { Link("Open source", destination: url).font(.caption) }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Text("Found automatically by word rules, not by a person. Open the source before relying on it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("2027 report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - News

struct CapitolNewsView: View {
    @EnvironmentObject var committees: CommitteeStore
    @AppStorage("newsKind") private var kind = "all"

    private var items: [CapitolNewsItem] {
        kind == "all" ? committees.news : committees.news.filter { $0.kinds.contains(kind) }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $kind) {
                    Text("All").tag("all")
                    Text("Committees").tag("assignment")
                    Text("Staff").tag("staff")
                    Text("Leaders").tag("leadership")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("From press offices, Georgia news sites, Google and Bing News, Reddit and Bluesky. Checked 4 times a day.")
            }
            ForEach(items) { n in
                if let url = URL(string: n.url) {
                    Link(destination: url) { NewsRow(item: n) }
                        .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { EmptyMessage(text: items.isEmpty ? "Nothing yet. New stories show up here after each update." : nil) }
    }
}

struct NewsRow: View {
    let item: CapitolNewsItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(item.outlet) · \(DateText.pretty(item.date))").font(.caption).foregroundStyle(.secondary)
                if item.social == true { ColorTag(text: "Social", color: .gray) }
                if item.kinds.contains("staff") { ColorTag(text: "Staff", color: .purple) }
                if (item.assignments ?? 0) > 0 { ColorTag(text: "Assignment", color: .teal) }
            }
            Text(item.title).font(.subheadline.weight(.semibold))
            if let s = item.snippet, !s.isEmpty {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}
