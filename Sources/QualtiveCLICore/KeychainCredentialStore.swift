#if canImport(Security)
import Foundation
import Security

/// macOS Keychain generic-password items: service `io.qualtive.cli`, account = profile.
public struct KeychainCredentialStore: CredentialStore {
    public static let service = "io.qualtive.cli"
    public var name: String { "macOS Keychain (\(Self.service))" }

    public init() {}

    public func load(profile: String) throws -> StoredCredentials? {
        var query = baseQuery(profile: profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status, action: "read credentials from")
        }
        return try StoredCredentials.decoder.decode(StoredCredentials.self, from: data)
    }

    public func save(_ credentials: StoredCredentials, profile: String) throws {
        let data = try StoredCredentials.encoder.encode(credentials)
        let query = baseQuery(profile: profile)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Qualtive CLI (\(profile))"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status, action: "save credentials to") }
    }

    public func delete(profile: String) throws {
        let status = SecItemDelete(baseQuery(profile: profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, action: "delete credentials from")
        }
    }

    /// Keychain access is tied to the code signature, so only Developer ID builds (stable Team ID) default to it.
    /// Ad-hoc builds get a new identity on every build and would prompt constantly.
    public static func currentProcessHasTeamIdentifier() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return false
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        else { return false }
        return !team.isEmpty
    }

    private func baseQuery(profile: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: profile,
        ]
    }

    private func keychainError(_ status: OSStatus, action: String) -> CLIError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return CLIError(
            "Could not \(action) the Keychain: \(message)",
            hint: "Run `qualtive auth login` again, or set QUALTIVE_CREDENTIAL_STORE=file.",
            exitStatus: .notAuthenticated
        )
    }
}
#endif
