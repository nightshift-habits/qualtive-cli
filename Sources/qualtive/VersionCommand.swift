import ArgumentParser
import QualtiveCLICore

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Print the CLI version.")

    @Flag(help: "Print JSON.")
    var json = false

    func run() async throws {
        if json {
            print(try Output.prettyJSON(object: [
                "version": QualtiveVersion.current,
                "os": Platform.osName,
                "arch": Platform.architecture,
            ]))
        } else {
            print("qualtive \(QualtiveVersion.current) (\(Platform.osName) \(Platform.architecture))")
        }
    }
}
