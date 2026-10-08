import Foundation

/// Parses how long to wait after an HTTP 429 response.
enum RetryAfter {
    /// Reads the `Retry-After` header (case-insensitively) and falls back to
    /// Discord's JSON `retry_after` field.
    static func delay(from response: HTTPURLResponse, body: Data?, now: Date = Date()) -> TimeInterval? {
        delay(headerValue: response.value(forHTTPHeaderField: "Retry-After"), body: body, now: now)
    }

    /// Returns a non-negative number of seconds, or `nil` if nothing usable was found.
    ///
    /// The header may be delta-seconds (`"2"`, `"0.75"`) or an HTTP date.
    static func delay(headerValue: String?, body: Data?, now: Date = Date()) -> TimeInterval? {
        if let raw = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
                return seconds
            }
            if let date = httpDate(from: raw) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return bodyRetryAfter(body)
    }

    private static func bodyRetryAfter(_ body: Data?) -> TimeInterval? {
        guard let body, !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let number = object["retry_after"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let seconds = number.doubleValue
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    private static func httpDate(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}
