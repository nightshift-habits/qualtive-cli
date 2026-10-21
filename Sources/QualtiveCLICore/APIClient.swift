import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public struct APIResponse: Sendable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw CLIError("Unexpected response from the Qualtive API: \(error)")
        }
    }
}

/// Thin AsyncHTTPClient wrapper for the admin API (`pAdminApi`).
public struct APIClient: Sendable {
    public let baseURL: String
    let httpClient: HTTPClient
    static let timeout: TimeAmount = .seconds(30)
    static let maxBodyBytes = 16 * 1024 * 1024

    public init(baseURL: String, httpClient: HTTPClient = .shared) {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = trimmed
        self.httpClient = httpClient
    }

    /// Sends a request and throws `APIError` for non-2xx responses.
    public func send(
        _ method: HTTPMethod,
        _ path: String,
        headers: [(String, String)] = [],
        body: Data? = nil
    ) async throws -> APIResponse {
        let response = try await sendRaw(method, path, headers: headers, body: body)
        guard (200 ..< 300).contains(response.status) else {
            throw APIError(response: response)
        }
        return response
    }

    public func sendRaw(
        _ method: HTTPMethod,
        _ path: String,
        headers: [(String, String)] = [],
        body: Data? = nil
    ) async throws -> APIResponse {
        var request = HTTPClientRequest(url: baseURL + path)
        request.method = method
        request.headers.add(name: "User-Agent", value: QualtiveVersion.userAgent)
        request.headers.add(name: "Accept", value: "application/json")
        for (name, value) in headers {
            request.headers.add(name: name, value: value)
        }
        if let body {
            request.body = .bytes(ByteBuffer(bytes: body))
        }
        do {
            let response = try await httpClient.execute(request, timeout: Self.timeout)
            let buffer = try await response.body.collect(upTo: Self.maxBodyBytes)
            return APIResponse(status: Int(response.status.code), headers: response.headers, body: Data(buffer.readableBytesView))
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError("Could not reach \(baseURL): \(error)", exitStatus: .network)
        }
    }

    /// `POST /oauth/token` with a form-encoded body. Throws `OAuthError` on RFC 6749 error responses.
    public func token(_ parameters: [(String, String)]) async throws -> TokenResponse {
        let response = try await sendRaw(
            .POST,
            "/oauth/token",
            headers: [("Content-Type", "application/x-www-form-urlencoded")],
            body: Data(FormEncoding.encode(parameters).utf8)
        )
        guard response.status == 200 else {
            if let error = try? JSONDecoder().decode(OAuthErrorResponse.self, from: response.body) {
                throw OAuthError(status: response.status, response: error)
            }
            throw APIError(response: response)
        }
        return try response.decode(TokenResponse.self)
    }
}

public struct APIError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var reason: String?

    init(response: APIResponse) {
        status = response.status
        reason = (try? JSONDecoder().decode(APIErrorResponse.self, from: response.body))?.reason
    }

    public var description: String {
        if let reason { return "The Qualtive API returned \(status) (\(reason))." }
        return "The Qualtive API returned HTTP \(status)."
    }

    public var cliError: CLIError {
        switch (status, reason) {
        case (_, "InvalidAccessToken"?), (_, "InvalidAPIKey"?), (_, "AuthorizationMissing"?), (401, _):
            return CLIError(description, hint: "Run `qualtive auth login`.", exitStatus: .notAuthenticated)
        case (_, "ContainerMissing"?), (_, "MissingContainer"?):
            return CLIError(description, hint: "Pass --container <id> or run `qualtive containers use <id>`.", exitStatus: .usage)
        case (_, "UnauthorizedContainer"?):
            return CLIError(description, hint: "Check the container with `qualtive containers list`.", exitStatus: .forbidden)
        case (_, "InsufficientPermissions"?), (403, _):
            return CLIError(description, exitStatus: .forbidden)
        case (404, _):
            return CLIError(description, exitStatus: .notFound)
        default:
            return CLIError(description)
        }
    }
}

public struct OAuthError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var response: OAuthErrorResponse

    public var description: String {
        let detail = response.errorDescription.map { ": \($0)" } ?? ""
        return "Token request failed (\(response.error))\(detail)"
    }

    public var cliError: CLIError {
        switch response.error {
        case "invalid_grant", "invalid_client":
            return CLIError(description, hint: "Run `qualtive auth login` again.", exitStatus: .notAuthenticated)
        default:
            return CLIError(description)
        }
    }
}

enum FormEncoding {
    static func encode(_ parameters: [(String, String)]) -> String {
        parameters.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters pass through; everything else is percent-encoded.
    static func escape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
