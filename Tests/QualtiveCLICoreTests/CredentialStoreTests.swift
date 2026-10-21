import Foundation
import Testing
@testable import QualtiveCLICore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite struct CredentialStoreTests {
    let credentials = StoredCredentials(
        kind: .oauth,
        accessToken: "access",
        accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        refreshToken: "refresh",
        container: "acme",
        user: "u1",
        apiURL: "https://admin-api.qualtive.io"
    )

    @Test func fileStoreRoundTripsWithPrivatePermissions() throws {
        let directory = TestSupport.temporaryDirectory().appendingPathComponent("nested/qualtive")
        let store = FileCredentialStore(directory: directory)
        #expect(try store.load(profile: "default") == nil)

        try store.save(credentials, profile: "default")
        #expect(try store.load(profile: "default") == credentials)
        #expect(try mode(of: store.fileURL) == 0o600)
        #expect(try mode(of: directory) == 0o700)

        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"refresh_token\" : \"refresh\""))
        #expect(json.contains("\"access_expires_at\" : 1800000000"))

        try store.delete(profile: "default")
        #expect(try store.load(profile: "default") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func fileStoreKeepsOtherProfiles() throws {
        let store = FileCredentialStore(directory: TestSupport.temporaryDirectory())
        try store.save(credentials, profile: "default")
        var other = credentials
        other.container = "other"
        try store.save(other, profile: "work")
        try store.delete(profile: "default")
        #expect(try store.load(profile: "work") == other)
    }

    @Test func fileStoreRefusesGroupOrWorldReadableFile() throws {
        let store = FileCredentialStore(directory: TestSupport.temporaryDirectory())
        try store.save(credentials, profile: "default")
        chmod(store.fileURL.path, 0o644)
        #expect(throws: CLIError.self) { try store.load(profile: "default") }
    }

    @Test func credentialStoreSelection() throws {
        let file = try CredentialStores.make(for: CLIEnvironment(
            variables: ["QUALTIVE_CREDENTIAL_STORE": "file"],
            configDirectory: TestSupport.temporaryDirectory()
        ))
        #expect(file is FileCredentialStore)
        #expect(throws: CLIError.self) {
            try CredentialStores.make(for: CLIEnvironment(variables: ["QUALTIVE_CREDENTIAL_STORE": "nope"]))
        }
        #if !canImport(Security)
        let fallback = try CredentialStores.make(for: CLIEnvironment(variables: [:], configDirectory: TestSupport.temporaryDirectory()))
        #expect(fallback is FileCredentialStore)
        #endif
    }

    @Test func refreshNeededWithinSixtySecondsOfExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        var value = credentials
        value.accessExpiresAt = now.addingTimeInterval(61)
        #expect(!value.accessTokenNeedsRefresh(now: now))
        value.accessExpiresAt = now.addingTimeInterval(59)
        #expect(value.accessTokenNeedsRefresh(now: now))
        value.accessToken = nil
        value.accessExpiresAt = nil
        #expect(value.accessTokenNeedsRefresh(now: now))
        #expect(!StoredCredentials(kind: .apiKey, apiKey: "u-1", apiURL: "x").accessTokenNeedsRefresh(now: now))
    }

    @Test func configDirectoryResolution() {
        #expect(CLIEnvironment.resolveConfigDirectory(["HOME": "/home/a"]).path == "/home/a/.config/qualtive")
        #expect(CLIEnvironment.resolveConfigDirectory(["HOME": "/home/a", "XDG_CONFIG_HOME": "/x"]).path == "/x/qualtive")
        #expect(CLIEnvironment.resolveConfigDirectory(["XDG_CONFIG_HOME": "relative", "HOME": "/h"]).path == "/h/.config/qualtive")
        #expect(CLIEnvironment.resolveConfigDirectory(["QUALTIVE_CONFIG_DIR": "/c", "XDG_CONFIG_HOME": "/x"]).path == "/c")
    }

    private func mode(of url: URL) throws -> mode_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw CLIError("stat failed") }
        return info.st_mode & 0o777
    }
}
