import SwiftUI

struct BillDetailView: View {
    @EnvironmentObject var store: BillStore
    let bill: Bill
    @State private var askingNewFolder = false
    @State private var folderName = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Georgia · \(bill.number) · \(bill.year)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        OutcomeDot(bill: bill)
                        Text(bill.displayHeadline).font(.title3.weight(.semibold))
                    }
                    HStack(spacing: 8) {
                        Tag(text: bill.status)
                        if let impact = bill.impact { Tag(text: impact) }
                    }
                }
                .padding(.vertical, 4)
            }

            if let recap = bill.recap {
                Section("Summary") { Text(recap) }
            }

            if let why = bill.whyHousing {
                Section(bill.isIndirect ? "How it affects housing (indirectly)" : "How it affects housing") {
                    Text(why)
                }
            }

            if let next = bill.upcoming.first {
                Section("Coming up") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(DateText.pretty(next.date))\(next.time.map { " at \($0)" } ?? "")")
                            .font(.headline)
                        Text([next.what, next.`where`].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }

            if !bill.versions.isEmpty {
                Section("What changed") {
                    ForEach(bill.versions.reversed()) { v in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(v.name) · \(DateText.pretty(v.date))").font(.subheadline.weight(.semibold))
                            if let changes = v.changes { Text(changes).font(.subheadline) }
                            if let s = v.url, let url = URL(string: s) {
                                Link("Read this version", destination: url).font(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !bill.timeline.isEmpty {
                Section("Timeline") {
                    ForEach(Array(bill.timeline.reversed().enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateText.pretty(item.date)).font(.caption).foregroundStyle(.secondary)
                            Text(item.text ?? "").font(.subheadline)
                        }
                    }
                }
            }

            if let url = bill.url {
                Section { Link("View full bill", destination: url) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("New folder", isPresented: $askingNewFolder) {
            TextField("Name, like Property tax", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let folder = store.addFolder(folderName) { store.toggle(bill, in: folder) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: bill.shareText) { Image(systemName: "square.and.arrow.up") }
                Menu {
                    FolderButtons(bill: bill)
                    Divider()
                    Button("New folder…", systemImage: "folder.badge.plus") { folderName = ""; askingNewFolder = true }
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Folders")
                Button { store.toggleStar(bill) } label: {
                    Image(systemName: store.starred.contains(bill.id) ? "star.fill" : "star")
                }
                .accessibilityLabel(store.starred.contains(bill.id) ? "Stop watching" : "Watch")
            }
        }
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}
