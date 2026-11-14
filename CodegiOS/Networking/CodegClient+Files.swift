import Foundation

/// Base64 file reads, for the images a reply's Markdown points at. Both return
/// a bare JSON string (`Json<String>` server side) and fail with the usual
/// server errors ("File does not exist", "Path is outside workspace root",
/// "File is too large to attach").
extension CodegClient {
    /// A file under `rootPath`, by a path relative to it. The server
    /// canonicalizes the path (resolving symlinks) and refuses anything that
    /// lands outside the root.
    func readWorkspaceFileBase64(rootPath: String, path: String, maxBytes: Int?) async throws -> String {
        try await postJSON("read_workspace_file_base64",
                           ReadWorkspaceFileBase64Body(rootPath: rootPath, path: path, maxBytes: maxBytes))
    }

    /// A file by its absolute path — the reader the web's file panel uses, and
    /// what a reply's screenshot in `/tmp` (outside the folder) needs.
    func readFileBase64(path: String, maxBytes: Int?) async throws -> String {
        try await postJSON("read_file_base64", ReadFileBase64Body(path: path, maxBytes: maxBytes))
    }
}

/// Body for `read_workspace_file_base64`.
struct ReadWorkspaceFileBase64Body: Encodable, Sendable {
    let rootPath: String
    let path: String
    var maxBytes: Int?
}

/// Body for `read_file_base64`.
struct ReadFileBase64Body: Encodable, Sendable {
    let path: String
    var maxBytes: Int?
}
