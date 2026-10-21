import Foundation

public protocol CredentialStore: Sendable {
    var name: String { get }
    func load(profile: String) throws -> StoredCredentials?
    func save(_ credentials: StoredCredentials, profile: String) throws
    func delete(profile: String) throws
}

public enum CredentialStores {
    /// Picks the store from `QUALTIVE_CREDENTIAL_STORE` (`file` or `keychain`), else the platform default:
    /// Keychain for Developer ID signed macOS builds, the 0600 file everywhere else.
    public static func make(for environment: CLIEnvironment) throws -> any CredentialStore {
        let file = FileCredentialStore(directory: environment.configDirectory)
        switch environment.credentialStore?.lowercased() {
        case "file":
            return file
        case "keychain":
            #if canImport(Security)
            return KeychainCredentialStore()
            #else
            throw CLIError("The keychain credential store is only available on macOS.", exitStatus: .usage)
            #endif
        case nil:
            #if canImport(Security)
            if KeychainCredentialStore.currentProcessHasTeamIdentifier() {
                return KeychainCredentialStore()
            }
            #endif
            return file
        case let other?:
            throw CLIError(
                "Unknown QUALTIVE_CREDENTIAL_STORE value \"\(other)\".",
                hint: "Use \"file\" or \"keychain\".",
                exitStatus: .usage
            )
        }
    }
}

/// `credentials.json` holding every profile, mode 0600 inside a 0700 directory.
public struct FileCredentialStore: CredentialStore {
    public let directory: URL
    public var name: String { fileURL.path }

    public init(directory: URL) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("credentials.json") }

    struct FileContents: Codable {
        var profiles: [String: StoredCredentials]
    }

    public func load(profile: String) throws -> StoredCredentials? {
        try readAll().profiles[profile]
    }

    public func save(_ credentials: StoredCredentials, profile: String) throws {
        var contents = try readAll()
        contents.profiles[profile] = credentials
        try writeAll(contents)
    }

    public func delete(profile: String) throws {
        var contents = try readAll()
        guard contents.profiles.removeValue(forKey: profile) != nil else { return }
        if contents.profiles.isEmpty {
            try SecureFile.remove(fileURL)
        } else {
            try writeAll(contents)
        }
    }

    private func readAll() throws -> FileContents {
        guard let data = try SecureFile.readPrivate(fileURL) else { return FileContents(profiles: [:]) }
        do {
            return try StoredCredentials.decoder.decode(FileContents.self, from: data)
        } catch {
            throw CLIError(
                "Could not parse \(fileURL.path).",
                hint: "Run `qualtive auth logout` and log in again."
            )
        }
    }

    private func writeAll(_ contents: FileContents) throws {
        try SecureFile.writeAtomically(StoredCredentials.encoder.encode(contents), to: fileURL, mode: 0o600)
    }
}
