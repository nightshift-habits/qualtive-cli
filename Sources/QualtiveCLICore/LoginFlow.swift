import Foundation
import NIOCore

public enum LoginFlow {
    /// Authorization code + PKCE with a loopback redirect to `127.0.0.1:<port>/callback`.
    public static func browserLogin(
        session: AuthSession,
        container: String?,
        openBrowser: Bool,
        timeout: TimeAmount = .minutes(5),
        opener: @Sendable (String) -> Bool = Browser.open,
        log: @Sendable (String) -> Void = StandardError.write
    ) async throws -> StoredCredentials {
        let apiURL = await session.apiURL
        let pkce = OAuth.PKCE.generate()
        let state = OAuth.randomState()
        let server = try await OAuthCallbackServer.start(expectedState: state)
        let url = OAuth.authorizeURL(
            apiURL: apiURL,
            redirectURI: server.redirectURI,
            pkce: pkce,
            state: state,
            container: container
        )

        if openBrowser, opener(url) {
            log("Opening your browser to log in. If it doesn't open, visit:\n\n  \(url)\n")
        } else {
            log("Open this URL in a browser on this machine to log in:\n\n  \(url)\n")
        }
        log("Waiting for the browser login (press Ctrl-C to cancel)…")

        let result = try await server.waitForCode(timeout: timeout)
        let token: TokenResponse
        do {
            token = try await OAuth.exchangeCode(
                result.code,
                pkce: pkce,
                redirectURI: server.redirectURI,
                client: APIClient(baseURL: apiURL)
            )
        } catch let error as OAuthError {
            throw error.cliError
        } catch let error as APIError {
            throw error.cliError
        }
        let credentials = StoredCredentials.oauth(token, apiURL: apiURL)
        try await session.saveCredentials(credentials)
        try await session.setDefaultContainer(token.container)
        return credentials
    }

    /// Validates an API key with `GET /containers` and stores it. `u-` keys need a container for most calls.
    public static func apiKeyLogin(
        session: AuthSession,
        apiKey rawKey: String,
        container: String?,
        log: @Sendable (String) -> Void = StandardError.write
    ) async throws -> StoredCredentials {
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw CLIError("No API key given on standard input.", exitStatus: .usage)
        }
        if !apiKey.hasPrefix("u-"), !apiKey.hasPrefix("c-") {
            log("Warning: Qualtive API keys normally start with \"u-\" or \"c-\".")
        }
        let apiURL = await session.apiURL
        var headers = [("Authorization", "Bearer \(apiKey)")]
        if let container {
            headers.append(("X-Container", container))
        }
        let response = try await APIClient(baseURL: apiURL).sendRaw(.GET, "/containers", headers: headers)
        var resolvedContainer = container
        if (200 ..< 300).contains(response.status) {
            if resolvedContainer == nil, apiKey.hasPrefix("c-"),
               let containers = try? JSONDecoder().decode([Container].self, from: response.body),
               containers.count == 1 {
                resolvedContainer = containers[0].id
            }
        } else {
            let error = APIError(response: response)
            if response.status == 401 || response.status == 403 {
                throw error.cliError
            }
            log("Warning: could not verify the API key (\(error.description)). Saving it anyway.")
        }
        if apiKey.hasPrefix("u-"), resolvedContainer == nil {
            log("Note: user API keys need a container. Pass --container or run `qualtive containers use <id>`.")
        }
        let credentials = StoredCredentials(kind: .apiKey, apiKey: apiKey, container: resolvedContainer, apiURL: apiURL)
        try await session.saveCredentials(credentials)
        if let resolvedContainer {
            try await session.setDefaultContainer(resolvedContainer)
        }
        return credentials
    }
}
