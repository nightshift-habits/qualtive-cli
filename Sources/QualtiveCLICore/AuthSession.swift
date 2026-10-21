import Foundation
import NIOHTTP1

/// Resolves which credentials and container a command uses, refreshes access tokens,
/// and sends authorized admin API requests.
///
/// Precedence: `QUALTIVE_API_KEY` > stored credentials. Container: `--container` >
/// `QUALTIVE_CONTAINER` > the stored credentials' container > `config.json`.
public actor AuthSession {
    public static let defaultProfile = "default"

    public nonisolated let environment: CLIEnvironment
    public nonisolated let store: any CredentialStore
    public nonisolated let profile: String
    private let containerOverride: String?
    private let apiURLOverride: String?
    private let now: @Sendable () -> Date

    private var config: Config
    private var credentials: StoredCredentials?
    private var credentialsSource: CredentialsSource = .none
    /// Set when `--container` differs from the token's container: an in-memory token pair for that container.
    private var switchedCredentials: StoredCredentials?

    public enum CredentialsSource: Sendable, Equatable {
        case none
        case environment
        case store
    }

    public init(
        environment: CLIEnvironment,
        store: any CredentialStore,
        profile: String = AuthSession.defaultProfile,
        containerOverride: String? = nil,
        apiURLOverride: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.environment = environment
        self.store = store
        self.profile = profile
        self.containerOverride = containerOverride ?? environment.container
        self.apiURLOverride = apiURLOverride
        self.now = now
        let config = try Config.load(from: environment)
        self.config = config

        if let apiKey = environment.apiKey {
            let apiURL = apiURLOverride ?? environment.apiURL ?? config.apiURL ?? CLIEnvironment.defaultAPIURL
            credentials = StoredCredentials(kind: .apiKey, apiKey: apiKey, apiURL: apiURL)
            credentialsSource = .environment
        } else if let stored = try store.load(profile: profile) {
            credentials = stored
            credentialsSource = .store
        }
    }

    // MARK: - Resolution

    public var source: CredentialsSource { credentialsSource }
    public var currentCredentials: StoredCredentials? { credentials }

    /// The API URL: `--api-url` > `QUALTIVE_API_URL` > stored credentials > `config.json` > production.
    public var apiURL: String {
        apiURLOverride ?? environment.apiURL ?? credentials?.apiURL ?? config.apiURL ?? CLIEnvironment.defaultAPIURL
    }

    public var client: APIClient { APIClient(baseURL: apiURL) }

    public var container: String? {
        containerOverride ?? credentials?.container ?? config.container
    }

    public func requireCredentials() throws -> StoredCredentials {
        guard let credentials else { throw CLIError.notLoggedIn() }
        return credentials
    }

    // MARK: - Requests

    /// Sends an authorized request. `X-Container` is added when `includeContainer` is true and a container is known.
    /// A `401 InvalidAccessToken` triggers one refresh and retry for OAuth credentials.
    public func send(_ method: HTTPMethod, _ path: String, includeContainer: Bool = true) async throws -> APIResponse {
        var forceRefresh = false
        while true {
            let token = try await validBearerToken(forceRefresh: forceRefresh)
            var headers = [("Authorization", "Bearer \(token)")]
            if includeContainer {
                guard let container = try await containerResolvingKeyContainer(token: token) else {
                    throw CLIError(
                        "No container selected.",
                        hint: "Pass --container <id> or run `qualtive containers use <id>`.",
                        exitStatus: .usage
                    )
                }
                headers.append(("X-Container", container))
            } else if credentials?.kind == .apiKey, let container {
                // `u-` user API keys pick their container from the header, even on `GET /containers`.
                headers.append(("X-Container", container))
            }
            let response = try await client.sendRaw(method, path, headers: headers)
            if (200 ..< 300).contains(response.status) {
                return response
            }
            let error = APIError(response: response)
            if error.status == 401, error.reason == "InvalidAccessToken", activeCredentials?.kind == .oauth, !forceRefresh {
                forceRefresh = true
                continue
            }
            throw error.cliError
        }
    }

    /// A bearer token valid for at least 60 more seconds, refreshing (and persisting) when needed.
    public func validBearerToken(forceRefresh: Bool = false) async throws -> String {
        let credentials = try requireCredentials()
        switch credentials.kind {
        case .apiKey:
            guard let key = credentials.apiKey else { throw CLIError.notLoggedIn() }
            return key
        case .oauth:
            if let containerOverride, containerOverride != credentials.container {
                return try await switchedAccessToken(to: containerOverride, forceRefresh: forceRefresh)
            }
            if forceRefresh || credentials.accessTokenNeedsRefresh(now: now()) {
                try await refreshStoredCredentials(container: nil, force: forceRefresh)
            }
            guard let token = self.credentials?.accessToken else { throw CLIError.notLoggedIn() }
            return token
        }
    }

    /// Refreshes the stored OAuth credentials, optionally switching container, and persists the new pair.
    /// Holds a file lock and re-reads the store so concurrent CLI processes don't refresh twice.
    @discardableResult
    public func refreshStoredCredentials(container newContainer: String?, force: Bool = true) async throws -> StoredCredentials {
        let lock = try FileLock(url: environment.configDirectory.appendingPathComponent(".credentials.lock"))
        defer { withExtendedLifetime(lock) {} }

        guard credentialsSource == .store, var current = try store.load(profile: profile) ?? credentials else {
            throw CLIError.notLoggedIn()
        }
        guard current.kind == .oauth, let refreshToken = current.refreshToken else {
            throw CLIError("API key credentials cannot be refreshed.", exitStatus: .usage)
        }
        if newContainer == nil, !force, current != credentials, !current.accessTokenNeedsRefresh(now: now()) {
            credentials = current
            return current
        }
        let client = APIClient(baseURL: apiURLOverride ?? environment.apiURL ?? current.apiURL)
        let token: TokenResponse
        do {
            token = try await OAuth.refresh(refreshToken, container: newContainer, client: client)
        } catch let error as OAuthError {
            throw error.cliError
        } catch let error as APIError {
            throw error.cliError
        }
        current = .oauth(token, apiURL: current.apiURL, now: now())
        try store.save(current, profile: profile)
        credentials = current
        return current
    }

    /// `c-` container keys belong to exactly one container, which `GET /containers` returns without `X-Container`.
    private func containerResolvingKeyContainer(token: String) async throws -> String? {
        if let container { return container }
        guard credentials?.kind == .apiKey, token.hasPrefix("c-") else { return nil }
        let response = try await client.send(.GET, "/containers", headers: [("Authorization", "Bearer \(token)")])
        let containers = try response.decode([Container].self)
        guard containers.count == 1 else { return nil }
        credentials?.container = containers[0].id
        return containers[0].id
    }

    private var activeCredentials: StoredCredentials? {
        switchedCredentials ?? credentials
    }

    private func switchedAccessToken(to container: String, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let switched = switchedCredentials, !switched.accessTokenNeedsRefresh(now: now()),
           let token = switched.accessToken {
            return token
        }
        guard let refreshToken = credentials?.refreshToken else { throw CLIError.notLoggedIn() }
        do {
            let token = try await OAuth.refresh(refreshToken, container: container, client: client)
            switchedCredentials = .oauth(token, apiURL: apiURL, now: now())
            return token.accessToken
        } catch let error as OAuthError {
            throw error.cliError
        } catch let error as APIError {
            throw error.cliError
        }
    }

    // MARK: - Persistence

    public func saveCredentials(_ new: StoredCredentials) throws {
        try store.save(new, profile: profile)
        credentials = new
        credentialsSource = .store
    }

    public func deleteCredentials() throws -> Bool {
        let existed = try store.load(profile: profile) != nil
        try store.delete(profile: profile)
        if credentialsSource == .store {
            credentials = nil
            credentialsSource = .none
        }
        return existed
    }

    public func setDefaultContainer(_ container: String?) throws {
        config.container = container
        try config.save(to: environment)
    }
}
