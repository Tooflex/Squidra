/// Squidra's bounded timestamp wire profile. Gregorian years 0001...9999,
/// explicit known offsets, 0...9 fractional digits and no leap seconds.
/// Output is UTC with six fractional digits, rounded to microseconds.
/// UTCInstant uses Double; precision can be coarser at distant dates.
public enum RFC3339 {
    public enum ValidationError: Error, Equatable, Sendable { case invalidTimestamp }

    public static func parse(_ text: String) throws -> UTCInstant {
        guard (20...35).contains(text.utf8.count) else { throw ValidationError.invalidTimestamp }
        let b = Array(text.utf8)
        func number(_ start: Int, _ count: Int) throws -> Int {
            guard start + count <= b.count else { throw ValidationError.invalidTimestamp }
            var result = 0
            for c in b[start..<(start + count)] {
                guard (48...57).contains(c) else { throw ValidationError.invalidTimestamp }
                result = result * 10 + Int(c - 48)
            }
            return result
        }
        guard b[4] == 45, b[7] == 45, [84,116].contains(b[10]),
              b[13] == 58, b[16] == 58 else { throw ValidationError.invalidTimestamp }
        let year = try number(0,4), month = try number(5,2), day = try number(8,2)
        let hour = try number(11,2), minute = try number(14,2), second = try number(17,2)
        guard year >= 1, (1...12).contains(month), (1...daysInMonth(year,month)).contains(day),
              hour < 24, minute < 60, second < 60 else { throw ValidationError.invalidTimestamp }
        var i = 19, fraction = 0.0
        if b[i] == 46 {
            i += 1
            let start = i
            var scale = 1.0
            while i < b.count, (48...57).contains(b[i]) {
                guard i - start < 9 else { throw ValidationError.invalidTimestamp }
                scale *= 10; fraction += Double(b[i] - 48) / scale; i += 1
            }
            guard i > start else { throw ValidationError.invalidTimestamp }
        }
        guard i < b.count else { throw ValidationError.invalidTimestamp }
        var offset = 0
        if [90,122].contains(b[i]) {
            guard i + 1 == b.count else { throw ValidationError.invalidTimestamp }
        } else {
            guard [43,45].contains(b[i]), i + 6 == b.count, b[i+3] == 58 else {
                throw ValidationError.invalidTimestamp
            }
            let hours = try number(i+1,2), minutes = try number(i+4,2)
            guard hours < 24, minutes < 60, !(b[i] == 45 && hours == 0 && minutes == 0) else {
                throw ValidationError.invalidTimestamp
            }
            offset = (hours * 3600 + minutes * 60) * (b[i] == 45 ? -1 : 1)
        }
        var ordinal = daysBeforeYear(year) + day - 1
        for m in 1..<month { ordinal += daysInMonth(year,m) }
        let seconds = (ordinal - 719162) * 86400 + hour * 3600 + minute * 60 + second - offset
        do { return try UTCInstant(secondsSince1970: Double(seconds) + fraction) }
        catch { throw ValidationError.invalidTimestamp }
    }

    public static func format(_ instant: UTCInstant) throws -> String {
        let rounded = (instant.secondsSince1970 * 1_000_000).rounded()
        guard rounded >= -62_135_596_800_000_000, rounded < 253_402_300_800_000_000 else {
            throw ValidationError.invalidTimestamp
        }
        let micros = Int64(rounded)
        var seconds = micros / 1_000_000, fraction = micros % 1_000_000
        if fraction < 0 { seconds -= 1; fraction += 1_000_000 }
        var days = seconds / 86400, daytime = seconds % 86400
        if daytime < 0 { days -= 1; daytime += 86400 }
        let ordinal = Int(days) + 719162
        var low = 1, high = 10000
        while low + 1 < high {
            let middle = (low + high) / 2
            if daysBeforeYear(middle) <= ordinal { low = middle } else { high = middle }
        }
        let year = low
        var day = ordinal - daysBeforeYear(year), month = 1
        while day >= daysInMonth(year,month) { day -= daysInMonth(year,month); month += 1 }
        func padded(_ value: Int, _ width: Int) -> String {
            let value = String(value)
            return String(repeating: "0", count: width - value.count) + value
        }
        return padded(year,4) + "-" + padded(month,2) + "-" + padded(day+1,2)
            + "T" + padded(Int(daytime/3600),2) + ":" + padded(Int(daytime/60%60),2)
            + ":" + padded(Int(daytime%60),2) + "." + padded(Int(fraction),6) + "Z"
    }

    private static func daysBeforeYear(_ year: Int) -> Int {
        let y = year - 1
        return 365*y + y/4 - y/100 + y/400
    }
    private static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        if month == 2 { return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28 }
        return [4,6,9,11].contains(month) ? 30 : 31
    }
}
