import SwiftUI

struct BillDetailView: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    let bill: Bill

    @State private var showTask = false
    @State private var showStakeholder = false
    @State private var showRelated = false
    @State private var showMeeting = false
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var calendarEvent: Upcoming?
    @State private var prepSheet: SharedFile?

    private var work: BillWork { workspace.work(bill) }
    private var starred: Bool { store.starred.contains(bill.id) }

    var body: some View {
        List {
            header
            quickActions
            Section("Progress") { ProgressTracker(stage: bill.stage) }

            if bill.recap != nil || bill.whyHousing != nil {
                Section("Summary") {
                    if let recap = bill.recap { Text(recap) }
                    if let why = bill.whyHousing {
                        Label(bill.isIndirect ? "Indirect: \(why)" : why, systemImage: "house")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }

            ourWork
            comingUp
            tasks
            stakeholders
            related
            versions
            votes
            sponsors
            meetings
            prepAndOutreach

            Section {
                DisclosureGroup("Timeline (\(bill.timeline.count))") {
                    ForEach(Array(bill.timeline.reversed().enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateText.pretty(item.date)).font(.caption).foregroundStyle(.secondary)
                            Text(item.text ?? "").font(.subheadline)
                        }
                    }
                }
                let entries = workspace.journal(for: bill)
                DisclosureGroup("Activity journal (\(entries.count))") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.text).font(.subheadline)
                        }
                    }
                }
            }

            Section {
                if let url = bill.url { Link("View full bill on legis.ga.gov", destination: url) }
            } footer: { SourceLine() }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(bill.displayNumber)
        .toolbar {
            ShareLink(item: shareText) { Image(systemName: "square.and.arrow.up") }
        }
        .sheet(isPresented: $showTask) { TaskEditor(bill: bill) }
        .sheet(isPresented: $showStakeholder) { StakeholderEditor(bill: bill) }
        .sheet(isPresented: $showRelated) { RelatedPicker(bill: bill) }
        .sheet(isPresented: $showMeeting) { MeetingEditor(bills: [bill]) }
        .sheet(item: $calendarEvent) { event in CalendarEventSheet(bill: bill, event: event) }
        .sheet(item: $prepSheet) { file in ShareSheet(url: file.url) }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name, like Property tax", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let folder = workspace.addFolder(folderName) {
                    workspace.toggle(bill, in: folder)
                    store.star(bill)
                }
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Georgia · \(bill.displayNumber) · \(bill.year)")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    OutcomeDot(bill: bill)
                    Text(bill.displayHeadline).font(.title3.weight(.semibold))
                }
                HStack(spacing: 8) {
                    Tag(text: bill.status)
                    if let committee = bill.committee { Tag(text: committee) }
                    if work.priority { Tag(text: "🚩 High priority") }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Star, priority, position, task and folder in one row.
    private var quickActions: some View {
        Section {
            HStack {
                QuickButton(title: starred ? "Watching" : "Watch", icon: starred ? "star.fill" : "star", tint: .yellow) {
                    store.toggleStar(bill)
                    if store.starred.contains(bill.id) { workspace.startAmendmentWatch(bill) }
                }
                QuickButton(title: "Priority", icon: work.priority ? "flag.fill" : "flag", tint: .red) {
                    workspace.setPriority(bill, !work.priority)
                    if work.priority {
                        store.star(bill)
                        workspace.startAmendmentWatch(bill)
                    }
                }
                Menu {
                    ForEach(Position.allCases, id: \.self) { p in
                        Button("\(p.rawValue) (approved)") { workspace.setPosition(bill, p, approved: true); store.star(bill) }
                    }
                    Menu("Propose for approval") {
                        ForEach(Position.allCases, id: \.self) { p in
                            Button(p.rawValue) { workspace.setPosition(bill, p, approved: false); store.star(bill) }
                        }
                    }
                    if work.position != nil {
                        Button("Clear position", role: .destructive) { workspace.setPosition(bill, nil, approved: false) }
                    }
                } label: {
                    QuickLabel(title: work.position?.rawValue ?? "Position", icon: "hand.raised", tint: .blue)
                }
                QuickButton(title: "Task", icon: "checklist", tint: .purple) { showTask = true }
                Menu {
                    FolderButtons(bill: bill)
                    Divider()
                    Button("New folder…", systemImage: "folder.badge.plus") { folderName = ""; showNewFolder = true }
                } label: {
                    QuickLabel(title: "Folder", icon: "folder", tint: .teal)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var ourWork: some View {
        Section("Our work") {
            if let position = work.position {
                HStack {
                    Text("Position")
                    Spacer()
                    PositionTag(position: position, approved: work.positionApproved)
                    if !work.positionApproved {
                        Button("Approve") { workspace.approvePosition(bill) }
                            .buttonStyle(.borderless)
                    }
                }
                TextField("Why we hold this position", text: workspace.binding(bill, \.positionReason), axis: .vertical)
            }
            LabeledField(label: "Assigned to", text: workspace.binding(bill, \.assignedTo), prompt: "Name or team")
            LabeledField(label: "Next action", text: workspace.binding(bill, \.nextAction), prompt: "What happens next")
            TextField("My notes…", text: workspace.binding(bill, \.note), axis: .vertical)
                .lineLimit(2...12)
        }
    }

    @ViewBuilder private var comingUp: some View {
        if !bill.upcoming.isEmpty {
            Section("Coming up") {
                ForEach(bill.upcoming, id: \.self) { next in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(DateText.pretty(next.date))\(next.time.map { " at \($0)" } ?? "")")
                                .font(.headline)
                            Text([next.what, next.`where`].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { calendarEvent = next } label: { Image(systemName: "calendar.badge.plus") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add to calendar")
                    }
                }
            }
        }
    }

    private var tasks: some View {
        Section {
            ForEach(workspace.tasks(for: bill)) { task in TaskRow(task: task) }
            Button("Add a task", systemImage: "plus") { showTask = true }
        } header: { Text("Tasks") }
    }

    private var stakeholders: some View {
        Section {
            ForEach(work.stakeholders) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(s.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(s.stance).font(.caption.weight(.bold))
                            .foregroundStyle(s.stance == "Support" ? Color.green : s.stance == "Oppose" ? Color.red : Color.secondary)
                    }
                    Text(s.confirmed ? "Public position" : "What we've heard").font(.caption).foregroundStyle(.secondary)
                    if !s.note.isEmpty { Text(s.note).font(.caption) }
                }
            }
            .onDelete { idx in workspace.update(bill) { $0.stakeholders.remove(atOffsets: idx) } }
            Button("Add an organization", systemImage: "plus") { showStakeholder = true }
        } header: { Text("Who supports or opposes") }
    }

    private var related: some View {
        Section {
            ForEach(work.related) { r in
                if let other = store.bill(id: r.billId) {
                    NavigationLink(value: other) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.kind): \(other.displayNumber)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(other.displayHeadline).font(.subheadline).lineLimit(2)
                        }
                    }
                }
            }
            .onDelete { idx in workspace.update(bill) { $0.related.remove(atOffsets: idx) } }
            Button("Link a related bill", systemImage: "link") { showRelated = true }
        } header: { Text("Related bills") }
    }

    @ViewBuilder private var versions: some View {
        if !bill.versions.isEmpty {
            Section {
                if workspace.needsReview(bill) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("New version to review", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange).font(.subheadline.weight(.semibold))
                        if !work.watchSections.isEmpty {
                            Text("Check: \(work.watchSections)").font(.caption)
                        }
                        Button("Mark reviewed") { workspace.markReviewed(bill) }.buttonStyle(.borderless)
                    }
                }
                ForEach(bill.versions.reversed()) { v in
                    HStack {
                        Text(v.name).font(.subheadline)
                        Spacer()
                        Text(DateText.pretty(v.date)).font(.caption).foregroundStyle(.secondary)
                        if let s = v.url, let url = URL(string: s) {
                            Link(destination: url) { Image(systemName: "doc.text") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if bill.versions.count > 1 {
                    NavigationLink("Compare versions") { DiffView(bill: bill) }
                }
                TextField("Sections to watch, like Section 3 or 44-7-50", text: workspace.binding(bill, \.watchSections), axis: .vertical)
                    .font(.subheadline)
            } header: { Text("Versions (\(bill.versions.count))") }
        }
    }

    @ViewBuilder private var votes: some View {
        if !bill.allVotes.isEmpty {
            Section("Votes") {
                ForEach(bill.allVotes) { v in
                    NavigationLink { VoteDetailView(bill: bill, roll: v) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(v.chamber ?? "") · \(DateText.pretty(v.date))").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text((v.passed ?? false) ? "Passed" : "Failed")
                                    .font(.caption.weight(.bold)).foregroundStyle((v.passed ?? false) ? Color.green : Color.red)
                            }
                            Text(v.desc ?? "Vote").font(.subheadline)
                            Text("Yes \(v.yea ?? 0) · No \(v.nay ?? 0) · Not voting \(v.nv ?? 0) · Absent \(v.absent ?? 0)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var sponsors: some View {
        if !bill.allSponsors.isEmpty {
            Section("Sponsors") {
                ForEach(Array(bill.allSponsors.enumerated()), id: \.offset) { _, s in
                    if let person = store.person(id: s.id) {
                        NavigationLink(value: person) { SponsorRow(sponsor: s) }
                    } else {
                        SponsorRow(sponsor: s)
                    }
                }
            }
        }
    }

    private var meetings: some View {
        Section {
            ForEach(workspace.meetings(for: bill)) { m in MeetingRow(meeting: m) }
            Button("Log a meeting about this bill", systemImage: "person.2") { showMeeting = true }
        } header: { Text("Meetings") }
    }

    private var prepAndOutreach: some View {
        Section("Prep and outreach") {
            DisclosureGroup("Talking points and questions") {
                TextField("Key talking points", text: workspace.binding(bill, \.talkingPoints), axis: .vertical)
                    .lineLimit(3...12)
                TextField("Questions for the hearing", text: workspace.binding(bill, \.questions), axis: .vertical)
                    .lineLimit(2...10)
            }
            Button("Hearing prep sheet (PDF)", systemImage: "doc.richtext") {
                prepSheet = PDFMaker.make(html: Briefing.prepSheet(bill: bill, work: work, store: store, workspace: workspace),
                                          name: "\(bill.number) prep sheet").map(SharedFile.init)
            }
            NavigationLink { MemberActionView(bill: bill) } label: {
                Label("Member action email", systemImage: "envelope")
            }
        }
    }

    private var shareText: String {
        var parts = ["\(bill.displayNumber): \(bill.displayHeadline)", "Status: \(bill.status)"]
        if let recap = bill.recap { parts.append(recap) }
        if let link = bill.link { parts.append(link) }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Small pieces

struct QuickButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) { QuickLabel(title: title, icon: icon, tint: tint) }
    }
}

struct QuickLabel: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.primary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct LabeledField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            TextField(prompt, text: $text).multilineTextAlignment(.trailing)
        }
    }
}

struct SponsorRow: View {
    let sponsor: Sponsor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(sponsor.name ?? "Unknown")\((sponsor.primary ?? false) ? " (primary)" : "")").font(.subheadline)
            Text([sponsor.chamber, sponsor.district.map { "District \($0)" }, sponsor.party].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Filed → Committee → Passed 1st chamber → 2nd chamber → Passed both → Governor → Law.
struct ProgressTracker: View {
    let stage: BillStage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(BillStage.steps.indices, id: \.self) { i in
                    Circle()
                        .fill(color(i))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if i == stage.reached { Circle().stroke(Color.primary, lineWidth: 2).frame(width: 20, height: 20) }
                        }
                    if i < BillStage.steps.count - 1 {
                        Rectangle().fill(i < stage.reached ? color(i) : Color.secondary.opacity(0.25)).frame(height: 3)
                    }
                }
            }
            .padding(.horizontal, 4)
            HStack {
                Text(BillStage.steps[stage.reached]).font(.subheadline.weight(.semibold))
                if stage.stopped { Text("· stopped here").font(.subheadline).foregroundStyle(.red) }
            }
            Text("Steps: " + BillStage.steps.joined(separator: " → ")).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func color(_ i: Int) -> Color {
        if i > stage.reached { return Color.secondary.opacity(0.25) }
        if stage.stopped && i == stage.reached { return .red }
        return .green
    }
}

/// How every legislator voted on one roll call.
struct VoteDetailView: View {
    @EnvironmentObject var store: BillStore
    let bill: Bill
    let roll: VoteSummary

    var body: some View {
        List {
            Section {
                Text(roll.desc ?? "Vote").font(.headline)
                Text("\(roll.chamber ?? "") · \(DateText.pretty(roll.date))").foregroundStyle(.secondary)
                Text("Yes \(roll.yea ?? 0) · No \(roll.nay ?? 0) · Not voting \(roll.nv ?? 0) · Absent \(roll.absent ?? 0)")
            }
            let groups = store.breakdown(of: roll)
            if groups.isEmpty {
                Section {
                    Text(store.votes == nil ? "Loading…" : "Legislator-by-legislator votes aren't loaded for this bill yet. They're added for housing bills over the next few updates.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section("\(group.label) (\(group.people.count))") {
                    ForEach(group.people) { p in
                        NavigationLink(value: p) {
                            VStack(alignment: .leading) {
                                Text(p.displayName)
                                Text(p.line).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(bill.displayNumber)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadVotes() }
    }
}

/// What changed between versions, with removed words in red and added words in green.
struct DiffView: View {
    @EnvironmentObject var store: BillStore
    let bill: Bill
    @State private var pairs: [DiffPair]?

    var body: some View {
        List {
            if let pairs {
                if pairs.isEmpty {
                    Text("This comparison isn't ready yet. Comparisons are added for housing bills over the next few updates. You can open each version from the bill page.")
                        .foregroundStyle(.secondary)
                }
                ForEach(pairs.reversed()) { pair in
                    Section {
                        Text(attributed(pair)).font(.callout)
                    } header: {
                        Text("\(pair.from ?? "Earlier") → \(pair.to ?? "Later") (\(pair.changes) changes)")
                    } footer: {
                        Text("\(DateText.pretty(pair.fromDate)) → \(DateText.pretty(pair.toDate)). Red is removed, green is added.")
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("What changed")
        .navigationBarTitleDisplayMode(.inline)
        .task { pairs = await store.diffs(for: bill) }
    }

    private func attributed(_ pair: DiffPair) -> AttributedString {
        var out = AttributedString()
        for piece in pair.pieces where piece.count == 2 {
            var part = AttributedString(piece[1] + " ")
            switch piece[0] {
            case "+":
                part.foregroundColor = Color.green
                part.backgroundColor = Color.green.opacity(0.12)
            case "-":
                part.foregroundColor = Color.red
                part.backgroundColor = Color.red.opacity(0.12)
            case "…":
                part = AttributedString("\n[\(piece[1])]\n")
                part.foregroundColor = Color.secondary
            default:
                break
            }
            out += part
        }
        return out
    }
}
