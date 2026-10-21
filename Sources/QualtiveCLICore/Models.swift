import Foundation

/// `POST /oauth/token` success body.
public struct TokenResponse: Decodable, Equatable, Sendable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: Int
    public var refreshToken: String
    public var container: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case container
    }
}

/// `POST /oauth/token` error body (RFC 6749 §5.2).
public struct OAuthErrorResponse: Decodable, Equatable, Sendable {
    public var error: String
    public var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// Admin API error body: `{ "reason": "InvalidAccessToken" | … }`.
public struct APIErrorResponse: Decodable, Equatable, Sendable {
    public var reason: String
}

/// An entry of `GET /containers`. Decoded leniently: only `id` is required.
public struct Container: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var version: String?

    public init(id: String, name: String? = nil, version: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case version
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .id) {
            id = string
        } else {
            id = String(try container.decode(Int64.self, forKey: .id))
        }
        name = (try? container.decodeIfPresent(String.self, forKey: .name))
            ?? (try? container.decodeIfPresent(String.self, forKey: .title))
        version = try? container.decodeIfPresent(String.self, forKey: .version)
    }
}

/// An entry of `GET /feedback/categories`. Timestamps are Unix seconds.
public struct Category: Decodable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var questionsCounter: UInt32
    public var updated: UInt64
    public var created: UInt64

    public init(id: Int64, name: String, questionsCounter: UInt32, updated: UInt64, created: UInt64) {
        self.id = id
        self.name = name
        self.questionsCounter = questionsCounter
        self.updated = updated
        self.created = created
    }
}
