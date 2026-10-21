import AsyncHTTPClient
import Foundation
import Testing
@testable import QualtiveCLICore

@Suite struct OAuthCallbackServerTests {
    @Test func returnsCodeForMatchingState() async throws {
        let server = try await OAuthCallbackServer.start(expectedState: "s1")
        #expect(server.redirectURI == "http://127.0.0.1:\(server.port)/callback")
        let result = Task { try await server.waitForCode(timeout: .seconds(10)) }

        let (status, body) = try await get("\(server.redirectURI)?code=abc&state=s1")
        #expect(status == 200)
        #expect(body.contains("You can close this tab"))
        #expect(try await result.value.code == "abc")
    }

    @Test func ignoresOtherPathsAndWrongState() async throws {
        let server = try await OAuthCallbackServer.start(expectedState: "s2")
        let result = Task { try await server.waitForCode(timeout: .seconds(10)) }

        #expect(try await get("http://127.0.0.1:\(server.port)/favicon.ico").0 == 404)
        #expect(try await get("\(server.redirectURI)?code=evil&state=wrong").0 == 400)
        #expect(try await get("\(server.redirectURI)?state=s2").0 == 400)
        #expect(try await get("\(server.redirectURI)?code=good&state=s2").0 == 200)
        #expect(try await result.value.code == "good")
    }

    @Test func accessDeniedFailsTheLogin() async throws {
        let server = try await OAuthCallbackServer.start(expectedState: "s3")
        let result = Task { try await server.waitForCode(timeout: .seconds(10)) }
        #expect(try await get("\(server.redirectURI)?error=access_denied&state=s3").0 == 200)
        await #expect(throws: CLIError.self) { try await result.value }
    }

    @Test func timesOut() async throws {
        let server = try await OAuthCallbackServer.start(expectedState: "s4")
        await #expect(throws: CLIError.self) { try await server.waitForCode(timeout: .milliseconds(50)) }
    }

    private func get(_ url: String) async throws -> (Int, String) {
        let response = try await HTTPClient.shared.execute(HTTPClientRequest(url: url), timeout: .seconds(5))
        let body = try await response.body.collect(upTo: 1 << 20)
        return (Int(response.status.code), String(buffer: body))
    }
}
