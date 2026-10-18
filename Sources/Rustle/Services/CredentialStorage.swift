import Foundation

struct APICredentials: Codable, Equatable {
    var transcriptionKey = ""
    var insightsKey = ""
}

/// Local plaintext storage, isolated from preferences, recordings, and the system Keychain.
struct CredentialStorage {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("api-keys.json") }
    private let fileManager = FileManager.default

    init(directory dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("Credentials", isDirectory: true)
    }

    func read() throws -> APICredentials {
        guard fileManager.fileExists(atPath: fileURL.path) else { return APICredentials() }
        try restrictDirectory()
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return try JSONDecoder().decode(APICredentials.self, from: Data(contentsOf: fileURL))
    }

    func save(_ credentials: APICredentials) throws {
        if credentials.transcriptionKey.isEmpty && credentials.insightsKey.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try restrictDirectory()
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try restrictDirectory()
        // Atomic replacement and its temporary file stay inside the owner-only directory.
        try JSONEncoder().encode(credentials).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func restrictDirectory() throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
