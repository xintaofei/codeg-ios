import Testing
@testable import Codeg

/// `src/lib/activity/short-path.test.ts` plus the JSON readers' edge cases.
struct ActivityFormatTests {
    @Test func shortPathKeepsTheLastTwoPosixSegments() {
        #expect(ActivityFormat.shortPath("/home/me/repo/src/a.ts") == "src/a.ts")
        #expect(ActivityFormat.shortPath("/home/a.ts") == "home/a.ts")
    }

    @Test func shortPathKeepsTheLastTwoWindowsSegments() {
        #expect(ActivityFormat.shortPath("C:\\work\\repo\\src\\a.ts") == "src\\a.ts")
        #expect(ActivityFormat.shortPath("\\\\server\\share\\repo\\a.ts") == "repo\\a.ts")
    }

    @Test func shortPathLeavesShortPathsAlone() {
        #expect(ActivityFormat.shortPath("a.ts") == "a.ts")
        #expect(ActivityFormat.shortPath("src/a.ts") == "src/a.ts")
        #expect(ActivityFormat.shortPath("src\\a.ts") == "src\\a.ts")
    }

    @Test func countLinesIgnoresOneTrailingNewline() {
        #expect(ActivityFormat.countLines("") == 0)
        #expect(ActivityFormat.countLines("a") == 1)
        #expect(ActivityFormat.countLines("a\n") == 1)
        #expect(ActivityFormat.countLines("a\nb\n\n") == 3)
        #expect(ActivityFormat.countLines("a\r\n") == 1)
        #expect(ActivityFormat.countLines("a\r\nb\r\n") == 2)
    }

    @Test func splitPathForDisplay() {
        let split = ActivityFormat.splitPathForDisplay("agent/src/query_tasks.py")
        #expect(split.dir == "agent/src/")
        #expect(split.name == "query_tasks.py")
        #expect(ActivityFormat.splitPathForDisplay("a.py").dir == "")
    }

    @Test func previewLineStripsInlineMarkdown() {
        #expect(ActivityFormat.previewLine("\n## **Bold** `code` [link](http://x)\nrest", 80) == "Bold code link")
        #expect(ActivityFormat.previewLine("abcdef", 4) == "abc…")
        #expect(ActivityFormat.previewLine("  \n ", 10) == nil)
    }
}

struct ActivityJSONTests {
    @Test func booleansAreNotNumbers() {
        let obj = ActivityJSON.tryParse(#"{"a": true, "b": 1, "c": 1.5}"#)!
        #expect(ActivityJSON.num(obj, "a") == nil)
        #expect(ActivityJSON.num(obj, "b") == 1)
        #expect(ActivityJSON.int(obj["c"]) == nil)
    }

    @Test func tryParseOnlyAcceptsObjects() {
        #expect(ActivityJSON.tryParse("[1]") == nil)
        #expect(ActivityJSON.tryParse("nope") == nil)
        #expect(ActivityJSON.tryParse(#"{"k":"v"}"#)?["k"] as? String == "v")
    }

    @Test func extractFieldWorksOnTruncatedJSON() {
        #expect(ActivityJSON.extractField(#"{"command": "echo \"hi\"", "x": "#, key: "command") == #"echo "hi""#)
    }

    @Test func deepSearchLooksThroughEnvelopesAndStringifiedObjects() {
        let value: Any = ["arguments": #"{"file_path": "/a/b.ts"}"#]
        #expect(ActivityJSON.findStringFieldDeep(value, key: "file_path") == "/a/b.ts")
        #expect(ActivityJSON.findObjectFieldDeep(["input": ["changes": ["k": 1]]], key: "changes") != nil)
        #expect(ActivityJSON.findStringFieldDeep(["x": "  "], key: "x") == nil)
    }
}
