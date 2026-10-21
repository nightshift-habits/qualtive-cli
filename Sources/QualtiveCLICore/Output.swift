import Foundation

public enum Output {
    /// Left-aligned columns separated by two spaces, header first.
    public static func table(headers: [String], rows: [[String]]) -> String {
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return ([headers] + rows).map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
        }
        .joined(separator: "\n")
    }

    /// Re-serializes API JSON with stable formatting, keeping every field the server returned.
    public static func prettyJSON(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try prettyJSON(object: object)
    }

    public static func prettyJSON(object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// `yyyy-MM-dd HH:mm` in UTC.
    public static func timestamp(unixSeconds: UInt64) -> String {
        timestamp(Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    public static func timestamp(_ date: Date) -> String {
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0,
            components.hour ?? 0, components.minute ?? 0
        )
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

public enum StandardError {
    public static func write(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
