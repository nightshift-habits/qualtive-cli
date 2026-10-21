public enum QualtiveVersion {
    /// Replaced by the release workflow before building a tagged release.
    public static let current = "0.1.0-dev"

    public static var userAgent: String {
        "qualtive-cli/\(current) (\(Platform.osName); \(Platform.architecture))"
    }
}

public enum Platform {
    public static var osName: String {
        #if os(macOS)
        "macOS"
        #elseif os(Linux)
        "Linux"
        #elseif os(Windows)
        "Windows"
        #else
        "unknown"
        #endif
    }

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
