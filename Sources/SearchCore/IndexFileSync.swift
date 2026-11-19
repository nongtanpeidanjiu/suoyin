import Darwin

/// Index frames and snapshots must survive more than a process exit. Fall
/// back to the filesystem sync on volumes without a hardware flush command.
func syncIndexFile(_ fd: Int32) throws {
    while fcntl(fd, F_FULLFSYNC) != 0 {
        let code = errno
        if code == EINTR { continue }
        guard code == ENOTSUP || code == ENOTTY || code == EINVAL else { throw SnapshotError.filesystem(code) }
        try syncIndexDescriptor(fd)
        return
    }
}

func syncIndexDirectory(containing path: String) throws {
    let fd = open(path.contains("/") ? parentPath(path) : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw SnapshotError.filesystem(errno) }
    defer { _ = close(fd) }
    try syncIndexDescriptor(fd)
}

private func syncIndexDescriptor(_ fd: Int32) throws {
    while fsync(fd) != 0 {
        guard errno == EINTR else { throw SnapshotError.filesystem(errno) }
    }
}
