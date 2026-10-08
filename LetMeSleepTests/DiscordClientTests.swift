import Foundation
import Testing
@testable import LetMeSleep

/// Replays canned responses instead of touching the network.
actor FakeTransport: HTTPTransport {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body = "{}"
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var paths: [String] {
        requests.compactMap { $0.url?.path() }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty, let url = request.url else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            throw URLError(.badServerResponse)
        }
        return (Data(reply.body.utf8), response)
    }
}

actor SleepLog {
    private(set) var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }
}

struct DiscordClientTests {
    let token = "test-token"
    let user = "123456789012345678"
    let openChannel = FakeTransport.Reply(status: 200, body: #"{"id": "42"}"#)
    let sent = FakeTransport.Reply(status: 200)

    func makeClient(_ transport: FakeTransport, log: SleepLog = SleepLog()) -> DiscordClient {
        DiscordClient(transport: transport, maxRetries: 2, maxRetryDelay: 30, fallbackRetryDelay: 2) { delay in
            await log.record(delay)
        }
    }

    @Test func cachesTheDMChannel() async throws {
        let transport = FakeTransport([openChannel, sent, sent])
        let client = makeClient(transport)

        try await client.sendDirectMessage("one", botToken: token, userID: user)
        try await client.sendDirectMessage("two", botToken: token, userID: user)

        #expect(await transport.paths == [
            "/api/v10/users/@me/channels",
            "/api/v10/channels/42/messages",
            "/api/v10/channels/42/messages",
        ])
        let first = try #require(await transport.requests.first)
        #expect(first.httpMethod == "POST")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bot test-token")
        let body = try #require(first.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["recipient_id"] as? String == user)
    }

    @Test func retriesAfterRateLimitThenSucceeds() async throws {
        let transport = FakeTransport([
            openChannel,
            .init(status: 429, headers: ["retry-after": "1.5"]),
            sent,
        ])
        let log = SleepLog()
        try await makeClient(transport, log: log).sendDirectMessage("hi", botToken: token, userID: user)
        #expect(await log.delays == [1.5])
        #expect(await transport.requests.count == 3)
    }

    @Test func givesUpAfterMaxRetries() async throws {
        let limited = FakeTransport.Reply(status: 429, headers: ["Retry-After": "1"])
        let transport = FakeTransport([openChannel, limited, limited, limited, sent])
        let log = SleepLog()
        await #expect(throws: DiscordError.rateLimited(retryAfter: 1)) {
            try await makeClient(transport, log: log).sendDirectMessage("hi", botToken: token, userID: user)
        }
        #expect(await log.delays == [1, 1])
        #expect(await transport.requests.count == 4) // channel + 1 try + 2 retries
    }

    @Test func doesNotWaitForAbsurdRetryAfter() async throws {
        let transport = FakeTransport([openChannel, .init(status: 429, headers: ["Retry-After": "3600"])])
        let log = SleepLog()
        await #expect(throws: DiscordError.rateLimited(retryAfter: 3600)) {
            try await makeClient(transport, log: log).sendDirectMessage("hi", botToken: token, userID: user)
        }
        #expect(await log.delays.isEmpty)
    }

    @Test func usesFallbackDelayWhenRetryAfterIsMissing() async throws {
        let transport = FakeTransport([openChannel, .init(status: 429), sent])
        let log = SleepLog()
        try await makeClient(transport, log: log).sendDirectMessage("hi", botToken: token, userID: user)
        #expect(await log.delays == [2])
    }

    @Test func reopensChannelOnceIfCachedChannelIsGone() async throws {
        let transport = FakeTransport([
            openChannel, sent,
            .init(status: 404, body: #"{"message": "Unknown Channel", "code": 10003}"#),
            .init(status: 200, body: #"{"id": "77"}"#),
            sent,
        ])
        let client = makeClient(transport)
        try await client.sendDirectMessage("one", botToken: token, userID: user)
        try await client.sendDirectMessage("two", botToken: token, userID: user)
        #expect(await transport.paths == [
            "/api/v10/users/@me/channels",
            "/api/v10/channels/42/messages",
            "/api/v10/channels/42/messages",
            "/api/v10/users/@me/channels",
            "/api/v10/channels/77/messages",
        ])
    }

    @Test func validatesInputBeforeAnyRequest() async throws {
        let transport = FakeTransport([])
        let client = makeClient(transport)
        await #expect(throws: DiscordError.missingToken) {
            try await client.sendDirectMessage("hi", botToken: "  ", userID: user)
        }
        await #expect(throws: DiscordError.invalidUserID) {
            try await client.sendDirectMessage("hi", botToken: token, userID: "FIND USING DEVELOPER MODE")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func mapsCommonDiscordErrors() async throws {
        await #expect(throws: DiscordError.unauthorized) {
            try await makeClient(FakeTransport([.init(status: 401)]))
                .sendDirectMessage("hi", botToken: token, userID: user)
        }
        await #expect(throws: DiscordError.cannotMessageUser) {
            try await makeClient(FakeTransport([
                openChannel,
                .init(status: 403, body: #"{"message": "Cannot send messages to this user", "code": 50007}"#),
            ]))
            .sendDirectMessage("hi", botToken: token, userID: user)
        }
        await #expect(throws: DiscordError.http(status: 500, message: "oops")) {
            try await makeClient(FakeTransport([.init(status: 500, body: #"{"message": "oops"}"#)]))
                .sendDirectMessage("hi", botToken: token, userID: user)
        }
    }
}
