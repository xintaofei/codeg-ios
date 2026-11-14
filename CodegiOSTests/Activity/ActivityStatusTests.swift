import Testing
@testable import Codeg

/// `src/lib/activity/status.test.ts`.
@MainActor
struct ActivityStatusTests {
    private func call(state: ToolCallState = .done, output: String? = "ok", isError: Bool = false) -> ToolCallVM {
        ToolCallVM(id: "c1", rawName: "Bash", kind: "", state: state,
                   input: #"{"command":"ls"}"#, output: output, content: nil, isError: isError)
    }

    @Test func mapsTheLifecycleStates() {
        #expect(ActivityStatus.of(call()) == .succeeded)
        #expect(ActivityStatus.of(call(state: .running)) == .running)
        #expect(ActivityStatus.of(call(state: .inputStreaming)) == .pending)
        #expect(ActivityStatus.of(call(state: .error, output: "boom", isError: true)) == .failed)
    }

    @Test func tellsADeclinedCallAndAnInterruptedOneApartFromAFailure() {
        #expect(ActivityStatus.of(call(state: .error,
            output: "The user doesn't want to proceed with this tool use. The tool use was rejected",
            isError: true)) == .rejected)
        #expect(ActivityStatus.of(call(state: .error,
            output: "[Request interrupted by user for tool use]", isError: true)) == .cancelled)
    }

    @Test func letsAPendingPermissionWin() {
        #expect(ActivityStatus.of(call(), awaiting: true) == .awaiting)
    }

    @Test func ranksLiveOverWaitingOverFailedOverDone() {
        #expect(ActivityStatus.combine([.succeeded, .running, .failed]) == .running)
        #expect(ActivityStatus.combine([.failed, .awaiting]) == .awaiting)
        #expect(ActivityStatus.combine([.succeeded, .rejected]) == .failed)
        #expect(ActivityStatus.combine([.succeeded, .cancelled]) == .succeeded)
        #expect(ActivityStatus.combine([.cancelled, .cancelled]) == .cancelled)
    }
}
