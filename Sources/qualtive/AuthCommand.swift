import ArgumentParser
import Foundation
import QualtiveCLICore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Log in, log out, and inspect credentials.",
        subcommands: [Login.self, Logout.self, Status.self, Token.self]
    )

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Log in with the browser, or store an API key with --with-token.",
            discussion: """
            By default this opens the Qualtive login page in your browser and receives the result on \
            http://127.0.0.1:<port>/callback. On headless machines, pipe an API key to --with-token, \
            or set QUALTIVE_API_KEY instead of logging in.
            """
        )

        @OptionGroup var global: GlobalOptions

        @Flag(help: "Read an API key (u-… or c-…) from standard input instead of using the browser.")
        var withToken = false

        @Flag(help: "Print the login URL instead of opening a browser.")
        var noBrowser = false

        func run() async throws {
            try await runCLI {
                let session = try global.makeSession()
                if await session.source == .environment {
                    StandardError.write("Note: QUALTIVE_API_KEY is set and takes precedence over stored credentials.")
                }
                if withToken {
                    let credentials = try await LoginFlow.apiKeyLogin(
                        session: session,
                        apiKey: readAPIKey(),
                        container: global.container
                    )
                    let where_ = credentials.container.map { " for container \($0)" } ?? ""
                    print("Saved API key\(where_) to \(session.store.name).")
                } else {
                    let credentials = try await LoginFlow.browserLogin(
                        session: session,
                        container: global.container,
                        openBrowser: !noBrowser
                    )
                    let user = credentials.user.map { " as \($0)" } ?? ""
                    print("Logged in\(user) to container \(credentials.container ?? "?").")
                }
            }
        }

        private func readAPIKey() -> String {
            if isatty(STDIN_FILENO) != 0 {
                guard let pointer = getpass("Paste your Qualtive API key: ") else { return "" }
                return String(cString: pointer)
            }
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
    }

    struct Logout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete the locally stored credentials.",
            discussion: """
            There are no server-side sessions: the stored refresh token stays valid until it expires (40 days), \
            the same as logging out of the web admin.
            """
        )

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCLI {
                let session = try global.makeSession()
                if try await session.deleteCredentials() {
                    print("Logged out. Removed credentials from \(session.store.name).")
                } else {
                    print("Not logged in; nothing to remove.")
                }
                if await session.source == .environment {
                    StandardError.write("Note: QUALTIVE_API_KEY is still set in your environment.")
                }
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show who you're logged in as, the container, and token expiry."
        )

        @OptionGroup var global: GlobalOptions

        @Flag(help: "Print JSON.")
        var json = false

        func run() async throws {
            try await runCLI {
                let session = try global.makeSession()
                guard let credentials = await session.currentCredentials else {
                    if json {
                        print(try Output.prettyJSON(object: ["logged_in": false]))
                    } else {
                        print("Not logged in. Run `qualtive auth login`.")
                    }
                    throw ExitCode(CLIExitStatus.notAuthenticated.rawValue)
                }
                let status = try await AuthStatus(session: session, credentials: credentials)
                print(json ? try Output.prettyJSON(object: status.json) : status.text)
            }
        }
    }

    struct Token: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a valid access token (refreshing it if needed), or the API key in use."
        )

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCLI {
                let session = try global.makeSession()
                print(try await session.validBearerToken())
            }
        }
    }
}

struct AuthStatus {
    var rows: [(String, String)] = []
    var json: [String: Any] = ["logged_in": true]

    init(session: AuthSession, credentials: StoredCredentials) async throws {
        let source = await session.source
        add("API", "api_url", await session.apiURL)
        switch credentials.kind {
        case .oauth:
            add("Auth", "auth_type", "browser login (OAuth)")
        case .apiKey:
            let origin = source == .environment ? "QUALTIVE_API_KEY" : "stored API key"
            add("Auth", "auth_type", "\(origin) (\(Self.mask(credentials.apiKey ?? "")))")
        }
        if source == .store {
            add("Credentials", "credential_store", session.store.name)
        }
        add("Container", "container", await session.container ?? "(none)")
        if credentials.kind == .oauth, let token = credentials.accessToken, let claims = JWT.claims(token) {
            if let user = credentials.user {
                add("User", "user", user)
            }
            if let role = claims["role"].map({ "\($0)" }) {
                add("Role", "role", role)
            }
            if let workspaces = claims["workspaceIDs"] as? [Any], !workspaces.isEmpty {
                add("Workspaces", "workspace_ids", workspaces.map { "\($0)" }.joined(separator: ", "))
            }
        }
        if let expiresAt = credentials.accessExpiresAt {
            let remaining = Int(expiresAt.timeIntervalSinceNow)
            let state = remaining > 0 ? "in \(remaining / 60) min" : "expired (refreshed on next use)"
            rows.append(("Access token", "expires \(Output.timestamp(expiresAt)) UTC, \(state)"))
            json["access_expires_at"] = Int(expiresAt.timeIntervalSince1970)
        }
    }

    var text: String {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { "\($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }.joined(separator: "\n")
    }

    private mutating func add(_ label: String, _ key: String, _ value: String) {
        rows.append((label, value))
        json[key] = value
    }

    static func mask(_ key: String) -> String {
        key.count > 8 ? String(key.prefix(6)) + "…" : "…"
    }
}
