import Testing
@testable import Codeg

/// `src/lib/activity/command.test.ts` (codeg 0.44).
struct SimplifyShellCommandTests {
    @Test("strips nested shell wrappers")
    func stripsNestedShellWrappers() {
        #expect(ActivityCommand.simplifyShellCommand(#"/bin/zsh -lc "bash -lc 'pnpm test'""#) == "pnpm test")
    }

    @Test("leaves a plain command alone")
    func leavesAPlainCommandAlone() {
        #expect(ActivityCommand.simplifyShellCommand("git status --short") == "git status --short")
    }
}

struct ExtractDisplayCommandFromToolInputTests {
    @Test("reads command, cmd, argv and Antigravity's CommandLine")
    func readsCommandCmdArgvAndCommandLine() {
        #expect(ActivityCommand.extractDisplayCommandFromToolInput(#"{"command":"ls -la"}"#) == "ls -la")
        #expect(ActivityCommand.extractDisplayCommandFromToolInput(#"{"cmd":["bash","-lc","make"]}"#) == "make")
        #expect(ActivityCommand.extractDisplayCommandFromToolInput(#"{"CommandLine":"pnpm build"}"#) == "pnpm build")
        #expect(ActivityCommand.extractDisplayCommandFromToolInput("echo hi") == "echo hi")
    }
}

struct DetectHeredocTests {
    @Test("names the interpreter and counts the script lines")
    func namesTheInterpreterAndCountsTheScriptLines() {
        let command = [
            "agent/.venv/bin/python - <<'PY'",
            "import json",
            "print(json.dumps({}))",
            "PY",
        ].joined(separator: "\n")
        #expect(ActivityCommand.detectHeredoc(command) == HeredocCommand(
            head: "agent/.venv/bin/python - <<'PY'",
            interpreter: "python",
            bodyLines: 2))
    }

    @Test("skips env assignments when finding the interpreter")
    func skipsEnvAssignmentsWhenFindingTheInterpreter() {
        let heredoc = ActivityCommand.detectHeredoc("FOO=1 node <<EOF\nconsole.log(1)\nEOF")
        #expect(heredoc?.interpreter == "node")
        #expect(heredoc?.bodyLines == 1)
    }

    @Test("counts to the end when the closing delimiter is missing")
    func countsToTheEndWhenTheClosingDelimiterIsMissing() {
        #expect(ActivityCommand.detectHeredoc("cat <<-'END'\na\nb")?.bodyLines == 2)
    }

    @Test("ignores single-line commands and multi-line commands without one")
    func ignoresSingleLineAndMultiLineCommandsWithoutOne() {
        #expect(ActivityCommand.detectHeredoc("cat <<EOF") == nil)
        #expect(ActivityCommand.detectHeredoc("cd web &&\n  pnpm test") == nil)
    }
}

struct ExtractCommandExitTests {
    private func exit(_ code: Int?, _ signal: String? = nil) -> CommandExit {
        CommandExit(code: code, signal: signal)
    }

    @Test("reads codex's command envelope")
    func readsCodexsCommandEnvelope() {
        #expect(ActivityCommand.extractCommandExit(#"{"formatted_output":"boom","exit_code":2}"#) == exit(2))
    }

    @Test("reads a numeric exit_code on other JSON envelopes")
    func readsANumericExitCodeOnOtherJSONEnvelopes() {
        #expect(ActivityCommand.extractCommandExit(#"{"stdout":"","exit_code":127}"#) == exit(127))
    }

    @Test("reads the backend's terminal exit line, including signals")
    func readsTheBackendsTerminalExitLineIncludingSignals() {
        #expect(ActivityCommand.extractCommandExit("npm ERR!\n[terminal exited: exit code: 1]\n") == exit(1))
        #expect(ActivityCommand.extractCommandExit("[terminal exited: signal: SIGKILL]") == exit(nil, "SIGKILL"))
        #expect(ActivityCommand.extractCommandExit("[terminal exited: finished]") == nil)
    }

    @Test("reads the Exit code line inside the fence claude-agent-acp puts around a failure")
    func readsTheExitCodeLineInsideTheFence() {
        // Without a terminal channel the adapter sends a failed result fenced
        // for Markdown; history (the transcript) keeps it bare. Both read the
        // same.
        #expect(ActivityCommand.extractCommandExit(
            "```\nExit code 1\nls: /missing: No such file or directory\n```") == exit(1))
        #expect(ActivityCommand.extractCommandExit("```\nboom\n```") == nil)
    }

    @Test("reads Claude Code's leading and OpenCode's trailing Exit code line")
    func readsLeadingAndTrailingExitCodeLine() {
        #expect(ActivityCommand.extractCommandExit("Exit code 1\nFAIL src/a.test.ts") == exit(1))
        #expect(ActivityCommand.extractCommandExit("boom\n\nExit code 3") == exit(3))
    }

    @Test("reads codex's CLI framing")
    func readsCodexsCLIFraming() {
        let framed = [
            "Chunk ID: 065b2b",
            "Wall time: 0.05 seconds",
            "Process exited with code 4",
            "Output:",
            "nope",
        ].joined(separator: "\n")
        #expect(ActivityCommand.extractCommandExit(framed) == exit(4))
    }

    @Test("does not invent a code from text in the middle of the output")
    func doesNotInventACodeFromTextInTheMiddle() {
        #expect(ActivityCommand.extractCommandExit("starting\nExit code 9 is reserved\ndone") == nil)
        #expect(ActivityCommand.extractCommandExit("") == nil)
        #expect(ActivityCommand.extractCommandExit(nil) == nil)
    }

    // OpenCode 2 closes a command's result with a notice block of its own
    // (packages/core/src/shell/result.ts `notice`): the live 2.2.0 completion
    // joins its blocks, history keeps them apart — the last line reads alike.
    @Test("reads OpenCode 2's closing exit notice")
    func readsOpenCode2sClosingExitNotice() {
        let live = "ls: /definitely-not-here: No such file or directory\n\nExited with code 1"
        #expect(ActivityCommand.extractCommandExit(live) == exit(1))
        #expect(ActivityCommand.extractAgentReportedExit(live) == exit(1))
        #expect(ActivityCommand.extractAgentReportedExit("out\n\nKilled by SIGTERM") == exit(nil, "SIGTERM"))
        #expect(ActivityCommand.extractAgentReportedExit("Exited with code 3\nstill printing") == nil)
        #expect(ActivityCommand.extractAgentReportedExit("Timed out before completion") == nil)
    }

    // 2.2.7 rewords the notice (#62141): `Exit code: N`, a signal as `Exit
    // code: 143 (SIGTERM)`. The numeric code rides the call's `_meta`; only the
    // signal has to come from the text.
    @Test("reads OpenCode 2.2.7's signal notice")
    func readsOpenCode227sSignalNotice() {
        #expect(ActivityCommand.extractAgentReportedExit("out\n\nExit code: 143 (SIGTERM)") == exit(nil, "SIGTERM"))
        #expect(ActivityCommand.extractAgentReportedExit(
            "Command timed out after 1 seconds. If it needs longer and isn't waiting for input, rerun with a larger timeout.\nExit code: 137 (SIGKILL)")
            == exit(nil, "SIGKILL"))
        // Plain codes look like Claude Code's framing: a succeeded call's own
        // text, never read as the agent's status.
        #expect(ActivityCommand.extractAgentReportedExit("out\n\nExit code: 3") == nil)
        #expect(ActivityCommand.extractAgentReportedExit("Exit code: unknown") == nil)
        #expect(ActivityCommand.extractAgentReportedExit("Exit code: 143 (SIGTERM)\nstill printing") == nil)
    }
}

struct ExitFromMetaTests {
    @Test("reads the exit code a live call carries on its meta")
    func readsTheExitCodeALiveCallCarriesOnItsMeta() {
        #expect(ActivityCommand.exitFromMeta(["codeg.exitCode": 2]) == CommandExit(code: 2, signal: nil))
        #expect(ActivityCommand.exitFromMeta(["codeg.exitCode": "2"]) == nil)
        #expect(ActivityCommand.exitFromMeta(nil) == nil)
    }
}

struct WallTimeTests {
    private let framed = "Chunk ID: x\nWall time: 12.5 seconds\nOutput:\nok"

    @Test("reports milliseconds")
    func reportsMilliseconds() {
        #expect(ActivityCommand.extractWallTimeMs(framed) == 12500)
        #expect(ActivityCommand.extractWallTimeMs("no wall time") == nil)
    }
}

struct NormalizeCommandOutputTests {
    @Test("unwraps JSON envelopes, CLI framing and fences")
    func unwrapsJSONEnvelopesCLIFramingAndFences() {
        #expect(ActivityCommand.normalizeCommandOutput(#"{"stdout":"a\nb"}"#) == "a\nb")
        #expect(ActivityCommand.normalizeCommandOutput("Chunk ID: 1\nWall time: 1s\nOutput:\nhello") == "hello")
        #expect(ActivityCommand.normalizeCommandOutput("```sh\nls\n```") == "ls")
    }
}
