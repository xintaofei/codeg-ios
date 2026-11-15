import Foundation

/// Decoding for the events behind the composer's "N running" list and its
/// predicted next prompt. Kept apart from the main `AcpEvent` decoder, which
/// hands every type it does not know to ``decodeRunsEvent(type:from:)``.
///
/// Every one of these is decoded leniently: a frame that doesn't have the shape
/// expected comes back nil — and so `.unknown` — rather than throwing, which
/// would drop the whole envelope.
extension AcpEvent {
    private enum RunsKeys: String, CodingKey {
        case delta, outstandingTasks, childConnectionId, running, result, text, turns, settled
        case watermark, sessionId
    }

    /// One element of a list decoded on its own, so one this build cannot
    /// read drops alone.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// `delegation_completed.result` (Rust `DelegationResultSummary`, tagged `kind`).
    private struct DelegationResult: Decodable {
        let kind: String
        let errorCode: String?

        private enum CodingKeys: String, CodingKey { case kind, errorCode }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil) ?? ""
            errorCode = (try? c.decodeIfPresent(String.self, forKey: .errorCode)) ?? nil
        }
    }

    static func decodeRunsEvent(type: String, from decoder: Decoder) -> AcpEvent? {
        guard let c = try? decoder.container(keyedBy: RunsKeys.self) else { return nil }
        switch type {
        case "async_task":
            // `{delta: {task_id, spawned, …}}` — absent fields mean unchanged.
            guard let delta = (try? c.decodeIfPresent(AsyncTaskDelta.self, forKey: .delta)) ?? nil,
                  !delta.taskId.isEmpty else { return nil }
            return .asyncTask(delta)
        case "background_activity":
            // The producer's WHOLE outstanding set; absent on the wire means none.
            // Each turn is read on its own: one this build can't read drops
            // alone, and is still counted.
            let turns = ((try? c.decodeIfPresent([Lenient<MessageTurn>].self, forKey: .turns)) ?? nil) ?? []
            let settled = ((try? c.decodeIfPresent([BackgroundSettled].self, forKey: .settled)) ?? nil) ?? []
            return .backgroundActivity(
                outstandingTasks: ((try? c.decodeIfPresent([BackgroundOutstandingTask].self,
                                                             forKey: .outstandingTasks)) ?? nil) ?? [],
                outOfTurn: BackgroundOutOfTurn(
                    turnCount: turns.count,
                    turns: turns.compactMap(\.value),
                    watermark: ((try? c.decodeIfPresent(Int64.self, forKey: .watermark)) ?? nil) ?? 0,
                    sessionID: (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? nil,
                    settled: settled.filter { !$0.taskId.isEmpty }))
        case "delegation_started":
            guard let info = try? DelegationInfo(from: decoder), !info.parentToolUseId.isEmpty else { return nil }
            return .delegationStarted(info)
        case "delegation_completed":
            guard let info = try? DelegationInfo(from: decoder), !info.parentToolUseId.isEmpty else { return nil }
            let result = (try? c.decodeIfPresent(DelegationResult.self, forKey: .result)) ?? nil
            return .delegationCompleted(info, succeeded: result?.kind == "ok", errorCode: result?.errorCode)
        case "delegation_child_running":
            guard let child = (try? c.decodeIfPresent(String.self, forKey: .childConnectionId)) ?? nil,
                  !child.isEmpty else { return nil }
            return .delegationChildRunning(
                childConnectionId: child,
                running: ((try? c.decodeIfPresent(Bool.self, forKey: .running)) ?? nil) ?? false)
        case "prompt_suggestion":
            // `text: null` withdraws the one held.
            return .promptSuggestion(text: (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil)
        default:
            return nil
        }
    }
}
