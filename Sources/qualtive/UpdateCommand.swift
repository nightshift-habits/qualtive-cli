import ArgumentParser
import Foundation
import QualtiveCLICore

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update the CLI (Homebrew installs: prints the brew command).",
        discussion: "Self-update for ~/.local/bin installs is not implemented yet."
    )

    static let releasesURL = "https://github.com/nightshift-habits/qualtive-cli/releases"

    @Flag(help: "Only report whether a newer version is available.")
    var check = false

    func run() async throws {
        if check {
            print("Version checks are not implemented yet. You have \(QualtiveVersion.current); see \(Self.releasesURL).")
            return
        }
        let executable = (Bundle.main.executableURL?.resolvingSymlinksInPath().path) ?? CommandLine.arguments[0]
        if executable.contains("/Cellar/") {
            print("Installed with Homebrew. Run:\n\n  brew upgrade qualtive")
        } else {
            print("Self-update is not available yet. Download the latest release from \(Self.releasesURL).")
        }
    }
}
