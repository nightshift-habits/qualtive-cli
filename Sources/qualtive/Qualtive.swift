import ArgumentParser
import QualtiveCLICore

@main
struct Qualtive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qualtive",
        abstract: "Work with Qualtive from the command line.",
        version: QualtiveVersion.current,
        subcommands: [
            AuthCommand.self,
            ContainersCommand.self,
            CategoriesCommand.self,
            UpdateCommand.self,
            VersionCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Container ID to use (overrides QUALTIVE_CONTAINER and the default container).")
    var container: String?

    @Option(name: .long, help: .hidden)
    var apiURL: String?

    func makeSession() throws -> AuthSession {
        let environment = CLIEnvironment.current()
        return try AuthSession(
            environment: environment,
            store: CredentialStores.make(for: environment),
            containerOverride: container,
            apiURLOverride: apiURL
        )
    }
}

/// Prints `CLIError`s as `error: …` plus an optional hint and exits with their status.
func runCLI(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as CLIError {
        throw report(error)
    } catch let error as APIError {
        throw report(error.cliError)
    } catch let error as OAuthError {
        throw report(error.cliError)
    }
}

private func report(_ error: CLIError) -> ExitCode {
    StandardError.write("error: \(error.message)")
    if let hint = error.hint {
        StandardError.write("hint: \(hint)")
    }
    return ExitCode(error.exitStatus.rawValue)
}
