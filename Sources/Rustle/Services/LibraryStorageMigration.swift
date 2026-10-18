import Foundation

enum LibraryStorageMigration {
    static let preferenceKey = "dataDirectoryPath"
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rustle", isDirectory: true)
    }

    static func relocatedPath(_ path: String, from source: URL, to destination: URL) -> String {
        guard !path.isEmpty else { return path }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        for (candidate, root) in [(file, source.standardizedFileURL), (file.resolvingSymlinksInPath(), source.resolvingSymlinksInPath())] {
            let components = candidate.pathComponents
            let prefix = root.pathComponents
            if components.count > prefix.count && components.starts(with: prefix) {
                return components.dropFirst(prefix.count).reduce(destination) { $0.appendingPathComponent($1) }.path
            }
        }
        return path
    }

    /// Commit a complete library into a new directory. The source remains a backup.
    static func migrate(from source: URL, to destination: URL, recordings: [Recording]) async throws -> [Recording] {
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let files = FileManager.default
            let original = source.standardizedFileURL.resolvingSymlinksInPath()
            // Resolving a nonexistent URL does not resolve links in its parent on macOS.
            let target = destination.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(destination.lastPathComponent, isDirectory: true)
            guard source.isFileURL, destination.isFileURL else {
                throw ProcessingFailure.message("请选择本机或已挂载磁盘中的文件夹。")
            }
            let oldParts = original.pathComponents, newParts = target.pathComponents
            guard !oldParts.starts(with: newParts), !newParts.starts(with: oldParts) else {
                throw ProcessingFailure.message("新位置不能是当前存储目录、它的子目录或上级目录。")
            }
            // Also recognize alternate casing on case-insensitive volumes.
            if let sourceID = (try? original.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject {
                var ancestorPath = target.deletingLastPathComponent().path
                while !ancestorPath.isEmpty {
                    try Task.checkCancellation()
                    let ancestor = URL(fileURLWithPath: ancestorPath, isDirectory: true)
                    if let identifier = (try? ancestor.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject,
                       identifier.isEqual(sourceID) {
                        throw ProcessingFailure.message("新位置不能是当前存储目录的子目录。")
                    }
                    let parentPath = (ancestorPath as NSString).deletingLastPathComponent
                    if parentPath.count >= ancestorPath.count { break }
                    ancestorPath = parentPath
                }
            }
            guard !files.fileExists(atPath: target.path) else {
                throw ProcessingFailure.message("所选位置中已存在 Rustle 文件夹。请选择其他位置或新建文件夹，避免覆盖已有数据。")
            }
            let parent = target.deletingLastPathComponent()
            guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw ProcessingFailure.message("目标文件夹不可用，请检查磁盘连接。")
            }
            let stage = parent.appendingPathComponent(".rustle-migration-\(UUID().uuidString)", isDirectory: true)
            defer { try? files.removeItem(at: stage) }
            try files.copyItem(at: original, to: stage)
            try Task.checkCancellation()
            var migrated = recordings
            for index in migrated.indices {
                if let path = migrated[index].localMediaPath {
                    migrated[index].localMediaPath = relocatedPath(path, from: source, to: destination)
                }
            }
            let library = stage.appendingPathComponent("library.json")
            try JSONEncoder().encode(migrated).write(to: library, options: .atomic)
            guard try JSONDecoder().decode([Recording].self, from: Data(contentsOf: library)) == migrated else {
                throw ProcessingFailure.message("新记录库校验失败，仍使用原存储位置。")
            }
            let credentials = stage.appendingPathComponent("Credentials", isDirectory: true)
            if files.fileExists(atPath: credentials.path) {
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: credentials.path)
                let keys = credentials.appendingPathComponent("api-keys.json")
                if files.fileExists(atPath: keys.path) {
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keys.path)
                }
            }
            try Task.checkCancellation()
            // moveItem fails if a different process has created the target meanwhile.
            try files.moveItem(at: stage, to: target)
            return migrated
        }
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }
}
