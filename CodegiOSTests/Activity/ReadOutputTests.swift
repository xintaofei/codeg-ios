import Testing
@testable import Codeg

/// `src/lib/activity/read-output.test.ts` (codeg 0.44) — tests `explore.ts`.
struct ParseReadOutputTests {
    private typealias Read = ActivityExplore.ReadOutput

    @Test("keeps the structured Claude read shape { start_line, content }")
    func keepsTheStructuredClaudeReadShape() {
        let raw = exploreFixtureJSON(["start_line": 12, "content": "line a\nline b"])
        #expect(ActivityExplore.parseReadOutput(raw) == Read(startLine: 12, content: "line a\nline b"))
    }

    @Test("returns plain non-JSON text verbatim")
    func returnsPlainNonJSONTextVerbatim() {
        #expect(ActivityExplore.parseReadOutput("just some text") == Read(startLine: 1, content: "just some text"))
    }

    @Test("unwraps a clean codex { formatted_output, exit_code } envelope")
    func unwrapsACleanCodexEnvelope() {
        // codex read commandAction output where formatted_output is already
        // clean.
        let raw = exploreFixtureJSON(["formatted_output": "---\nname: using-superpowers\n---", "exit_code": 0])
        #expect(ActivityExplore.parseReadOutput(raw) == Read(startLine: 1, content: "---\nname: using-superpowers\n---"))
    }

    @Test("strips codex CLI framing (Chunk ID / Wall time / Output:) from formatted_output")
    func stripsCodexCLIFramingFromFormattedOutput() {
        let framed = "Chunk ID: 60dc01\n"
            + "Wall time: 0.0000 seconds\n"
            + "Process exited with code 0\n"
            + "Original token count: 1475\n"
            + "Output:\n"
            + "---\nname: using-superpowers\n---"
        let raw = exploreFixtureJSON(["formatted_output": framed, "exit_code": 0])
        #expect(ActivityExplore.parseReadOutput(raw) == Read(startLine: 1, content: "---\nname: using-superpowers\n---"))
    }

    // ── regression guards (Codex review) ──────────────────────────────────

    @Test("does NOT unwrap a JSON file whose content is an object with an output-like key")
    func doesNotUnwrapAJSONFileWithAnOutputLikeKey() {
        // A genuine read of a JSON file. Without the strict { formatted_output
        // + exit_code } gate these would render only the inner value, losing
        // the file.
        let objects: [[String: Any]] = [
            ["output": "x"],
            ["stdout": "x"],
            ["text": "x"],
            ["result": "x"],
            ["exit_code": 0], // metadata-only, no formatted_output
            ["formatted_output": "x"], // formatted_output without exit_code
        ]
        for object in objects {
            let raw = exploreFixtureJSON(object)
            #expect(ActivityExplore.parseReadOutput(raw) == Read(startLine: 1, content: raw))
        }
    }

    @Test("does NOT truncate file content whose first line is literally 'Output:'")
    func doesNotTruncateFileContentWhoseFirstLineIsOutput() {
        // A real codex read envelope, but formatted_output is unframed file
        // content that happens to start with "Output:" — the envelope parser
        // must not strip it.
        let raw = exploreFixtureJSON(["formatted_output": "Output:\nthe real first line\nsecond line", "exit_code": 0])
        #expect(ActivityExplore.parseReadOutput(raw)
            == Read(startLine: 1, content: "Output:\nthe real first line\nsecond line"))
    }
}

struct CodexCommandReadOutputTests {
    @Test("requires both exit_code:number and formatted_output:string")
    func requiresBothExitCodeAndFormattedOutput() {
        #expect(ActivityExplore.codexCommandReadOutput(exploreFixtureJSON(["output": "x"])) == nil)
        #expect(ActivityExplore.codexCommandReadOutput(exploreFixtureJSON(["exit_code": 0])) == nil)
        #expect(ActivityExplore.codexCommandReadOutput(exploreFixtureJSON(["formatted_output": "x"])) == nil)
        #expect(ActivityExplore.codexCommandReadOutput("not json") == nil)
        #expect(ActivityExplore.codexCommandReadOutput(
            exploreFixtureJSON(["formatted_output": "hello", "exit_code": 0])) == "hello")
    }
}
