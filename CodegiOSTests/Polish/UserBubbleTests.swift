import SwiftUI
import Testing
@testable import Codeg

/// The user's message bubble, rounded all the way.
struct UserBubbleTests {
    @Test func theUserBubbleIsAPillOnOneLineAndRoundAllTheWayOnMore() {
        let line = CGRect(x: 0, y: 0, width: 300, height: 44)
        #expect(UserBubbleShape().path(in: line) == Capsule(style: .continuous).path(in: line))
        let tall = CGRect(x: 0, y: 0, width: 300, height: 120)
        #expect(UserBubbleShape().path(in: tall)
                == RoundedRectangle(cornerRadius: 22, style: .continuous).path(in: tall))
    }
}
