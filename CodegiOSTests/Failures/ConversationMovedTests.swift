import Foundation
import Testing
@testable import Codeg

/// Port of the web's `src/lib/conversation-moved.test.ts` (codeg 0.44). The
/// "already-typed error" case has no counterpart: iOS only ever reads the
/// server's message.
@Suite struct ConversationMovedTests {
    @Test func readsTheBareDisplayStringAndItsFolder() {
        #expect(ConversationMoved.from(message: "conversation moved to another folder (folder 12)")?.folderId == 12)
    }

    @Test func readsTheHttpRejection() {
        let error = APIError.server(status: 400, code: "invalid_input",
                                    message: "conversation moved to another folder (folder 3)")
        #expect(ConversationMoved.from(error) == ConversationMoved(folderId: 3))
    }

    @Test func keepsTheMarkerEvenIfTheFolderIsNotNamed() {
        let moved = ConversationMoved.from(message: "conversation moved to another folder")
        #expect(moved != nil)
        #expect(moved?.folderId == nil)
    }

    @Test func isNilForAnyOtherFailure() {
        #expect(ConversationMoved.from(message: "turn already in progress") == nil)
        #expect(ConversationMoved.from(APIError.turnInProgress) == nil)
        #expect(ConversationMoved.from(APIError.transport("boom")) == nil)
        #expect(ConversationMoved.from(CancellationError()) == nil)
    }
}
