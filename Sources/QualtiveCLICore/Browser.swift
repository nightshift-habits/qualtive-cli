import Foundation

public enum Browser {
    /// Opens `url` with `open` (macOS) or `xdg-open` (Linux). Returns false when no opener could run.
    public static func open(_ url: String) -> Bool {
        #if os(macOS)
        let candidates = ["/usr/bin/open"]
        #else
        let candidates = ["/usr/bin/xdg-open", "/usr/local/bin/xdg-open", "/bin/xdg-open"]
        #endif
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
