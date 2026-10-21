/// Process exit codes. Stable so scripts can branch on them.
public enum CLIExitStatus: Int32, Sendable {
    case success = 0
    case failure = 1
    case usage = 2
    case notAuthenticated = 3
    case forbidden = 4
    case notFound = 5
    case network = 6
}

public struct CLIError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var hint: String?
    public var exitStatus: CLIExitStatus

    public init(_ message: String, hint: String? = nil, exitStatus: CLIExitStatus = .failure) {
        self.message = message
        self.hint = hint
        self.exitStatus = exitStatus
    }

    public var description: String { message }

    public static func notLoggedIn() -> CLIError {
        CLIError(
            "Not logged in.",
            hint: "Run `qualtive auth login`, or set QUALTIVE_API_KEY.",
            exitStatus: .notAuthenticated
        )
    }
}
