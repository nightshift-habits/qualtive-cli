import Crypto
import Foundation

public enum OAuth {
    public static let clientID = "qualtive-cli"

    public struct PKCE: Sendable, Equatable {
        public var verifier: String
        public var challenge: String

        /// 32 random bytes → a 43-character base64url verifier (RFC 7636 §4.1).
        public static func generate() -> PKCE {
            var generator = SystemRandomNumberGenerator()
            let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            return PKCE(verifier: Base64URL.encode(bytes))
        }

        public init(verifier: String) {
            self.verifier = verifier
            challenge = Base64URL.encode(Array(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    public static func randomState() -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode((0 ..< 16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func redirectURI(port: Int) -> String {
        "http://127.0.0.1:\(port)/callback"
    }

    public static func authorizeURL(
        apiURL: String,
        redirectURI: String,
        pkce: PKCE,
        state: String,
        container: String?
    ) -> String {
        var parameters = [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        if let container {
            parameters.append(("container", container))
        }
        var base = apiURL
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/oauth/authorize?" + FormEncoding.encode(parameters)
    }

    public static func exchangeCode(
        _ code: String,
        pkce: PKCE,
        redirectURI: String,
        client: APIClient
    ) async throws -> TokenResponse {
        try await client.token([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", pkce.verifier),
            ("redirect_uri", redirectURI),
        ])
    }

    public static func refresh(
        _ refreshToken: String,
        container: String? = nil,
        client: APIClient
    ) async throws -> TokenResponse {
        var parameters = [
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
        ]
        if let container {
            parameters.append(("container", container))
        }
        return try await client.token(parameters)
    }
}
