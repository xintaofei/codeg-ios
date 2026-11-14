import Testing
@testable import Codeg

/// `src/lib/activity/exit-meaning.test.ts` (codeg 0.44).
private func read(_ command: String, _ code: Int?, _ output: String = "") -> ExitMeaning? {
    ActivityExitMeaning.readCommandExit(command, exit: CommandExit(code: code, signal: nil), output: output)
}

struct ReadCommandExitAnswerTests {
    @Test("`%s` exiting 1 with nothing printed: %s", arguments: [
        ("rg -n 'source_bindings' src", ExitMeaning.noMatch),
        (#"grep -rn "TODO" ."#, .noMatch),
        ("egrep -q 'a|b' notes.txt", .noMatch),
        ("pgrep -f 'next dev'", .noMatch),
        ("git grep -n 'useFoo'", .noMatch),
        ("test -f package.json", .false),
        ("[ -d node_modules ]", .false),
        (#"[[ -n "$CI" ]]"#, .false),
        ("git diff --quiet", .differs),
        ("git -C repo diff --exit-code -- src", .differs),
        ("cmp -s a.bin b.bin", .differs),
        ("which python2", .notFound),
        ("command -v rustup", .notFound),
        ("printenv CODEX_HOME", .notFound),
        ("lsof -i :3000", .noMatch),
        ("pidof node", .noMatch),
        ("git check-ignore -v docs/spec.md", .noMatch),
        ("git config --get user.signingkey", .notFound),
        ("git rev-parse --verify --quiet refs/heads/topic", .notFound),
        ("git show-ref --verify --quiet refs/heads/topic", .notFound),
        ("git merge-base --is-ancestor main topic", .false),
    ])
    func exitingOneWithNothingPrinted(command: String, meaning: ExitMeaning) {
        #expect(read(command, 1) == meaning)
    }

    @Test("reads a diff's exit 1 with the diff it printed")
    func readsADiffsExit1WithTheDiffItPrinted() {
        #expect(read("diff a.txt b.txt", 1, "1c1\n< a\n---\n> b") == .differs)
    }

    @Test("leaves OpenCode 2.2.7's closing notice out of what was printed")
    func leavesOpenCode227sClosingNoticeOut() {
        #expect(read("rg -n 'nothing-here' src", 1, "Exit code: 1") == .noMatch)
        #expect(read("grep -c foo a.ts", 1, "a.ts:0\n\nExit code: unknown") == .noMatch)
        #expect(read("grep -c foo a.ts", 1, "a.ts:0\n\nExit code: 143 (SIGTERM)") == .noMatch)
    }

    @Test("reads grep -c's zero counts as no match")
    func readsGrepCsZeroCountsAsNoMatch() {
        #expect(read("grep -c foo a.ts b.ts", 1, "a.ts:0\nb.ts:0") == .noMatch)
    }

    @Test("reads a lookup's own not-found line, a builtin's shell prefix and all")
    func readsALookupsOwnNotFoundLine() {
        #expect(read("which python2", 1, "python2 not found") == .notFound)
        #expect(read("type foo", 1, "bash: type: foo: not found") == .notFound)
        #expect(read("which foo", 1, "which: no foo in (/usr/bin:/bin)") == .notFound)
    }

    @Test("reads a missing path a read-only command was pointed at")
    func readsAMissingPathAReadOnlyCommandWasPointedAt() {
        #expect(read("cat missing.txt", 1, "cat: missing.txt: No such file or directory") == .notFound)
        #expect(read("ls src/missing", 2, "ls: cannot access 'src/missing': No such file or directory") == .notFound)
        #expect(read("sed -n '1,40p' src/missing.ts", 2,
                     "sed: can't read src/missing.ts: No such file or directory") == .notFound)
    }

    @Test("takes the status from the end of a pipeline")
    func takesTheStatusFromTheEndOfAPipeline() {
        #expect(read("ps aux | grep '[n]ode server'", 1) == .noMatch)
        #expect(read("rg -l foo | head -20", 1) == nil)
    }

    @Test("looks past an `&& echo` the failing command never reached")
    func looksPastAnAndEcho() {
        #expect(read("[ -f .env ] && echo present", 1) == .false)
        #expect(read("grep -q foo f && echo found && echo done", 1) == .noMatch)
    }

    @Test("follows setup chained ahead when nothing was printed")
    func followsSetupChainedAheadWhenNothingWasPrinted() {
        #expect(read("cd /repo && rg -n foo", 1) == .noMatch)
        #expect(read("cd /missing && rg -n foo", 1, "cd: no such file or directory: /missing") == nil)
    }

    @Test("does not guess past a command ahead of it that might have failed")
    func doesNotGuessPastACommandAheadOfIt() {
        #expect(read("git status --short && rg foo", 1) == nil)
        #expect(read("pnpm build && test -f out/index.html", 1) == nil)
        // The `ls` stops the line before the pipeline runs: the missing path
        // is its, not the head's.
        #expect(read("ls .docs/p0 && grep -n A3 .docs/p0/list.md | head -5", 1,
                     "ls: .docs/p0: No such file or directory") == nil)
        #expect(read("cd repo && ps aux | grep '[n]ode'", 1) == .noMatch)
    }

    @Test("reads lists, comments, assignments, wrappers and paths")
    func readsListsCommentsAssignmentsWrappersAndPaths() {
        #expect(read("cd repo\nrg foo", 1) == .noMatch)
        #expect(read("rg foo # where is it used", 1) == .noMatch)
        #expect(read("# first look\nrg foo", 1) == .noMatch)
        #expect(read("FOO=1 grep -q x f", 1) == .noMatch)
        #expect(read("env LC_ALL=C grep -q x f", 1) == .noMatch)
        #expect(read("/usr/bin/grep -q x f", 1) == .noMatch)
        #expect(read("rg foo 2>/dev/null", 1) == .noMatch)
        #expect(read("rg foo 2>&1", 1) == .noMatch)
    }
}

struct ReadCommandExitFailureTests {
    @Test("`%s` exiting %i", arguments: [
        ("pnpm test", 1, "FAIL lib/report.test.ts\nTests: 1 failed"),
        ("rg foo src", 2, "rg: src: No such file or directory (os error 2)"),
        ("grep -rn foo .", 1, "grep: warning: recursive search of stdin"),
        ("test -f a.txt", 2, "test: too many arguments"),
        ("git diff", 1, ""),
        ("git rev-parse HEAD~3", 1, ""),
        ("git merge-base main topic", 1, ""),
        ("printenv HOME", 1, "printenv: write error"),
        ("sed -i 's/a/b/' missing", 2, "sed: missing: No such file or directory"),
        ("ls", 1, ""),
    ])
    func exiting(command: String, code: Int, output: String) {
        #expect(read(command, code, output) == nil)
    }

    @Test("leaves an exit a failure when the deciding command may not have run")
    func leavesAnExitAFailureWhenTheDecidingCommandMayNotHaveRun() {
        // An `exit` ends the line before the grep.
        #expect(read("node -e 'process.exit(1)' || exit 1; grep -q . package.json", 1) == nil)
        // The cd failed without a word: the grep never ran.
        #expect(read("cd /missing 2>/dev/null && grep -q . package.json", 1) == nil)
        // printf fails on a bad number, after the test passed.
        #expect(read("test -f package.json && printf '%d' oops 2>/dev/null >/dev/null", 1) == nil)
        // An echo whose output cannot land fails too.
        #expect(read("test -f a && echo yes > /dev/full", 1) == nil)
    }

    @Test("leaves a comparison that could not read its files a failure")
    func leavesAComparisonThatCouldNotReadItsFilesAFailure() {
        #expect(read("git diff --no-index missing-file package.json", 1,
                     "error: Could not access 'missing-file'") == nil)
        // The shell, by its full path, could not open the redirect.
        #expect(read("diff - package.json < /missing", 1, "/bin/bash: /missing: No such file or directory") == nil)
        #expect(read("diff - package.json < /missing", 1, "bash: line 1: /missing: No such file or directory") == nil)
    }

    @Test("does not read a sed that may write as a look")
    func doesNotReadASedThatMayWriteAsALook() {
        #expect(read("sed -n 'w missing-dir/result.txt' package.json", 1,
                     "sed: missing-dir/result.txt: No such file or directory") == nil)
        #expect(read("sed -E -n '1,4p' missing.ts", 1, "sed: missing.ts: No such file or directory") == nil)
    }

    @Test("leaves the shell's own complaint a failure")
    func leavesTheShellsOwnComplaintAFailure() {
        // A glob that matched nothing: zsh exits 1 before diff runs.
        #expect(read("diff a *.snap", 1, "(eval):1: no matches found: *.snap") == nil)
        // A redirect into a folder that is not there.
        #expect(read("cat a > out/x.log", 1, "zsh:1: no such file or directory: out/x.log") == nil)
    }

    @Test("does not read a line it cannot follow")
    func doesNotReadALineItCannotFollow() {
        #expect(read("set -euo pipefail; rg foo | head", 1) == nil)
        #expect(read(#"rg "$(cat pattern)" src"#, 1) == nil)
        #expect(read("rg `cat pattern` src", 1) == nil)
        #expect(read("(cd sub && rg foo)", 1) == nil)
        #expect(read("{ rg foo; }", 1) == nil)
        #expect(read("python - <<'PY'\nimport sys\nPY", 1) == nil)
        #expect(read("grep foo f &", 1) == nil)
        #expect(read("! grep -q foo f", 1) == nil)
        #expect(read("rg 'unterminated", 1) == nil)
    }

    @Test("names the failures the shell's codes stand for")
    func namesTheFailuresTheShellsCodesStandFor() {
        #expect(read("pyhton x.py", 127, "zsh:1: command not found: pyhton") == .commandNotFound)
        #expect(read("./run.sh", 126, "zsh:1: permission denied: ./run.sh") == .notExecutable)
        #expect(read("timeout 5 sleep 10", 124) == .timedOut)
        #expect(read("sleep 300", 143, "Command timed out after 2m 0s") == .timedOut)
        #expect(read("npm test", 124) == nil)
    }

    @Test("has nothing to say about a zero or unknown code")
    func hasNothingToSayAboutAZeroOrUnknownCode() {
        #expect(read("rg foo", 0) == nil)
        #expect(read("rg foo", nil) == nil)
    }
}

struct ExitMeaningsTests {
    @Test("tells an answer from a failure")
    func tellsAnAnswerFromAFailure() {
        #expect(ActivityExitMeaning.isExitAnswer(.noMatch) == true)
        #expect(ActivityExitMeaning.isExitAnswer(.notFound) == true)
        #expect(ActivityExitMeaning.isExitAnswer(.commandNotFound) == false)
        #expect(ActivityExitMeaning.isExitAnswer(nil) == false)
    }

    @Test("names the signal a 128 + n code stands for")
    func namesTheSignalA128PlusNCodeStandsFor() {
        #expect(ActivityExitMeaning.signalOfExitCode(137) == "SIGKILL")
        #expect(ActivityExitMeaning.signalOfExitCode(130) == "SIGINT")
        #expect(ActivityExitMeaning.signalOfExitCode(143) == "SIGTERM")
        #expect(ActivityExitMeaning.signalOfExitCode(1) == nil)
        #expect(ActivityExitMeaning.signalOfExitCode(nil) == nil)
    }
}
