import Foundation

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
    let jurisdiction: String          // "Federal" or "Georgia"
    let number: String
    let title: String
    let sponsor: String?
    let status: String
    let lastAction: String?
    let lastActionDate: String?
    let timeline: [TimelineItem]
    let versions: [BillVersion]
    let upcoming: [Upcoming]
    let link: String?
    let headline: String?
    let recap: String?
    let impact: String?
    let changeKind: String?           // new, amended, status, action, hearing
    let updatedAt: String?

    var displayHeadline: String { headline ?? title }

    var isGeorgia: Bool { jurisdiction == "Georgia" }

    var url: URL? { link.flatMap(URL.init(string:)) }

    var changeLabel: String? {
        switch changeKind {
        case "new": return "New"
        case "amended": return "Amended"
        case "status": return "Status changed"
        case "hearing": return "Hearing scheduled"
        case "action": return "Updated"
        default: return nil
        }
    }

    /// The fields that, when they change, deserve an alert on a starred bill.
    var alertFingerprint: String {
        "\(status)|\(versions.count)|\(upcoming.first?.date ?? "")"
    }

    var shareText: String {
        var parts = ["\(jurisdiction) \(number): \(displayHeadline)", "Status: \(status)"]
        if let recap { parts.append(recap) }
        if let link { parts.append(link) }
        return parts.joined(separator: "\n\n")
    }
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
    let changes: String?
}

struct Upcoming: Codable, Hashable {
    let date: String?
    let time: String?
    let what: String?
    let `where`: String?
}

enum DateText {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func pretty(_ s: String?) -> String {
        guard let s, let d = iso.date(from: String(s.prefix(10))) else { return s ?? "" }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
