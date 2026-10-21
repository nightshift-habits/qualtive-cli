import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// POSIX file helpers for the config directory: 0700 directory, atomic writes with explicit modes,
/// and refusing to read secrets that other users can read.
enum SecureFile {
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let tempPath = url.path + ".tmp-\(getpid())-\(UInt32.random(in: 0 ... .max))"
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw posixError("create \(tempPath)") }
        var closed = false
        defer {
            if !closed { close(fd) }
        }
        // umask may have masked bits off at creation; set the exact mode.
        guard fchmod(fd, mode) == 0 else {
            unlink(tempPath)
            throw posixError("chmod \(tempPath)")
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let result = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += result
            }
            return true
        }
        guard written, fsync(fd) == 0 else {
            unlink(tempPath)
            throw posixError("write \(tempPath)")
        }
        close(fd)
        closed = true
        guard rename(tempPath, url.path) == 0 else {
            unlink(tempPath)
            throw posixError("rename to \(url.path)")
        }
    }

    /// Returns nil when the file does not exist.
    static func readPrivate(_ url: URL) throws -> Data? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError("stat \(url.path)")
        }
        if info.st_mode & 0o077 != 0 {
            throw CLIError(
                "Refusing to read \(url.path): it is readable by other users.",
                hint: "Run `chmod 600 \(url.path)` or `qualtive auth login` again."
            )
        }
        return try Data(contentsOf: url)
    }

    static func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw posixError("remove \(url.path)")
        }
    }

    static func ensureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) == 0 { return }
        if errno == ENOENT {
            try ensureDirectory(url.deletingLastPathComponent())
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw posixError("mkdir \(url.path)") }
            return
        }
        guard errno == EEXIST else { throw posixError("mkdir \(url.path)") }
    }

    private static func posixError(_ action: String) -> CLIError {
        CLIError("Could not \(action): \(String(cString: strerror(errno)))")
    }
}

/// Advisory exclusive lock (`flock`) so concurrent CLI processes don't write credentials at the same time.
final class FileLock {
    private let fd: Int32

    init(url: URL) throws {
        try SecureFile.ensureDirectory(url.deletingLastPathComponent())
        fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw CLIError("Could not open lock file \(url.path)") }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(fd)
                throw CLIError("Could not lock \(url.path)")
            }
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
