import Foundation

/// Process-level inputs (environment variables and paths), injectable for tests.
public struct CLIEnvironment: Sendable {
    public static let defaultAPIURL = "https://admin-api.qualtive.io"

    public var variables: [String: String]
    public var configDirectory: URL

    public init(variables: [String: String], configDirectory: URL? = nil) {
        self.variables = variables
        self.configDirectory = configDirectory ?? Self.resolveConfigDirectory(variables)
    }

    public static func current() -> CLIEnvironment {
        CLIEnvironment(variables: ProcessInfo.processInfo.environment)
    }

    public var apiKey: String? { nonEmpty("QUALTIVE_API_KEY") }
    public var container: String? { nonEmpty("QUALTIVE_CONTAINER") }
    public var apiURL: String? { nonEmpty("QUALTIVE_API_URL") }
    public var credentialStore: String? { nonEmpty("QUALTIVE_CREDENTIAL_STORE") }

    public func nonEmpty(_ name: String) -> String? {
        guard let value = variables[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// `$QUALTIVE_CONFIG_DIR`, else `$XDG_CONFIG_HOME/qualtive`, else `~/.config/qualtive` (on macOS too).
    static func resolveConfigDirectory(_ variables: [String: String]) -> URL {
        if let dir = variables["QUALTIVE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        if let xdg = variables["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("qualtive", isDirectory: true)
        }
        let home = variables["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("qualtive", isDirectory: true)
    }
}
