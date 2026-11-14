import Foundation
import Testing
@testable import Codeg

/// Web `src/lib/fuzzy-text-match.test.ts`, ported case for case.
@Suite struct FuzzyTextMatchTests {
    private struct Item: Equatable {
        var id = 0
        var name: String
        var tag: String? = nil
    }

    @Test func subsequenceMatchesContiguousAndGapped() {
        #expect(FuzzyTextMatch.subsequenceFirstIndex("bmadhelp", "bmad-help") == 0)
        #expect(FuzzyTextMatch.subsequenceFirstIndex("bmhp", "bmad-help") == 0)
        #expect(FuzzyTextMatch.subsequenceFirstIndex("help", "bmad-help") == 5)
        #expect(FuzzyTextMatch.subsequenceFirstIndex("bmadx", "bmad-help") == -1)
    }

    @Test func tiersOrderExactPrefixSubstringSubsequence() throws {
        let exact = try #require(FuzzyTextMatch.score("help", "help"))
        let prefix = try #require(FuzzyTextMatch.score("help", "help-me"))
        let substring = try #require(FuzzyTextMatch.score("help", "bmad-help"))
        let subsequence = try #require(FuzzyTextMatch.score("bmhp", "bmad-help"))
        #expect(exact > prefix)
        #expect(prefix > substring)
        let gapped = try #require(FuzzyTextMatch.score("bmadh", "bmad-help"))
        let contiguous = try #require(FuzzyTextMatch.score("bmad-", "bmad-help"))
        #expect(gapped < contiguous)
        #expect(subsequence > 0)
        #expect(FuzzyTextMatch.score("zzz", "bmad-help") == nil)
    }

    private let commands = [
        Item(name: "bmad-help", tag: "Show BMAD help"),
        Item(name: "bmad-create-story", tag: "Create a story"),
        Item(name: "clear", tag: "Clear the chat"),
    ]

    @Test func anEmptyQueryKeepsEverythingInOrder() {
        #expect(FuzzyTextMatch.rank("", commands, primary: { $0.name }) == commands)
        #expect(FuzzyTextMatch.rank("   ", commands, primary: { $0.name }) == commands)
    }

    @Test func hyphenatedNamesMatchBySubsequence() {
        #expect(FuzzyTextMatch.rank("bmadhelp", commands, primary: { $0.name }).map(\.name) == ["bmad-help"])
        #expect(FuzzyTextMatch.rank("bmhp", commands, primary: { $0.name }).map(\.name).contains("bmad-help"))
    }

    @Test func exactBeatsPrefixBeatsSubsequenceAndShorterWinsTies() {
        let items = [Item(name: "batch"), Item(name: "bh-tool"), Item(name: "bh"), Item(name: "bmad-help")]
        #expect(FuzzyTextMatch.rank("bh", items, primary: { $0.name }).map(\.name)
                == ["bh", "bh-tool", "batch", "bmad-help"])
    }

    @Test func anyPrimaryMatchOutranksAnySecondaryMatch() {
        let items = [Item(name: "zzz", tag: "bh"), Item(name: "batch", tag: "zzz")]
        #expect(FuzzyTextMatch.rank("bh", items, primary: { $0.name }, secondary: { $0.tag }).map(\.name)
                == ["batch", "zzz"])
    }

    @Test func equalScoresKeepTheirInputOrder() {
        let items = [Item(id: 1, name: "abc"), Item(id: 2, name: "abc"), Item(id: 3, name: "abc")]
        #expect(FuzzyTextMatch.rank("abc", items, primary: { $0.name }).map(\.id) == [1, 2, 3])
    }

    @Test func anEmptyPrimaryNeverMatches() {
        let items = [Item(name: ""), Item(name: "bmad-help")]
        #expect(FuzzyTextMatch.rank("bmad", items, primary: { $0.name }).map(\.name) == ["bmad-help"])
    }

    @Test func theSecondaryFieldFallsInBelowPrimaryHits() {
        let items = [Item(name: "clear", tag: "bmad helpers"), Item(name: "bmad-help", tag: "other")]
        let ranked = FuzzyTextMatch.rank("bmad", items, primary: { $0.name }, secondary: { $0.tag })
        #expect(ranked.first?.name == "bmad-help")
        #expect(ranked.map(\.name).contains("clear"))
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(FuzzyTextMatch.rank("BMADHELP", commands, primary: { $0.name }).map(\.name) == ["bmad-help"])
    }

    @Test func positionsCountUTF16Units() throws {
        // An emoji is two units: a substring after it starts at 2, like JS.
        let after = try #require(FuzzyTextMatch.score("ab", "😀ab"))
        let atStart = try #require(FuzzyTextMatch.score("ab", "xab"))
        #expect(after < atStart, "two units in beats one unit in")
    }
}
