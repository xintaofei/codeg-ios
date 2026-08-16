import XCTest
@testable import Codeg

final class SessionListVisibilityTests: XCTestCase {
    func testDefaultHidesCompletedOnly() {
        XCTAssertTrue(SessionListVisibility.isVisible(conv(.inProgress), showCompleted: false))
        XCTAssertTrue(SessionListVisibility.isVisible(conv(.pendingReview), showCompleted: false))
        XCTAssertTrue(SessionListVisibility.isVisible(conv(.cancelled), showCompleted: false))
        XCTAssertFalse(SessionListVisibility.isVisible(conv(.completed), showCompleted: false))
    }

    func testShowCompletedRevealsFinishedRows() {
        XCTAssertTrue(SessionListVisibility.isVisible(conv(.completed), showCompleted: true))
    }

    func testPinnedCompletedStaysVisibleWhenFilterIsOff() {
        XCTAssertTrue(
            SessionListVisibility.isVisible(conv(.completed, pinned: true), showCompleted: false)
        )
    }

    func testFilterKeepsOrderAndDropsHidden() {
        let rows = [
            conv(.inProgress, id: 1),
            conv(.completed, id: 2),
            conv(.completed, pinned: true, id: 3),
            conv(.cancelled, id: 4),
        ]
        let visible = SessionListVisibility.filter(rows, showCompleted: false)
        XCTAssertEqual(visible.map(\.id), [1, 3, 4])
    }

    func testPrefsDefaultOff() {
        let key = "codeg.sessions.showCompleted"
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(SessionListPrefs.showCompleted)
        SessionListPrefs.showCompleted = true
        XCTAssertTrue(SessionListPrefs.showCompleted)
        SessionListPrefs.showCompleted = false
        XCTAssertFalse(SessionListPrefs.showCompleted)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func conv(
        _ status: ConversationStatus,
        pinned: Bool = false,
        id: Int = 1
    ) -> ConversationSummary {
        ConversationSummary(
            id: id,
            folderId: 1,
            title: "t\(id)",
            agentType: .claudeCode,
            status: status,
            model: nil,
            gitBranch: nil,
            externalId: nil,
            messageCount: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            pinnedAt: pinned ? Date(timeIntervalSince1970: 1) : nil
        )
    }
}
