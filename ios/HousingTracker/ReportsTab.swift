import SwiftUI
import UIKit

/// Session dashboard, saved reports that export to PDF, and past sessions.
struct ReportsTab: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @State private var year = "All"
    @State private var shared: SharedFile?
    @AppStorage("alertStages") private var alertStages = true
    @AppStorage("alertNewBills") private var alertNewBills = true
    @AppStorage("alertHearings") private var alertHearings = true
    @AppStorage("alertRecap") private var alertRecap = true

    private var years: [String] { Array(Set(store.watching.map(\.year))).sorted(by: >) }

    /// Bills you watch in the chosen session year.
    private var tracked: [Bill] { store.watching.filter { year == "All" || $0.year == year } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Session", selection: $year) {
                        Text("All years").tag("All")
                        ForEach(years, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Dashboard") {
                    let priority = tracked.filter { workspace.isPriority($0) }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        Stat(value: tracked.count, label: "Watching")
                        Stat(value: tracked.filter(\.isLaw).count, label: "Became law", tint: .green)
                        Stat(value: tracked.filter { $0.outcome == false }.count, label: "Vetoed or failed", tint: .red)
                        Stat(value: priority.count, label: "High priority", tint: .orange)
                        Stat(value: priority.filter(\.isLaw).count, label: "Priority passed", tint: .green)
                        Stat(value: tracked.filter { $0.versions.count > 1 }.count, label: "Amended")
                        Stat(value: tracked.filter { workspace.work($0).position != nil }.count, label: "Positions")
                        Stat(value: workspace.data.meetings.count, label: "Meetings")
                        Stat(value: workspace.data.tasks.filter(\.done).count, label: "Tasks done")
                    }
                    .padding(.vertical, 4)
                    ForEach(Bill.statusGroupOrder, id: \.self) { group in
                        let n = tracked.filter { $0.statusGroup == group }.count
                        if n > 0 {
                            HStack {
                                Text(group)
                                Spacer()
                                Text("\(n)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("End-of-session summary (PDF)", systemImage: "doc.richtext") {
                        let html = Briefing.sessionSummary(year: year, bills: tracked, store: store, workspace: workspace)
                        shared = PDFMaker.make(html: html, name: "Session summary \(year == "All" ? "" : year)").map(SharedFile.init)
                    }
                }

                Section {
                    ForEach(workspace.data.reports) { preset in
                        NavigationLink { ReportBuilderView(presetId: preset.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                Text("\(preset.source) · \(preset.fields.count) fields\(preset.includeInternal ? " · includes internal notes" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { workspace.data.reports.remove(atOffsets: $0) }
                    Button("New report", systemImage: "plus") {
                        workspace.data.reports.append(ReportPreset(name: "New report"))
                    }
                } header: { Text("Reports") } footer: {
                    Text("Reports turn into a PDF you can email or print. Internal notes stay out unless you include them.")
                }

                Section {
                    Toggle("Starred bills: every change", isOn: .constant(true)).disabled(true)
                    Toggle("Housing bills: each step of the cycle", isOn: $alertStages)
                    Toggle("New housing bills", isOn: $alertNewBills)
                    Toggle("High priority: reminder the day before a hearing", isOn: $alertHearings)
                    Toggle("Monday weekly recap", isOn: $alertRecap)
                } header: { Text("Alerts") } footer: {
                    Text("Unstar a bill to stop its alerts. High priority alerts are flagged and use a different sound.")
                }

                Section {
                    TextField("Your organization's name (shown on reports)", text: $workspace.data.orgName)
                }
            }
            .navigationTitle("Reports")
            .sheet(item: $shared) { file in ShareSheet(url: file.url) }
            .appDestinations()
        }
    }
}

struct Stat: View {
    let value: Int
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.weight(.bold)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Pick which bills and which fields go in a report, then export a PDF.
struct ReportBuilderView: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    let presetId: UUID
    @State private var shared: SharedFile?

    private var index: Int? { workspace.data.reports.firstIndex { $0.id == presetId } }

    private var sources: [String] {
        ["Starred", "High priority", "With a position"] + workspace.data.folders.map(\.name)
    }

    var body: some View {
        if let i = index {
            let preset = workspace.data.reports[i]
            let bills = Briefing.bills(for: preset, store: store, workspace: workspace)
            Form {
                Section {
                    TextField("Report name, like Weekly CEO update", text: $workspace.data.reports[i].name)
                    Picker("Bills", selection: $workspace.data.reports[i].source) {
                        ForEach(sources, id: \.self) { Text($0).tag($0) }
                    }
                    Text("\(bills.count) bills").foregroundStyle(.secondary)
                }
                Section {
                    ForEach(ReportPreset.allFields, id: \.self) { field in
                        Toggle(field, isOn: Binding(
                            get: { workspace.data.reports[i].fields.contains(field) },
                            set: { on in
                                var fields = workspace.data.reports[i].fields.filter { $0 != field }
                                if on { fields.append(field) }
                                // Keep the standard order.
                                workspace.data.reports[i].fields = ReportPreset.allFields.filter { fields.contains($0) }
                            }
                        ))
                    }
                } header: { Text("Fields") }
                Section {
                    Toggle("Include internal notes", isOn: $workspace.data.reports[i].includeInternal)
                } footer: {
                    Text("Off: next actions, assignments and your notes are left out, so the report is safe to share with leadership or members.")
                }
                Section {
                    Button("Create PDF", systemImage: "doc.richtext") {
                        let html = Briefing.report(preset: preset, bills: bills, store: store, workspace: workspace)
                        shared = PDFMaker.make(html: html, name: preset.name).map(SharedFile.init)
                    }
                    .disabled(bills.isEmpty)
                }
            }
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $shared) { file in ShareSheet(url: file.url) }
        } else {
            Text("This report was deleted.")
        }
    }
}

// MARK: - PDFs

enum PDFMaker {
    /// Turns HTML into a letter-size PDF file and returns where it was saved.
    @MainActor
    static func make(html: String, name: String) -> URL? {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page.insetBy(dx: 42, dy: 42)), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let safe = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Report" : safe).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// Builds the HTML for prep sheets, reports and session summaries. Template text only, no AI.
@MainActor
enum Briefing {
    static func bills(for preset: ReportPreset, store: BillStore, workspace: Workspace) -> [Bill] {
        switch preset.source {
        case "Starred": return store.watching
        case "High priority": return store.watching.filter { workspace.isPriority($0) }
        case "With a position": return store.bills.filter { workspace.work($0).position != nil }.sorted { $0.numberOrder < $1.numberOrder }
        default:
            let ids = workspace.data.folders.first { $0.name == preset.source }?.billIds ?? []
            return store.bills.filter { ids.contains($0.id) }.sorted { $0.numberOrder < $1.numberOrder }
        }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func page(title: String, subtitle: String, body: String) -> String {
        """
        <html><head><style>
        body { font-family: -apple-system, Helvetica; font-size: 11pt; color: #111; }
        h1 { font-size: 20pt; margin: 0 0 2px 0; color: #0b2545; }
        .sub { color: #666; margin-bottom: 16px; }
        h2 { font-size: 13pt; margin: 18px 0 4px 0; color: #0b2545; border-bottom: 1px solid #ccd; padding-bottom: 2px; }
        .bill { margin: 0 0 14px 0; page-break-inside: avoid; }
        .num { font-weight: bold; }
        .label { color: #555; font-weight: 600; }
        .pill { display: inline-block; padding: 1px 6px; border-radius: 8px; background: #eef; font-size: 9pt; }
        table { border-collapse: collapse; width: 100%; }
        td { padding: 3px 6px; border-bottom: 1px solid #eee; vertical-align: top; }
        .foot { color: #888; font-size: 8pt; margin-top: 24px; }
        </style></head><body>
        <h1>\(esc(title))</h1><div class="sub">\(esc(subtitle))</div>
        \(body)
        <div class="foot">Source: Georgia General Assembly, via LegiScan. Prepared \(Date().formatted(date: .long, time: .shortened)).</div>
        </body></html>
        """
    }

    private static func row(_ label: String, _ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "<div><span class=\"label\">\(esc(label)):</span> \(esc(value))</div>"
    }

    private static func position(_ w: BillWork) -> String? {
        w.position.map { "\($0.rawValue)\(w.positionApproved ? "" : " (proposed)")" }
    }

    private static func nextHearing(_ bill: Bill) -> String? {
        bill.upcoming.first.map { u in
            [DateText.pretty(u.date), u.time, u.what, u.`where`].compactMap { $0 }.joined(separator: " · ")
        }
    }

    static func report(preset: ReportPreset, bills: [Bill], store: BillStore, workspace: Workspace) -> String {
        let fields = preset.fields.filter { preset.includeInternal || !ReportPreset.internalFields.contains($0) }
        var html = ""
        for bill in bills {
            let w = workspace.work(bill)
            html += "<div class=\"bill\"><div class=\"num\">\(esc(bill.displayNumber)): \(esc(bill.displayHeadline))</div>"
            for field in fields {
                switch field {
                case "Status": html += row("Status", bill.status)
                case "Latest action": html += row("Latest action", bill.lastAction.map { "\($0) (\(DateText.pretty(bill.lastActionDate)))" })
                case "Summary": html += row("Summary", bill.recap)
                case "Position": html += row("Position", position(w))
                case "Sponsor": html += row("Sponsor", bill.sponsor)
                case "Committee": html += row("Committee", bill.committee)
                case "Next hearing": html += row("Next hearing", nextHearing(bill))
                case "Next action": html += row("Next action", w.nextAction)
                case "Assigned to": html += row("Assigned to", w.assignedTo)
                case "Talking points": html += row("Talking points", w.talkingPoints)
                case "My notes": html += row("Notes", w.note)
                default: break
                }
            }
            html += "</div>"
        }
        let org = workspace.data.orgName.isEmpty ? "" : "\(workspace.data.orgName) · "
        return page(title: preset.name, subtitle: "\(org)\(bills.count) bills · \(Date().formatted(date: .long, time: .omitted))", body: html)
    }

    static func prepSheet(bill: Bill, work w: BillWork, store: BillStore, workspace: Workspace) -> String {
        var html = "<h2>The bill</h2>"
        html += row("Title", bill.displayHeadline)
        html += row("Sponsor", bill.allSponsors.compactMap(\.name).joined(separator: ", "))
        html += row("Committee", bill.committee)
        html += row("Status", bill.status)
        html += row("Latest action", bill.lastAction)
        html += row("Next hearing", nextHearing(bill))
        html += row("Summary", bill.recap)
        html += "<h2>Our position</h2>"
        html += row("Position", position(w) ?? "Not set")
        html += row("Why", w.positionReason)
        html += "<h2>Talking points</h2><div>\(esc(w.talkingPoints.isEmpty ? "—" : w.talkingPoints))</div>"
        html += "<h2>Questions for the hearing</h2><div>\(esc(w.questions.isEmpty ? "—" : w.questions))</div>"
        if !w.stakeholders.isEmpty {
            html += "<h2>Who supports or opposes</h2><table>"
            for s in w.stakeholders {
                html += "<tr><td>\(esc(s.name))</td><td>\(esc(s.stance))</td><td>\(s.confirmed ? "Public" : "Heard")</td><td>\(esc(s.note))</td></tr>"
            }
            html += "</table>"
        }
        let related = w.related.compactMap { r in store.bill(id: r.billId).map { "\(r.kind): \($0.displayNumber), \($0.displayHeadline)" } }
        if !related.isEmpty { html += "<h2>Related bills</h2><div>\(esc(related.joined(separator: "\n")))</div>" }
        let meetings = workspace.meetings(for: bill).prefix(5)
        if !meetings.isEmpty {
            html += "<h2>Recent meetings</h2>"
            for m in meetings {
                html += "<div><span class=\"label\">\(esc(m.date.formatted(date: .abbreviated, time: .omitted))), \(esc(m.personName.isEmpty ? m.role : m.personName)):</span> \(esc(m.notes))</div>"
            }
        }
        html += "<h2>Notes</h2><div>\(esc(w.note.isEmpty ? "—" : w.note))</div>"
        return page(title: "\(bill.displayNumber) hearing prep", subtitle: bill.displayHeadline, body: html)
    }

    static func sessionSummary(year: String, bills: [Bill], store: BillStore, workspace: Workspace) -> String {
        var html = "<h2>At a glance</h2><table>"
        for group in Bill.statusGroupOrder {
            let n = bills.filter { $0.statusGroup == group }.count
            html += "<tr><td>\(esc(group))</td><td>\(n)</td></tr>"
        }
        let priority = bills.filter { workspace.isPriority($0) }
        html += "<tr><td>High priority bills</td><td>\(priority.count) (\(priority.filter(\.isLaw).count) became law)</td></tr>"
        html += "<tr><td>Positions taken</td><td>\(bills.filter { workspace.work($0).position != nil }.count)</td></tr>"
        html += "<tr><td>Meetings logged</td><td>\(workspace.data.meetings.count)</td></tr></table>"
        for group in Bill.statusGroupOrder {
            let list = bills.filter { $0.statusGroup == group }
            guard !list.isEmpty else { continue }
            html += "<h2>\(esc(group)) (\(list.count))</h2>"
            for bill in list {
                let pos = position(workspace.work(bill)).map { " <span class=\"pill\">\(esc($0))</span>" } ?? ""
                html += "<div class=\"bill\"><span class=\"num\">\(esc(bill.displayNumber))</span>: \(esc(bill.displayHeadline))\(pos)</div>"
            }
        }
        let org = workspace.data.orgName.isEmpty ? "" : "\(workspace.data.orgName) · "
        return page(title: "Session summary\(year == "All" ? "" : " \(year)")", subtitle: "\(org)\(bills.count) bills watched", body: html)
    }
}
