import Testing
@testable import Codeg

struct ActivityToolFactsTests {
    @Test func recognisesEveryBackgroundLaunchWording() {
        #expect(ActivityToolFacts.backgroundLaunchTaskId("Command running in background with ID: b1a2. Output is being written to …") == "b1a2")
        #expect(ActivityToolFacts.backgroundLaunchTaskId("Command was manually backgrounded by user with ID: x_9") == "x_9")
        #expect(ActivityToolFacts.backgroundLaunchTaskId("Command was moved to the background (ID: abc). ") == "abc")
        #expect(ActivityToolFacts.backgroundLaunchTaskId("Command did not complete within its 120s timeout and was moved to the background (ID: t-1)") == "t-1")
        #expect(ActivityToolFacts.backgroundLaunchTaskId("Background task 42 started") == "42")
        #expect(ActivityToolFacts.backgroundLaunchTaskId("Command moved to the background (shell ID: sh_7).") == "sh_7")
        #expect(ActivityToolFacts.backgroundLaunchTaskId("all done") == nil)
    }

    @Test func delegateToolSpellings() {
        #expect(ActivityToolFacts.isDelegateToAgentToolName("delegate_to_agent"))
        #expect(ActivityToolFacts.isDelegateToAgentToolName("mcp__codeg-mcp__delegate_to_agent"))
        #expect(ActivityToolFacts.isDelegateToAgentToolName("codeg-mcp/delegate_to_agent"))
        #expect(!ActivityToolFacts.isDelegateToAgentToolName("redelegate_to_agent"))
    }

    @Test func announcedSessionNeedsALineOfItsOwn() {
        #expect(ActivityToolFacts.announcedSessionId("start\nSESSION_ID=17983\nmore") == "17983")
        #expect(ActivityToolFacts.announcedSessionId("echo SESSION_ID=1 here") == nil)
    }
}
