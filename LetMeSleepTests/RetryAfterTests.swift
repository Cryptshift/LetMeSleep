import Foundation
import Testing
@testable import LetMeSleep

struct RetryAfterTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000) // Tue, 14 Nov 2023 22:13:20 GMT

    func response(headers: [String: String]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: URL(string: "https://discord.com/api/v10/x")!,
            statusCode: 429,
            httpVersion: "HTTP/2",
            headerFields: headers
        ))
    }

    @Test(arguments: [
        ("2", 2.0),
        ("0.75", 0.75),
        (" 3 ", 3.0),
        ("0", 0.0),
    ])
    func parsesDeltaSeconds(header: String, expected: TimeInterval) {
        #expect(RetryAfter.delay(headerValue: header, body: nil, now: now) == expected)
    }

    @Test(arguments: ["retry-after", "Retry-After", "RETRY-AFTER"])
    func headerLookupIsCaseInsensitive(name: String) throws {
        let response = try response(headers: [name: "4"])
        #expect(RetryAfter.delay(from: response, body: nil, now: now) == 4)
    }

    @Test(arguments: ["soon", "-1", "nan", "inf", ""])
    func rejectsUnusableHeaders(header: String) {
        #expect(RetryAfter.delay(headerValue: header, body: nil, now: now) == nil)
    }

    @Test func fallsBackToDiscordJSONBody() {
        let body = Data(#"{"message": "You are being rate limited.", "retry_after": 1.5, "global": false}"#.utf8)
        #expect(RetryAfter.delay(headerValue: nil, body: body, now: now) == 1.5)
        #expect(RetryAfter.delay(headerValue: "garbage", body: body, now: now) == 1.5)
    }

    @Test func headerWinsOverBody() {
        let body = Data(#"{"retry_after": 9}"#.utf8)
        #expect(RetryAfter.delay(headerValue: "2", body: body, now: now) == 2)
    }

    @Test func ignoresBadBodies() {
        #expect(RetryAfter.delay(headerValue: nil, body: Data("not json".utf8), now: now) == nil)
        #expect(RetryAfter.delay(headerValue: nil, body: Data(#"{"retry_after": true}"#.utf8), now: now) == nil)
        #expect(RetryAfter.delay(headerValue: nil, body: Data(#"{"retry_after": -3}"#.utf8), now: now) == nil)
        #expect(RetryAfter.delay(headerValue: nil, body: Data(), now: now) == nil)
    }

    @Test func parsesHTTPDates() {
        #expect(RetryAfter.delay(headerValue: "Tue, 14 Nov 2023 22:13:30 GMT", body: nil, now: now) == 10)
        // A date in the past means "retry now".
        #expect(RetryAfter.delay(headerValue: "Tue, 14 Nov 2023 22:13:00 GMT", body: nil, now: now) == 0)
    }
}
