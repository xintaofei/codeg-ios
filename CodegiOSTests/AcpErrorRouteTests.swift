import Testing
@testable import Codeg

/// Mirrors the routing table in the web's `src/lib/acp-error-presentation.ts`.
struct AcpErrorRouteTests {
    @Test func failedTurnVerdictsFailTheTurn() {
        for code in AcpErrorRoute.failedTurnVerdicts {
            #expect(AcpErrorRoute.route(code: code, message: "m") == .failsTurn(message: "m"))
        }
    }

    @Test func codeLessErrorIsTheAgentsRejectionWithoutThePrefix() {
        #expect(AcpErrorRoute.route(code: nil, message: "ACP protocol error: Model refused")
                == .failsTurn(message: "Model refused"))
        #expect(AcpErrorRoute.route(code: "", message: "plain") == .failsTurn(message: "plain"))
    }

    @Test func turnContinuingCodesAreNotices() {
        for code in ["image_dropped", "set_mode_failed", "set_config_option_failed",
                     "goal_control_failed", "session_load_fallback",
                     "grok_model_switch_incompatible_agent", "turn_failed_refusal",
                     "turn_failed_max_tokens", "process_exited", "something_new"] {
            #expect(AcpErrorRoute.route(code: code, message: "m") == .notice(message: "m"))
        }
    }

    @Test func failedCompactionIsAlreadyOnItsCard() {
        #expect(AcpErrorRoute.route(code: "compaction_failed", message: "m") == .silent)
    }
}
