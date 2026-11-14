import Foundation
import Testing
@testable import Codeg

/// A JSON text already written out, nested verbatim by ``stringify(_:)``.
private struct RawJSON { var text: String }

/// `JSON.stringify` of an object literal: keys in the order given, slashes
/// unescaped (JavaScript does not write `\/`).
private func stringify(_ pairs: KeyValuePairs<String, Any>) -> String {
    func fragment(_ value: Any) -> String {
        if let raw = value as? RawJSON { return raw.text }
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    return "{" + pairs.map { "\(fragment($0.key)):\(fragment($0.value))" }.joined(separator: ",") + "}"
}

/// `src/lib/activity/edit.test.ts`, plus the iOS-only JavaScript semantics
/// (object key order, `\n`-only line splitting).
struct ActivityEditTests {
    // MARK: changedLineRangeFromUnifiedDiff

    @Test("spans only the changed lines, not the context around them")
    func spansOnlyChangedLines() {
        let diff = [
            "--- a/q.py",
            "+++ b/q.py",
            "@@ -42,4 +42,6 @@",
            " .model_copy(",
            "     {",
            #"-        "source_bindings": tuple(b for b in item.source_bindings),"#,
            #"+        "source_bindings": tuple("#,
            "+            b for b in item.source_bindings if b.active",
            "+        ),",
            "     }",
        ].joined(separator: "\n")
        #expect(ActivityEdit.changedLineRangeFromUnifiedDiff(diff) == 44...46)
    }

    @Test("covers every hunk of the file")
    func coversEveryHunk() {
        let diff = [
            "@@ -3,1 +3,1 @@",
            "-a",
            "+b",
            "@@ -90,2 +90,3 @@",
            " x",
            "+y",
            " z",
        ].joined(separator: "\n")
        #expect(ActivityEdit.changedLineRangeFromUnifiedDiff(diff) == 3...91)
    }

    @Test("returns null without hunk headers")
    func nullWithoutHunkHeaders() {
        #expect(ActivityEdit.changedLineRangeFromUnifiedDiff("+a\n-b") == nil)
    }

    // MARK: describeEditFiles

    @Test("reads every file of an apply_patch with its own counts")
    func readsEveryApplyPatchFile() {
        let patch = [
            "*** Begin Patch",
            "*** Update File: src/a.ts",
            "@@",
            "-old",
            "+new",
            "+more",
            "*** Add File: src/b.ts",
            "+export {}",
            "*** Update File: src/c.ts",
            "*** Move to: src/d.ts",
            "-x",
            "*** End Patch",
        ].joined(separator: "\n")
        #expect(ActivityEdit.describeEditFiles(toolName: "apply_patch", input: stringify(["input": patch]), output: nil) == [
            EditFileChange(path: "src/a.ts", op: .update, additions: 2, deletions: 1, lineRange: nil),
            EditFileChange(path: "src/b.ts", op: .add, additions: 1, deletions: 0, lineRange: nil),
            EditFileChange(path: "src/d.ts", fromPath: "src/c.ts", op: .move, additions: 0, deletions: 1, lineRange: nil),
        ])
    }

    @Test("uses the injected start line for a live Claude edit")
    func usesInjectedStartLine() {
        let input = stringify([
            "file_path": "/repo/q.py",
            "old_string": "a\nb\nc",
            "new_string": "a\nB1\nB2\nc",
            "_start_line": 40,
        ])
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: input, output: nil) == [
            EditFileChange(path: "/repo/q.py", op: .update, additions: 2, deletions: 1, lineRange: 41...42),
        ])
    }

    @Test("prefers the rebuilt structured patch in a reloaded Claude edit")
    func prefersRebuiltStructuredPatch() {
        let input = stringify(["file_path": "/repo/q.py", "old_string": "x", "new_string": "y"])
        let output = "--- a/q.py\n+++ b/q.py\n@@ -7,1 +7,1 @@\n-x\n+y"
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: input, output: output) == [
            EditFileChange(path: "/repo/q.py", op: .update, additions: 1, deletions: 1, lineRange: 7...7),
        ])
    }

    @Test("does not guess a range for replace_all or a missing start line")
    func noRangeForReplaceAll() {
        let input = stringify([
            "file_path": "/repo/q.py",
            "old_string": "x",
            "new_string": "y",
            "replace_all": true,
            "_start_line": 3,
        ])
        let first = ActivityEdit.describeEditFiles(toolName: "edit", input: input, output: nil).first
        #expect(first != nil)
        #expect(first?.lineRange == nil)
    }

    @Test("reads codex's changes map")
    func readsCodexChangesMap() {
        let input = stringify([
            "changes": RawJSON(text: stringify([
                "src/a.ts": RawJSON(text: stringify(["unified_diff": "@@ -1,1 +1,2 @@\n a\n+b"])),
                "src/new.ts": RawJSON(text: stringify(["content": "x\ny"])),
            ])),
        ])
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: input, output: nil) == [
            EditFileChange(path: "src/a.ts", op: .update, additions: 1, deletions: 0, lineRange: 2...2),
            EditFileChange(path: "src/new.ts", op: .add, additions: 2, deletions: 0, lineRange: nil),
        ])
    }

    @Test("counts a Write as new content and leaves a notebook edit uncounted")
    func countsWriteLeavesNotebookUncounted() {
        #expect(ActivityEdit.describeEditFiles(
            toolName: "write",
            input: stringify(["file_path": "/r/a.md", "content": "1\n2\n3\n"]),
            output: nil
        ) == [
            EditFileChange(path: "/r/a.md", op: .write, additions: 3, deletions: nil, lineRange: nil),
        ])
        let notebook = ActivityEdit.describeEditFiles(
            toolName: "notebookedit",
            input: stringify(["notebook_path": "/r/n.ipynb", "new_source": "x"]),
            output: nil
        ).first
        #expect(notebook?.path == "/r/n.ipynb")
        #expect(notebook != nil && notebook?.additions == nil && notebook?.deletions == nil)
    }

    @Test("accepts OpenCode's camelCase spelling")
    func acceptsCamelCase() {
        let input = stringify(["filePath": "/r/a.ts", "oldString": "a", "newString": "b"])
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: input, output: nil) == [
            EditFileChange(path: "/r/a.ts", op: .update, additions: 1, deletions: 1, lineRange: nil),
        ])
    }

    @Test("returns nothing for an empty payload")
    func nothingForEmptyPayload() {
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: nil, output: nil).isEmpty)
    }

    // MARK: editDiffText

    // OpenCode 2 names the file `path` on edit and write
    // (packages/core/src/tool/plugin/{edit,write}.ts, 2.2.0 capture).
    @Test("heads an OpenCode 2 write's diff with its path")
    func headsOpenCodeWriteDiff() {
        let diff = ActivityEdit.editDiffText(
            toolName: "write",
            input: stringify(["path": "new.txt", "content": "alpha\nbeta\n"]),
            output: "Created file successfully: new.txt"
        )
        #expect(diff.map { Array($0.text.components(separatedBy: "\n").prefix(2)) } == ["--- a/new.txt", "+++ b/new.txt"])
    }

    @Test("heads an OpenCode 2 edit's diff with its path")
    func headsOpenCodeEditDiff() {
        let diff = ActivityEdit.editDiffText(
            toolName: "edit",
            input: stringify(["path": "new.txt", "oldString": "beta", "newString": "gamma"]),
            output: "Edited new.txt (1 replacement)"
        )
        #expect(diff.map { Array($0.text.components(separatedBy: "\n").prefix(2)) } == ["--- a/new.txt", "+++ b/new.txt"])
    }

    // MARK: iOS-only: JavaScript semantics

    @Test("lists a changes map in its source order, not sorted")
    func changesMapKeepsSourceOrder() {
        let input = stringify([
            "changes": RawJSON(text: stringify([
                "z.ts": RawJSON(text: stringify(["content": "x"])),
                "a.ts": RawJSON(text: stringify(["content": "y"])),
            ])),
        ])
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: input, output: nil).map(\.path) == ["z.ts", "a.ts"])
    }

    @Test("takes a change record's unnamed strings as old then new in source order")
    func fallbackStringsKeepSourceOrder() {
        // Neither key is a known old/new key; both match the likely-change
        // pattern, so the first in source order is the old text.
        let input = #"{"changes":{"f.ts":{"value_z":"a\nb","value_a":"a\nc\nd"}}}"#
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: input, output: nil) == [
            EditFileChange(path: "f.ts", op: .update, additions: 2, deletions: 1, lineRange: nil),
        ])
    }

    @Test("splits on \\n only, so a CRLF diff keeps its \\r and still parses")
    func crlfDiff() {
        let diff = "--- a/f\r\n+++ b/f\r\n@@ -5,1 +5,2 @@\r\n-x\r\n+y\r\n+z\r\n"
        #expect(ActivityEdit.changedLineRangeFromUnifiedDiff(diff) == 5...6)
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: diff, output: nil) == [
            EditFileChange(path: "f", op: .update, additions: 2, deletions: 1, lineRange: 5...6),
        ])
    }

    @Test("moves a generated diff's hunks to the injected start line")
    func startLineAdjustsHunks() {
        let input = stringify(["file_path": "q.py", "old_string": "a", "new_string": "b", "_start_line": 12])
        let diff = ActivityEdit.editDiffText(toolName: "edit", input: input, output: nil)
        #expect(diff == EditDiff(text: "--- a/q.py\n+++ b/q.py\n@@ -12,1 +12,1 @@\n-a\n+b", numbered: true))
    }

    @Test("reads a bare multi-file unified diff as one uncounted entry per file")
    func bareMultiFileDiff() {
        let diff = "--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n-a\n+b\n--- a/y.ts\n+++ b/y.ts\n@@ -1 +1 @@\n-c\n+d"
        #expect(ActivityEdit.describeEditFiles(toolName: "edit", input: diff, output: nil) == [
            EditFileChange(path: "x.ts", op: .update, additions: nil, deletions: nil, lineRange: nil),
            EditFileChange(path: "y.ts", op: .update, additions: nil, deletions: nil, lineRange: nil),
        ])
    }
}
