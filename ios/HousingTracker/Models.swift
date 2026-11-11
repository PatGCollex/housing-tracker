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
    let relevance: String?            // "Direct" or "Indirect"
    let whyHousing: String?
    let changeKind: String?           // new, amended, status, action, hearing
    let updatedAt: String?

    var displayHeadline: String { headline ?? title }

    var isGeorgia: Bool { jurisdiction == "Georgia" }

    var isIndirect: Bool { relevance == "Indirect" }

    var isLaw: Bool { status == "Signed into law" }

    /// Date used to put the most recent bills first.
    var sortDate: String { lastActionDate ?? updatedAt ?? "" }

    /// "House bill", "Senate bill" or "Resolution", from the bill number (HB 12, S 45, H.Res. 3...).
    var billType: String {
        let letters = number.uppercased().filter { $0.isLetter }
        if isGeorgia {
            return letters == "HB" ? "House bill" : letters == "SB" ? "Senate bill" : "Resolution"
        }
        return letters == "HR" ? "House bill" : letters == "S" ? "Senate bill" : "Resolution"
    }

    /// Year the bill was introduced, for the Watching dropdowns.
    var year: String {
        String((timeline.first?.date ?? lastActionDate ?? updatedAt ?? "").prefix(4))
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

    /// Simple status groups for filtering.
    var statusGroup: String {
        switch status {
        case "Signed into law": return "Became law"
        case "Vetoed", "Failed": return "Stopped"
        case "Introduced", "In committee": return "Introduced"
        default: return "Moving"
        }
    }

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
        "\(status)|\(versions.count)|\(timeline.count)|\(upcoming.first?.date ?? "")"
    }

    var shareText: String {
        var parts = ["\(jurisdiction) \(number): \(displayHeadline)", "Status: \(status)"]
        if let recap { parts.append(recap) }
        if let link { parts.append(link) }
        return parts.joined(separator: "\n\n")
    }
}

/// A folder the user makes on Watching, such as "Property tax" or "Rentals".
struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var billIds: [String] = []
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
