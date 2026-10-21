import ArgumentParser
import Foundation
import QualtiveCLICore

struct ContainersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "containers",
        abstract: "List containers and choose the default one.",
        subcommands: [List.self, Use.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the containers you can access.")

        @OptionGroup var global: GlobalOptions

        @Flag(help: "Print the API response as JSON.")
        var json = false

        func run() async throws {
            try await runCLI {
                let session = try global.makeSession()
                let response = try await session.send(.GET, "/containers", includeContainer: false)
                if json {
                    print(try Output.prettyJSON(response.body))
                    return
                }
                let containers = try response.decode([QualtiveCLICore.Container].self)
                let current = await session.container
                if containers.isEmpty {
                    print("No containers.")
                    return
                }
                print(Output.table(
                    headers: ["", "ID", "NAME"],
                    rows: containers.map { [$0.id == current ? "*" : "", $0.id, $0.name ?? ""] }
                ))
            }
        }
    }

    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Switch the default container.",
            discussion: "For browser logins this refreshes the token pair for the new container; no re-login is needed."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "The container ID (see `qualtive containers list`).")
        var id: String

        func run() async throws {
            try await runCLI {
                let session = try global.makeSession()
                let credentials = try await session.requireCredentials()
                switch (credentials.kind, await session.source) {
                case (.oauth, _):
                    let updated = try await session.refreshStoredCredentials(container: id)
                    try await session.setDefaultContainer(updated.container ?? id)
                    print("Now using container \(updated.container ?? id).")
                case (.apiKey, .store):
                    var updated = credentials
                    updated.container = id
                    try await session.saveCredentials(updated)
                    try await session.setDefaultContainer(id)
                    print("Now using container \(id).")
                case (.apiKey, _):
                    try await session.setDefaultContainer(id)
                    print("Default container set to \(id). QUALTIVE_CONTAINER and --container still take precedence.")
                }
            }
        }
    }
}
