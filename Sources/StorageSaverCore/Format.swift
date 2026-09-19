import Foundation

public enum Format {
    /// Decimal units, matching Finder ("12.3 GB").
    public static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(n)
        var i = 0
        while value >= 1000 && i < units.count - 1 { value /= 1000; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[i])
    }

    public static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    public static func date(_ d: Date?) -> String {
        guard let d else { return "never" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        f.timeZone = .current
        return f.string(from: d)
    }
}

/// Messages stores dates as nanoseconds since 2001-01-01 (older databases used
/// seconds). Values below 1e12 are treated as seconds.
public enum AppleDate {
    public static let epochOffset: TimeInterval = 978_307_200

    public static func date(fromDB raw: Int64) -> Date {
        let seconds = raw < 1_000_000_000_000 ? TimeInterval(raw) : TimeInterval(raw) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + epochOffset)
    }

    /// Nanoseconds-since-2001 for `date`, the unit modern databases use.
    public static func dbNanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - epochOffset) * 1_000_000_000)
    }
}
