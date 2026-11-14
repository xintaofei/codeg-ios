import Foundation
import Testing
@testable import Codeg

/// The relative time on turn footers and navigator rows reads in the in-app
/// language: "刚刚 / 5分钟前" in Chinese, not an English "now" beside them.
@MainActor
struct RelativeTimeTests {
    private let reference = Date(timeIntervalSince1970: 1_790_000_000)
    private let chinese = Locale(identifier: "zh-Hans")
    private let english = Locale(identifier: "en")

    @Test func underAMinuteIsNowInTheGivenLanguage() {
        let moment = reference.addingTimeInterval(-10)
        #expect(RelativeTime.string(from: moment, relativeTo: reference, locale: english) == "now")
        #expect(RelativeTime.string(from: moment, relativeTo: reference, locale: chinese) == "刚刚")
    }

    @Test func olderTimesFollowTheGivenLanguage() {
        let earlier = reference.addingTimeInterval(-5 * 60)
        let zh = RelativeTime.string(from: earlier, relativeTo: reference, locale: chinese)
        let en = RelativeTime.string(from: earlier, relativeTo: reference, locale: english)
        #expect(zh.contains("5") && zh.contains("分钟"))
        #expect(en.contains("5") && en.contains("ago"))
    }
}
