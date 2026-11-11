import SwiftUI

/// Capitol mode: big buttons for people on the move, countdowns, hearings, the session calendar and legislators.
struct CapitolTab: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @State private var showMeeting = false
    @State private var showDeadline = false
    @State private var showFloor = false
    @State private var showMeetingMode = false
    @State private var showTasks = false

    /// Hearings and votes in the next 14 days on bills you watch.
    private var hearings: [(Bill, Upcoming)] {
        let today = DateText.daysAgo(0)
        let limit = DateText.string(Date(timeIntervalSinceNow: 14 * 24 * 60 * 60))
        return store.watching
            .flatMap { bill in bill.upcoming.map { (bill, $0) } }
            .filter { ($0.1.date ?? "") >= today && ($0.1.date ?? "") <= limit }
            .sorted { ($0.1.date ?? "") < ($1.1.date ?? "") }
    }

    private var countdowns: [(String, Date)] {
        let today = Calendar.current.startOfDay(for: Date())
        let milestones = (store.calendar?.milestones ?? []).compactMap { m in DateText.date(m.date).map { (m.title, $0) } }
        let mine = workspace.upcomingDeadlines.map { ($0.title, $0.date) }
        return (milestones + mine).filter { $0.1 >= today }.sorted { $0.1 < $1.1 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        Button { showFloor = true } label: { BigButton(title: "Floor note", icon: "square.and.pencil", tint: .blue) }
                        Button { showMeeting = true } label: { BigButton(title: "Log meeting", icon: "person.2.fill", tint: .green) }
                        Button { showMeetingMode = true } label: { BigButton(title: "Meeting mode", icon: "person.crop.rectangle", tint: .orange) }
                        Button { showTasks = true } label: { BigButton(title: "Tasks (\(workspace.openTasks.count))", icon: "checklist", tint: .purple) }
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(Array(countdowns.prefix(6).enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.0)
                            Spacer()
                            Text(daysText(item.1)).font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                        }
                    }
                    Button("Add a deadline", systemImage: "plus") { showDeadline = true }
                } header: { Text("Countdown") }

                Section("Hearings and votes, next 2 weeks") {
                    if hearings.isEmpty {
                        Text("None scheduled for bills you watch.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(hearings.enumerated()), id: \.offset) { _, item in
                        NavigationLink(value: item.0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(DateText.pretty(item.1.date))\(item.1.time.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                                Text("\(item.0.displayNumber): \(item.1.what ?? "Hearing")").font(.subheadline.weight(.semibold))
                                if let place = item.1.`where` { Text(place).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink { SessionCalendarView() } label: { Label("Session calendar", systemImage: "calendar") }
                    NavigationLink { LegislatorsView(meetingMode: false) } label: { Label("Legislators", systemImage: "person.3") }
                    if let url = URL(string: "https://openstates.org/find_your_legislator/") {
                        Link(destination: url) { Label("Find legislators by address", systemImage: "map") }
                    }
                    if let url = URL(string: "https://www.legis.ga.gov/") {
                        Link(destination: url) { Label("Georgia General Assembly website", systemImage: "safari") }
                    }
                }
            }
            .navigationTitle("Capitol")
            .navigationDestination(isPresented: $showFloor) { FloorNotesView() }
            .navigationDestination(isPresented: $showMeetingMode) { LegislatorsView(meetingMode: true) }
            .navigationDestination(isPresented: $showTasks) { ActionQueueView() }
            .sheet(isPresented: $showMeeting) { MeetingEditor() }
            .sheet(isPresented: $showDeadline) { DeadlineEditor() }
            .appDestinations()
            .refreshable { await store.refresh() }
        }
    }

    private func daysText(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "\(days) days"
        }
    }
}

struct BigButton: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(tint.gradient, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Session calendar

/// A month view. Blue days are session days, orange are committee days, a dot means a hearing on a bill you watch.
struct SessionCalendarView: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selected: Date?
    @State private var addEvent: CalendarItem?

    private let cal = Calendar.current

    private var days: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let firstWeekday = cal.component(.weekday, from: month) - 1
        let lead: [Date?] = Array(repeating: nil, count: firstWeekday)
        let monthDays: [Date?] = range.map { cal.date(byAdding: .day, value: $0 - 1, to: month) }
        return lead + monthDays
    }

    private func items(on day: Date) -> [CalendarItem] {
        let key = DateText.string(day)
        var out: [CalendarItem] = []
        for d in store.calendar?.days ?? [] where d.date == key {
            out.append(CalendarItem(title: d.label ?? (d.kind == "session" ? "Session day" : "Committee day"), date: day, kind: d.kind))
        }
        for m in store.calendar?.milestones ?? [] where m.date == key {
            out.append(CalendarItem(title: m.title, date: day, kind: "milestone"))
        }
        for bill in store.watching {
            for u in bill.upcoming where u.date == key {
                out.append(CalendarItem(title: "\(bill.displayNumber): \(u.what ?? "Hearing")", date: CalendarEventSheet.combine(u.date, u.time) ?? day,
                                        kind: "hearing", detail: u.`where`, billId: bill.id))
            }
        }
        for d in workspace.data.deadlines where cal.isDate(d.date, inSameDayAs: day) {
            out.append(CalendarItem(title: d.title, date: day, kind: "deadline"))
        }
        return out
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 6) {
                    ForEach(["S", "M", "T", "W", "T", "F", "S"].indices, id: \.self) { i in
                        Text(["S", "M", "T", "W", "T", "F", "S"][i]).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day)
                        } else {
                            Color.clear.frame(height: 36)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Legend(color: .blue, text: "Session")
                    Legend(color: .orange, text: "Committee")
                    Legend(color: .red, text: "Hearing")
                }
                .font(.caption2)
            } footer: {
                Text("Session and committee days are added once the legislature sets its schedule.")
            }

            if let selected {
                let list = items(on: selected)
                Section(selected.formatted(date: .complete, time: .omitted)) {
                    if list.isEmpty { Text("Nothing scheduled.").foregroundStyle(.secondary) }
                    ForEach(list) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline)
                                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button { addEvent = item } label: { Image(systemName: "calendar.badge.plus") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Add to my calendar")
                        }
                    }
                }
            }
        }
        .navigationTitle("Session calendar")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $addEvent) { item in CalendarEventSheet(title: item.title, date: item.date, notes: item.detail) }
    }

    private func dayCell(_ day: Date) -> some View {
        let list = items(on: day)
        let kinds = Set(list.map(\.kind))
        let fill: Color = kinds.contains("session") ? .blue : kinds.contains("committee") ? .orange : .clear
        let isSelected = selected.map { cal.isDate($0, inSameDayAs: day) } ?? false
        return Button { selected = day } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.subheadline)
                    .foregroundStyle(fill == .clear ? Color.primary : Color.white)
                    .frame(width: 30, height: 30)
                    .background(fill, in: Circle())
                    .overlay { if isSelected { Circle().stroke(Color.accentColor, lineWidth: 2) } }
                Circle().fill(kinds.contains("hearing") || kinds.contains("deadline") || kinds.contains("milestone") ? Color.red : Color.clear)
                    .frame(width: 5, height: 5)
            }
        }
        .buttonStyle(.borderless)
    }

    private func shift(_ months: Int) {
        if let d = cal.date(byAdding: .month, value: months, to: month) { month = d }
        selected = nil
    }
}

struct CalendarItem: Identifiable {
    let id = UUID()
    let title: String
    let date: Date
    let kind: String
    var detail: String? = nil
    var billId: String? = nil
}

struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

// MARK: - Legislators

struct LegislatorsView: View {
    @EnvironmentObject var store: BillStore
    let meetingMode: Bool
    @State private var query = ""
    @State private var chamber = "All"

    private var shown: [Person] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return store.people.filter { p in
            (chamber == "All" || p.chamber == chamber) &&
            (q.isEmpty || p.displayName.lowercased().contains(q) || p.district == q || (p.party ?? "").lowercased() == q
             || "district \(p.district ?? "")" == q)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Chamber", selection: $chamber) {
                    Text("All").tag("All")
                    Text("House").tag("House")
                    Text("Senate").tag("Senate")
                }
                .pickerStyle(.segmented)
            } footer: {
                if meetingMode { Text("Pick who you're meeting. You'll see their bills, your positions, past meetings and open tasks.") }
            }
            ForEach(shown) { p in
                NavigationLink(value: p) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.title) \(p.displayName)")
                        Text(p.line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay { EmptyMessage(text: store.people.isEmpty ? "Legislators load after the next data update." : nil) }
        .searchable(text: $query, prompt: "Name, district number or party")
        .navigationTitle(meetingMode ? "Meeting mode" : "Legislators")
    }
}

/// Everything about one legislator, ready for a meeting.
struct LegislatorView: View {
    @EnvironmentObject var store: BillStore
    @EnvironmentObject var workspace: Workspace
    let person: Person
    @State private var showMeeting = false

    var body: some View {
        let sponsored = store.sponsored(by: person)
        let trackedSponsored = sponsored.filter { store.starred.contains($0.id) || $0.isHousing }
        let starredWithVotes = store.watching.filter { !$0.allVotes.isEmpty }
        let meetings = workspace.meetings(with: person)
        let billIds = Set(trackedSponsored.map(\.id))
        let tasks = workspace.openTasks.filter { task in task.billId.map { billIds.contains($0) } ?? false }

        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(person.title) \(person.displayName)").font(.title3.weight(.semibold))
                    Text(person.line).foregroundStyle(.secondary)
                }
                Button("Log a meeting", systemImage: "person.2") { showMeeting = true }
                if let name = person.ballotpedia, let url = URL(string: "https://ballotpedia.org/\(name)") {
                    Link(destination: url) { Label("Profile on Ballotpedia", systemImage: "person.text.rectangle") }
                }
                if let url = URL(string: "https://www.legis.ga.gov/members/\(person.chamber == "Senate" ? "senate" : "house")") {
                    Link(destination: url) { Label("Contact info on legis.ga.gov", systemImage: "phone") }
                }
            }

            Section("Housing and watched bills they sponsor (\(trackedSponsored.count))") {
                if trackedSponsored.isEmpty { Text("None.").foregroundStyle(.secondary) }
                ForEach(trackedSponsored) { bill in NavigationLink(value: bill) { BillRow(bill: bill) } }
            }

            if !tasks.isEmpty {
                Section("Open tasks on their bills") {
                    ForEach(tasks) { task in TaskRow(task: task, showBill: true) }
                }
            }

            Section("Past meetings (\(meetings.count))") {
                if meetings.isEmpty { Text("No meetings logged yet.").foregroundStyle(.secondary) }
                ForEach(meetings) { m in MeetingRow(meeting: m) }
            }

            if !starredWithVotes.isEmpty {
                Section("How they voted on bills you watch") {
                    ForEach(starredWithVotes) { bill in
                        ForEach(bill.allVotes) { roll in
                            if let vote = store.vote(of: person, on: roll) {
                                NavigationLink(value: bill) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(bill.displayNumber).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                            Text(roll.desc ?? "Vote").font(.subheadline).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(vote).font(.subheadline.weight(.bold))
                                            .foregroundStyle(vote == "Yes" ? Color.green : vote == "No" ? Color.red : Color.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if sponsored.count > trackedSponsored.count {
                Section {
                    DisclosureGroup("All bills they sponsor (\(sponsored.count))") {
                        ForEach(sponsored) { bill in NavigationLink(value: bill) { BillRow(bill: bill) } }
                    }
                }
            }
        }
        .navigationTitle(person.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMeeting) { MeetingEditor(bills: trackedSponsored.filter { store.starred.contains($0.id) }, person: person) }
        .task { await store.loadVotes() }
    }
}
