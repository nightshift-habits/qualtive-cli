import Foundation

public struct StoredCredentials: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case oauth
        case apiKey = "api_key"
    }

    public var kind: Kind
    public var accessToken: String?
    public var accessExpiresAt: Date?
    public var refreshToken: String?
    public var apiKey: String?
    public var container: String?
    public var user: String?
    public var apiURL: String

    public init(
        kind: Kind,
        accessToken: String? = nil,
        accessExpiresAt: Date? = nil,
        refreshToken: String? = nil,
        apiKey: String? = nil,
        container: String? = nil,
        user: String? = nil,
        apiURL: String
    ) {
        self.kind = kind
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken
        self.apiKey = apiKey
        self.container = container
        self.user = user
        self.apiURL = apiURL
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case accessToken = "access_token"
        case accessExpiresAt = "access_expires_at"
        case refreshToken = "refresh_token"
        case apiKey = "api_key"
        case container
        case user
        case apiURL = "api_url"
    }

    public static func oauth(_ token: TokenResponse, apiURL: String, now: Date = Date()) -> StoredCredentials {
        StoredCredentials(
            kind: .oauth,
            accessToken: token.accessToken,
            accessExpiresAt: Date(timeIntervalSince1970: (now.timeIntervalSince1970 + TimeInterval(token.expiresIn)).rounded(.down)),
            refreshToken: token.refreshToken,
            container: token.container,
            user: JWT.claims(token.accessToken).flatMap(JWT.userDescription),
            apiURL: apiURL
        )
    }

    /// True when the access token is missing or has less than `margin` seconds left.
    public func accessTokenNeedsRefresh(now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard kind == .oauth else { return false }
        guard accessToken != nil, let expiresAt = accessExpiresAt else { return true }
        return expiresAt.timeIntervalSince(now) < margin
    }

    /// The bearer token sent to the API.
    public var bearerToken: String? {
        kind == .apiKey ? apiKey : accessToken
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
