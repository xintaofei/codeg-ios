import Foundation
import Testing
@testable import Codeg

/// A link closes a group's fullscreen list — which keeps a stack of its own —
/// so where the link went isn't left hidden under it: every link that takes
/// the app somewhere is counted, and only those.
@MainActor
struct LinkArrivalsTests {
    private func model() -> AppModel {
        let defaults = UserDefaults(suiteName: "LinkArrivalsTests-\(UUID().uuidString)")!
        let model = AppModel(serverStore: ServerStore(defaults: defaults))
        model.isCompact = true
        return model
    }

    @Test func aLinkThatGoesSomewhereIsCounted() throws {
        let model = model()
        model.handle(url: try #require(URL(string: "codeg://conversation/42")))
        #expect(model.linkArrivals == 1)
        #expect(model.paths[.chats] == [.conversation(42)])

        model.handle(url: try #require(URL(string: "codeg://project/7")))
        #expect(model.linkArrivals == 2)

        model.handle(url: try #require(URL(string: "codeg://tab/activity")))
        #expect(model.linkArrivals == 3)
        #expect(model.selectedTab == .activity)
    }

    @Test func aLinkThatGoesNowhereIsNot() throws {
        let model = model()
        model.handle(url: try #require(URL(string: "https://example.com/conversation/42")))
        model.handle(url: try #require(URL(string: "codeg://nowhere/1")))
        model.handle(url: try #require(URL(string: "codeg://tab/nope")))
        #expect(model.linkArrivals == 0)
    }
}
