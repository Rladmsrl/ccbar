import Foundation

/// Walks `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` and turns each
/// transcript into a ``Session`` with cheap metadata only (no parsing).
struct SessionScanner: Sendable {
    let paths: ClaudePaths

    /// Files smaller than this are almost certainly empty/aborted sessions.
    static let minimumFileSize: Int64 = 100

    func scan() async -> [Session] {
        let fm = FileManager.default
        let projectsDir = paths.projectsDirectory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsDir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { return [] }

        var sessions: [Session] = []
        for projectDir in projectDirs {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let dirName = projectDir.lastPathComponent
            guard let files = try? fm.contentsOfDirectory(at: projectDir,
                                                          includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                guard size >= Self.minimumFileSize else { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                let uuid = file.deletingPathExtension().lastPathComponent
                sessions.append(Session(
                    id: "\(dirName)::\(uuid)",
                    externalID: uuid,
                    provider: .claude,
                    projectDirectoryName: dirName,
                    filePath: file.path,
                    cwd: Self.readCwd(from: file),
                    lastModified: modified,
                    fileSize: size
                ))
            }
        }
        return sessions.sorted { $0.lastModified > $1.lastModified }
    }

    /// Pull `cwd` out of the transcript by scanning the first chunk for the
    /// `"cwd":"..."` byte marker — avoids JSON-decoding the whole file.
    private static func readCwd(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return nil }
        let marker = Data("\"cwd\":\"".utf8)
        guard let range = chunk.range(of: marker) else { return nil }
        let rest = chunk[range.upperBound...]
        guard let endIndex = rest.firstIndex(of: 0x22 /* " */) else { return nil }
        let valueBytes = chunk[range.upperBound..<endIndex]
        guard let value = String(data: Data(valueBytes), encoding: .utf8), !value.isEmpty else { return nil }
        // JSON-escaped slashes are rare here, but unescape the common ones.
        return value.replacingOccurrences(of: "\\/", with: "/")
    }
}
