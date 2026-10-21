import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import QualtiveCLICore

@Suite struct AuthSessionTests {
    let directory = TestSupport.temporaryDirectory()
    var store: FileCredentialStore { FileCredentialStore(directory: directory) }

    func environment(_ variables: [String: String] = [:]) -> CLIEnvironment {
        CLIEnvironment(variables: variables, configDirectory: directory)
    }

    func storedOAuth(apiURL: String, expiresIn: TimeInterval, container: String = "acme") -> StoredCredentials {
        StoredCredentials(
            kind: .oauth,
            accessToken: "old-access",
            accessExpiresAt: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + expiresIn).rounded()),
            refreshToken: "refresh-1",
            container: container,
            apiURL: apiURL
        )
    }

    @Test func expiringAccessTokenIsRefreshedAndPersisted() async throws {
        let server = try await MockAPIServer { request in
            switch request.path {
            case "/oauth/token":
                return .json(TestSupport.tokenJSON(access: "new-access", refresh: "refresh-2", container: "acme"))
            case "/feedback/categories":
                return .json(#"[{"id":1,"name":"Bugs","questionsCounter":3,"updated":1700000000,"created":1600000000}]"#)
            default:
                return .json(#"{"reason":"NotFound"}"#, status: .notFound)
            }
        }
        defer { Task { await server.shutdown() } }
        try store.save(storedOAuth(apiURL: server.url, expiresIn: 30), profile: "default")

        let session = try AuthSession(environment: environment(), store: store)
        let response = try await session.send(.GET, "/feedback/categories")
        #expect(try response.decode([QualtiveCLICore.Category].self).first?.name == "Bugs")

        let requests = server.requests
        #expect(requests.map(\.path) == ["/oauth/token", "/feedback/categories"])
        #expect(requests[0].headers.first(name: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(requests[0].form == ["grant_type": "refresh_token", "client_id": "qualtive-cli", "refresh_token": "refresh-1"])
        #expect(requests[1].headers.first(name: "Authorization") == "Bearer new-access")
        #expect(requests[1].headers.first(name: "X-Container") == "acme")
        #expect(requests[1].headers.first(name: "User-Agent")?.hasPrefix("qualtive-cli/") == true)

        let saved = try #require(try store.load(profile: "default"))
        #expect(saved.accessToken == "new-access")
        #expect(saved.refreshToken == "refresh-2")
    }

    @Test func invalidAccessTokenTriggersOneRefreshAndRetry() async throws {
        let server = try await MockAPIServer { request in
            if request.path == "/oauth/token" {
                return .json(TestSupport.tokenJSON(access: "fresh", refresh: "refresh-2", container: "acme"))
            }
            if request.headers.first(name: "Authorization") == "Bearer fresh" {
                return .json("[]")
            }
            return .json(#"{"reason":"InvalidAccessToken"}"#, status: .unauthorized)
        }
        defer { Task { await server.shutdown() } }
        try store.save(storedOAuth(apiURL: server.url, expiresIn: 1000), profile: "default")

        let session = try AuthSession(environment: environment(), store: store)
        _ = try await session.send(.GET, "/feedback/categories")
        #expect(server.requests.map(\.path) == ["/feedback/categories", "/oauth/token", "/feedback/categories"])
    }

    @Test func containersListOmitsXContainerForOAuth() async throws {
        let server = try await MockAPIServer { _ in .json(#"[{"id":"acme","name":"Acme"}]"#) }
        defer { Task { await server.shutdown() } }
        try store.save(storedOAuth(apiURL: server.url, expiresIn: 1000), profile: "default")

        let session = try AuthSession(environment: environment(), store: store)
        _ = try await session.send(.GET, "/containers", includeContainer: false)
        #expect(server.requests.first?.headers.first(name: "X-Container") == nil)
        #expect(server.requests.first?.headers.first(name: "Authorization") == "Bearer old-access")
    }

    @Test func containerSwitchRefreshesWithContainerAndPersists() async throws {
        let server = try await MockAPIServer { request in
            .json(TestSupport.tokenJSON(access: "beta-access", refresh: "beta-refresh", container: request.form["container"] ?? "?"))
        }
        defer { Task { await server.shutdown() } }
        try store.save(storedOAuth(apiURL: server.url, expiresIn: 1000), profile: "default")

        let session = try AuthSession(environment: environment(), store: store)
        let updated = try await session.refreshStoredCredentials(container: "beta")
        try await session.setDefaultContainer(updated.container)

        #expect(server.requests.first?.form["container"] == "beta")
        #expect(try store.load(profile: "default")?.container == "beta")
        #expect(try Config.load(from: environment()).container == "beta")
        #expect(await session.container == "beta")
    }

    @Test func containerOverrideUsesAnInMemoryTokenForThatContainer() async throws {
        let server = try await MockAPIServer { request in
            if request.path == "/oauth/token" {
                return .json(TestSupport.tokenJSON(access: "other-access", refresh: "other-refresh", container: "other"))
            }
            return .json("[]")
        }
        defer { Task { await server.shutdown() } }
        let original = storedOAuth(apiURL: server.url, expiresIn: 1000)
        try store.save(original, profile: "default")

        let session = try AuthSession(environment: environment(), store: store, containerOverride: "other")
        _ = try await session.send(.GET, "/feedback/categories")
        let requests = server.requests
        #expect(requests[0].form["container"] == "other")
        #expect(requests[1].headers.first(name: "Authorization") == "Bearer other-access")
        #expect(requests[1].headers.first(name: "X-Container") == "other")
        #expect(try store.load(profile: "default") == original)
    }

    @Test func environmentAPIKeyWinsAndSendsContainerHeader() async throws {
        let server = try await MockAPIServer { _ in .json("[]") }
        defer { Task { await server.shutdown() } }
        try store.save(storedOAuth(apiURL: server.url, expiresIn: 1000), profile: "default")

        let session = try AuthSession(
            environment: environment(["QUALTIVE_API_KEY": "u-key", "QUALTIVE_CONTAINER": "envco"]),
            store: store,
            apiURLOverride: server.url
        )
        #expect(await session.source == .environment)
        _ = try await session.send(.GET, "/containers", includeContainer: false)
        _ = try await session.send(.GET, "/feedback/categories")
        for request in server.requests {
            #expect(request.headers.first(name: "Authorization") == "Bearer u-key")
            #expect(request.headers.first(name: "X-Container") == "envco")
        }
    }

    @Test func invalidGrantOnRefreshMeansNotAuthenticated() async throws {
        let server = try await MockAPIServer { _ in
            .json(#"{"error":"invalid_grant","error_description":"expired"}"#, status: .badRequest)
        }
        defer { Task { await server.shutdown() } }
        try store.save(storedOAuth(apiURL: server.url, expiresIn: -10), profile: "default")

        let session = try AuthSession(environment: environment(), store: store)
        do {
            _ = try await session.validBearerToken()
            Issue.record("expected an error")
        } catch let error as CLIError {
            #expect(error.exitStatus == .notAuthenticated)
        }
    }

    @Test func noCredentialsMeansNotLoggedIn() async throws {
        let session = try AuthSession(environment: environment(), store: store)
        await #expect(throws: CLIError.self) { try await session.send(.GET, "/containers", includeContainer: false) }
    }

    @Test func apiErrorReasonsMapToExitCodes() {
        func status(_ code: Int, _ reason: String?) -> CLIExitStatus {
            var error = APIError(response: APIResponse(status: code, headers: [:], body: Data()))
            error.reason = reason
            return error.cliError.exitStatus
        }
        #expect(status(401, "InvalidAPIKey") == .notAuthenticated)
        #expect(status(403, "UnauthorizedContainer") == .forbidden)
        #expect(status(403, "InsufficientPermissions") == .forbidden)
        #expect(status(404, nil) == .notFound)
        #expect(status(500, nil) == .failure)
    }
}

@Suite struct LoginFlowTests {
    let directory = TestSupport.temporaryDirectory()

    @Test func browserLoginExchangesCodeWithPKCEAndSaves() async throws {
        let challenge = NIOLockedValueBox<String?>(nil)
        let accessToken = TestSupport.jwt(["user": "user-1", "container": "acme", "role": "admin"])
        let server = try await MockAPIServer { request in
            let form = request.form
            guard request.path == "/oauth/token",
                  form["grant_type"] == "authorization_code",
                  form["client_id"] == "qualtive-cli",
                  form["code"] == "the-code",
                  let verifier = form["code_verifier"],
                  OAuth.PKCE(verifier: verifier).challenge == challenge.withLockedValue({ $0 }),
                  form["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true
            else {
                return .json(#"{"error":"invalid_grant"}"#, status: .badRequest)
            }
            return .json(TestSupport.tokenJSON(access: accessToken, refresh: "refresh-1", container: "acme"))
        }
        defer { Task { await server.shutdown() } }

        let environment = CLIEnvironment(variables: [:], configDirectory: directory)
        let store = FileCredentialStore(directory: directory)
        let session = try AuthSession(environment: environment, store: store, apiURLOverride: server.url)

        let credentials = try await LoginFlow.browserLogin(
            session: session,
            container: "acme",
            openBrowser: true,
            timeout: .seconds(10),
            opener: { url in
                // Plays the browser: the consent page redirects to redirect_uri with code + state.
                let query = Dictionary(uniqueKeysWithValues: (URLComponents(string: url)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                challenge.withLockedValue { $0 = query["code_challenge"] }
                let redirect = "\(query["redirect_uri"]!)?code=the-code&state=\(query["state"]!)"
                Task { _ = try? await HTTPClient.shared.execute(HTTPClientRequest(url: redirect), timeout: .seconds(5)) }
                return true
            },
            log: { _ in }
        )

        #expect(credentials.container == "acme")
        #expect(credentials.user == "user-1")
        #expect(try store.load(profile: "default")?.refreshToken == "refresh-1")
        #expect(try Config.load(from: environment).container == "acme")
    }

    @Test func apiKeyLoginRejectsInvalidKeys() async throws {
        let server = try await MockAPIServer { _ in .json(#"{"reason":"InvalidAPIKey"}"#, status: .unauthorized) }
        defer { Task { await server.shutdown() } }
        let store = FileCredentialStore(directory: directory)
        let session = try AuthSession(
            environment: CLIEnvironment(variables: [:], configDirectory: directory),
            store: store,
            apiURLOverride: server.url
        )
        await #expect(throws: CLIError.self) {
            try await LoginFlow.apiKeyLogin(session: session, apiKey: "u-bad", container: nil, log: { _ in })
        }
        #expect(try store.load(profile: "default") == nil)
    }

    @Test func containerAPIKeyLoginAdoptsItsContainer() async throws {
        let server = try await MockAPIServer { _ in .json(#"[{"id":"acme","name":"Acme"}]"#) }
        defer { Task { await server.shutdown() } }
        let store = FileCredentialStore(directory: directory)
        let session = try AuthSession(
            environment: CLIEnvironment(variables: [:], configDirectory: directory),
            store: store,
            apiURLOverride: server.url
        )
        let credentials = try await LoginFlow.apiKeyLogin(session: session, apiKey: "c-good\n", container: nil, log: { _ in })
        #expect(credentials.apiKey == "c-good")
        #expect(credentials.container == "acme")
        #expect(server.requests.first?.headers.first(name: "X-Container") == nil)
    }
}
