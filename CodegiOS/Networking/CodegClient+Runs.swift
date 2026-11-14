import Foundation

/// Body for `acp_stop_async_task` (camelCase, like every request).
struct StopAsyncTaskBody: Encodable, Sendable {
    let connectionId: String
    let taskId: String
}

extension CodegClient {
    /// Stop one AIR async task (`_session/async_task/stop`). Works between
    /// turns as well as during one.
    ///
    /// Returns the ADAPTER's verdict, not "the request went through": `false`
    /// is an ordinary 200 meaning it declined (unknown task, already finished,
    /// a stop already on its way). The visible result — the task's terminal
    /// state — arrives on the session stream either way, so callers use this
    /// only to avoid claiming they stopped something they didn't.
    func stopAsyncTask(connectionId: String, taskId: String) async throws -> Bool {
        try await postJSON("acp_stop_async_task", StopAsyncTaskBody(connectionId: connectionId, taskId: taskId))
    }
}
