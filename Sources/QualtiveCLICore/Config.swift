import Foundation

/// Non-secret settings in `config.json`.
public struct Config: Codable, Equatable, Sendable {
    public var container: String?
    public var apiURL: String?

    public init(container: String? = nil, apiURL: String? = nil) {
        self.container = container
        self.apiURL = apiURL
    }

    enum CodingKeys: String, CodingKey {
        case container
        case apiURL = "api_url"
    }

    public static func fileURL(in environment: CLIEnvironment) -> URL {
        environment.configDirectory.appendingPathComponent("config.json")
    }

    public static func load(from environment: CLIEnvironment) throws -> Config {
        let url = fileURL(in: environment)
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw CLIError("Could not read \(url.path): \(error)")
        }
    }

    public func save(to environment: CLIEnvironment) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.writeAtomically(encoder.encode(self), to: Config.fileURL(in: environment), mode: 0o644)
    }
}
