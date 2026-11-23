import Darwin
import Foundation
import LidLidServiceCore

/// Only the daemon knows this fixed path. openat + O_NOFOLLOW prevent symlink
/// redirection; the directory and file must be root-owned and private. A synced
/// rename commits the journal before pmset may persist the override.
final class RootJournal: SleepJournalStore {
    private let directory: Int32
    private let name = "recovery.json"
    init() throws {
        let path = "/Library/Application Support/dev.kf.lidonce.compatibility"
        guard geteuid() == 0 else { throw ServiceFailure("兼容服务需要 macOS 管理员授权") }
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard directory >= 0, fstat(directory, &info) == 0, info.st_uid == 0,
              info.st_mode & 0o777 == 0o700 else {
            if directory >= 0 { close(directory) }
            throw ServiceFailure("兼容组件恢复目录权限异常，请联系支持")
        }
    }
    deinit { close(directory) }
    func load() throws -> SleepJournal? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw ServiceFailure("无法读取兼容组件恢复记录") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 4096 else {
            throw ServiceFailure("兼容组件恢复记录权限或格式异常，请联系支持")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard read(fd, &bytes, bytes.count) == bytes.count else { throw ServiceFailure("无法读取兼容组件恢复记录") }
        return try JSONDecoder().decode(SleepJournal.self, from: Data(bytes))
    }
    func save(_ journal: SleepJournal) throws {
        let temporary = ".recovery-\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ServiceFailure("无法保存兼容组件恢复记录") }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        let data = try JSONEncoder().encode(journal)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0,
              renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else {
            throw ServiceFailure("无法安全保存兼容组件恢复记录")
        }
    }
    func clear() throws {
        guard unlinkat(directory, name, 0) == 0 || errno == ENOENT, fsync(directory) == 0 else {
            throw ServiceFailure("无法清除兼容组件恢复记录")
        }
    }
}
