import ArgumentParser
import QualtiveCLICore

struct CategoriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "categories",
        abstract: "Work with feedback categories.",
        subcommands: [List.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the feedback categories in the container.")

        @OptionGroup var global: GlobalOptions

        @Flag(help: "Print the API response as JSON.")
        var json = false

        func run() async throws {
            try await runCLI {
                let session = try global.makeSession()
                let response = try await session.send(.GET, "/feedback/categories")
                if json {
                    print(try Output.prettyJSON(response.body))
                    return
                }
                let categories = try response.decode([Category].self)
                if categories.isEmpty {
                    print("No categories.")
                    return
                }
                print(Output.table(
                    headers: ["ID", "NAME", "ENQUIRIES", "UPDATED (UTC)"],
                    rows: categories.map {
                        [String($0.id), $0.name, String($0.questionsCounter), Output.timestamp(unixSeconds: $0.updated)]
                    }
                ))
            }
        }
    }
}
