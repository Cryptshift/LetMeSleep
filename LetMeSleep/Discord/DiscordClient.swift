import Foundation

/// The bit of `URLSession` the Discord client needs, so tests can fake it.
protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTransport: HTTPTransport {
    var session: URLSession = .shared

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum DiscordError: LocalizedError, Equatable {
    case missingToken
    case invalidUserID
    case unauthorized
    case cannotMessageUser
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, message: String?)
    case invalidResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Add your Discord bot token in Settings."
        case .invalidUserID:
            "Add the recipient's Discord user ID (numbers only) in Settings."
        case .unauthorized:
            "Discord rejected the bot token. Check it in Settings."
        case .cannotMessageUser:
            "Discord won't let the bot DM this user. The bot must share a server with them, and they must allow DMs from server members."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Discord is rate limiting the bot. Try again in \(Int(retryAfter.rounded(.up))) s."
            } else {
                "Discord is rate limiting the bot. Try again later."
            }
        case .http(let status, let message):
            "Discord returned HTTP \(status)\(message.map { ": \($0)" } ?? "")."
        case .invalidResponse:
            "Got an unexpected response from Discord."
        case .transport(let description):
            "Couldn't reach Discord: \(description)"
        }
    }
}

/// Sends a DM from a Discord bot to one user via the REST API.
///
/// The DM channel ID is cached per bot token + user, so each alert is a single
/// request. 429 responses are retried a limited number of times.
actor DiscordClient {
    static let apiBase = URL(string: "https://discord.com/api/v10")!

    private let transport: any HTTPTransport
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    let maxRetries: Int
    let maxRetryDelay: TimeInterval
    /// Used when a 429 has no usable Retry-After.
    let fallbackRetryDelay: TimeInterval

    private var cachedChannel: (key: String, channelID: String)?

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        maxRetries: Int = 2,
        maxRetryDelay: TimeInterval = 30,
        fallbackRetryDelay: TimeInterval = 2,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.maxRetries = maxRetries
        self.maxRetryDelay = maxRetryDelay
        self.fallbackRetryDelay = fallbackRetryDelay
        self.sleep = sleep
    }

    func sendDirectMessage(_ content: String, botToken: String, userID: String) async throws {
        let token = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw DiscordError.missingToken }
        guard !user.isEmpty, user.allSatisfy(\.isASCII), user.allSatisfy(\.isNumber) else {
            throw DiscordError.invalidUserID
        }

        let key = "\(user)|\(token)"
        let wasCached = cachedChannel?.key == key
        let channelID = try await dmChannelID(userID: user, token: token, cacheKey: key)
        do {
            try await postMessage(content, channelID: channelID, token: token)
        } catch DiscordError.http(status: 404, _) where wasCached {
            // The cached channel is gone; open a fresh one once.
            cachedChannel = nil
            let freshID = try await dmChannelID(userID: user, token: token, cacheKey: key)
            try await postMessage(content, channelID: freshID, token: token)
        }
    }

    private func dmChannelID(userID: String, token: String, cacheKey: String) async throws -> String {
        if let cachedChannel, cachedChannel.key == cacheKey {
            return cachedChannel.channelID
        }
        let request = try makeRequest(path: "users/@me/channels", token: token, body: ["recipient_id": userID])
        let data = try await perform(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channelID = object["id"] as? String, !channelID.isEmpty
        else { throw DiscordError.invalidResponse }
        cachedChannel = (cacheKey, channelID)
        return channelID
    }

    private func postMessage(_ content: String, channelID: String, token: String) async throws {
        let request = try makeRequest(
            path: "channels/\(channelID)/messages",
            token: token,
            body: ["content": content, "allowed_mentions": ["parse": [String]()]]
        )
        _ = try await perform(request)
    }

    private func makeRequest(path: String, token: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: Self.apiBase.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("LetMeSleep (https://github.com/Cryptshift/LetMeSleep, 1.0)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        var retries = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DiscordError.transport(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw DiscordError.invalidResponse }

            switch http.statusCode {
            case 200..<300:
                return data
            case 429:
                let delay = RetryAfter.delay(from: http, body: data)
                let wait = delay ?? fallbackRetryDelay
                guard retries < maxRetries, wait <= maxRetryDelay else {
                    throw DiscordError.rateLimited(retryAfter: delay)
                }
                retries += 1
                try await sleep(wait)
            case 401:
                throw DiscordError.unauthorized
            case 403 where Self.discordErrorCode(in: data) == 50007:
                throw DiscordError.cannotMessageUser
            default:
                throw DiscordError.http(status: http.statusCode, message: Self.discordErrorMessage(in: data))
            }
        }
    }

    private static func discordErrorCode(in data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? Int
    }

    private static func discordErrorMessage(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }
}
