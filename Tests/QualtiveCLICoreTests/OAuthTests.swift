import Foundation
import Testing
@testable import QualtiveCLICore

@Suite struct OAuthTests {
    @Test func pkceMatchesRFC7636AppendixB() {
        let pkce = OAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedPKCEIs43CharacterBase64URL() {
        let pkce = OAuth.PKCE.generate()
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(pkce.verifier.count == 43)
        #expect(pkce.challenge.count == 43)
        #expect(pkce.verifier.allSatisfy(allowed.contains))
        #expect(pkce.challenge.allSatisfy(allowed.contains))
        #expect(OAuth.PKCE.generate().verifier != pkce.verifier)
    }

    @Test func authorizeURLCarriesTheContractParameters() throws {
        let pkce = OAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = OAuth.authorizeURL(
            apiURL: "https://admin-api.qualtive.io/",
            redirectURI: OAuth.redirectURI(port: 53682),
            pkce: pkce,
            state: "st",
            container: "acme"
        )
        let components = try #require(URLComponents(string: url))
        #expect(components.host == "admin-api.qualtive.io")
        #expect(components.path == "/oauth/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == [
            "response_type": "code",
            "client_id": "qualtive-cli",
            "redirect_uri": "http://127.0.0.1:53682/callback",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "state": "st",
            "container": "acme",
        ])
        #expect(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Fcallback"))
    }

    @Test func formEncodingEscapesReservedAndNonASCII() {
        #expect(FormEncoding.encode([("a b", "x+y/z=å&")]) == "a%20b=x%2By%2Fz%3D%C3%A5%26")
    }

    @Test func tokenAndErrorResponsesDecode() throws {
        let token = try JSONDecoder().decode(
            TokenResponse.self,
            from: Data(TestSupport.tokenJSON(access: "a", refresh: "r", container: "acme").utf8)
        )
        #expect(token == TokenResponse(accessToken: "a", tokenType: "Bearer", expiresIn: 1800, refreshToken: "r", container: "acme"))
        let error = try JSONDecoder().decode(
            OAuthErrorResponse.self,
            from: Data(#"{"error":"invalid_grant","error_description":"expired"}"#.utf8)
        )
        #expect(OAuthError(status: 400, response: error).cliError.exitStatus == .notAuthenticated)
    }

    @Test func jwtClaimsAreReadWithoutVerification() {
        let token = TestSupport.jwt(["user": "u1", "container": "acme", "role": "admin"])
        let claims = JWT.claims(token)
        #expect(claims?["container"] as? String == "acme")
        #expect(claims.flatMap(JWT.userDescription) == "u1")
        #expect(JWT.claims("not-a-jwt") == nil)
    }
}
