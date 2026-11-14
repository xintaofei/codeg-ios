import Foundation
import Testing
@testable import Codeg

/// `src/lib/activity/progress.test.ts`.
struct ActivityProgressTests {
    // MARK: progressFromReport

    @Test func progressFromReportReadsTheBrokersProgress() {
        let report: [String: Any] = [
            "steps": 4,
            "marks": ["ok", "failed", "ok", "ok"],
            "last_step": "pnpm test\nmore",
        ]
        #expect(ActivityProgress.progressFromReport(report)
            == StepProgress(steps: 4, marks: [.ok, .failed, .ok, .ok], lastStep: "pnpm test"))
    }

    @Test func progressFromReportKeepsWhatItCanOfAMalformedOne() {
        #expect(ActivityProgress.progressFromReport(nil) == nil)
        #expect(ActivityProgress.progressFromReport(["marks": ["ok"]]) == nil)
        #expect(ActivityProgress.progressFromReport(["steps": -1]) == nil)
        let odd = ActivityProgress.progressFromReport(["steps": 1, "marks": ["ok", "maybe", "ok"]] as [String: Any])
        // Never fewer steps than the marks it draws.
        #expect(odd == StepProgress(steps: 2, marks: [.ok, .ok], lastStep: nil))
    }

    @Test func progressFromReportDoesNotReadABooleanAsAStepCount() {
        let parsed = try! JSONSerialization.jsonObject(with: Data(#"{"steps": true}"#.utf8))
        #expect(ActivityProgress.progressFromReport(parsed) == nil)
        let fractional = try! JSONSerialization.jsonObject(with: Data(#"{"steps": 1.5}"#.utf8))
        #expect(ActivityProgress.progressFromReport(fractional) == nil)
    }

    // MARK: progressFromLiveContent

    private func call(_ status: String, _ title: String) -> ActivityProgress.LiveBlock {
        .init(type: "tool_call", info: .init(status: status, title: title))
    }

    @Test func progressFromLiveContentTalliesALiveTurnsFinishedCallsInTheOrderTheyStarted() {
        let content: [ActivityProgress.LiveBlock] = [
            .init(type: "text"),
            call("completed", "Read a.ts"),
            call("failed", "pnpm test"),
            .init(type: "thinking"),
            call("in_progress", "Edit a.ts"),
        ]
        #expect(ActivityProgress.progressFromLiveContent(content)
            == StepProgress(steps: 2, marks: [.ok, .failed], lastStep: "Edit a.ts"))
    }

    @Test func progressFromLiveContentHasNothingForATurnThatCalledNoTool() {
        #expect(ActivityProgress.progressFromLiveContent([ActivityProgress.LiveBlock(type: "text")]) == nil)
    }

    // MARK: tallySteps

    @Test func tallyStepsDrawsTheLatestMarksAndCountsTheRest() {
        let max = ActivityProgress.maxStepMarks
        let steps = (0..<(max + 2)).map { i in
            TalliedStep(mark: i == 0 ? .failed : .ok, title: "step \(i)")
        }
        let progress = ActivityProgress.tallySteps(steps)
        #expect(progress?.steps == max + 2)
        #expect(progress?.marks.count == max)
        #expect(progress?.marks.contains(.failed) == false)
        #expect(progress?.lastStep == "step \(max + 1)")
    }

    // MARK: progressKey

    @Test func progressKeyChangesExactlyWhenTheDrawnProgressDoes() {
        let a = StepProgress(steps: 1, marks: [.ok], lastStep: "x")
        var sameMarks = a
        sameMarks.marks = [.ok]
        var otherStep = a
        otherStep.lastStep = "y"
        #expect(ActivityProgress.progressKey(a) == ActivityProgress.progressKey(sameMarks))
        #expect(ActivityProgress.progressKey(a) != ActivityProgress.progressKey(otherStep))
        #expect(ActivityProgress.progressKey(nil) == "")
    }
}
