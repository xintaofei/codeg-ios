import Testing
@testable import Codeg

/// `src/lib/model-config-groups.test.ts`.
struct ModelOptionGroupsTests {
    private func opt(_ value: String, _ name: String? = nil) -> SessionConfigSelectOption {
        SessionConfigSelectOption(value: value, name: name ?? value, description: nil)
    }

    private func modelOption(
        _ options: [SessionConfigSelectOption],
        groups: [SessionConfigSelectGroup] = [],
        id: String = "model",
        category: String? = nil
    ) -> SessionConfigOption {
        SessionConfigOption(
            id: id, name: "Model", description: nil, category: category,
            kind: .select(currentValue: options.first?.value ?? "", options: options, groups: groups)
        )
    }

    // MARK: isModelOption

    @Test func matchesTheModelOptionByIdOrCategory() {
        #expect(ModelOptionGroups.isModelOption(modelOption([])))
        #expect(ModelOptionGroups.isModelOption(modelOption([], id: "llm", category: "model")))
        #expect(!ModelOptionGroups.isModelOption(modelOption([], id: "mode", category: "mode")))
    }

    // MARK: derive

    @Test func returnsNilForNonModelOptionsFlatListsAndServerGroups() {
        #expect(ModelOptionGroups.derive(modelOption([opt("a/b")], id: "mode", category: "mode")) == nil)
        #expect(ModelOptionGroups.derive(modelOption([opt("a"), opt("b")])) == nil)
        let served = modelOption([opt("x/a")], groups: [SessionConfigSelectGroup(group: "g", name: "G", options: [opt("x/a")])])
        #expect(ModelOptionGroups.derive(served) == nil)
    }

    @Test func groupsByTheFirstSlashAndPreservesFirstSeenOrder() {
        let groups = ModelOptionGroups.derive(modelOption([
            opt("anthropic/claude-opus"), opt("openai/gpt-4o"),
            opt("anthropic/claude-sonnet"), opt("google/gemini-2.0"),
        ]))
        #expect(groups?.map(\.name) == ["anthropic", "openai", "google"])
        let anthropic = groups?.first { $0.name == "anthropic" }
        #expect(anthropic?.options.map(\.name) == ["claude-opus", "claude-sonnet"])
        #expect(anthropic?.options.map(\.value) == ["anthropic/claude-opus", "anthropic/claude-sonnet"])
    }

    @Test func usesTheSharedDisplayNamePrefixAsHeaderAndStripsIt() {
        let groups = ModelOptionGroups.derive(modelOption([
            opt("opencode/big-pickle", "OpenCode Zen/Big Pickle"),
            opt("opencode/claude-haiku", "OpenCode Zen/Claude Haiku"),
            opt("anthropic/claude-opus", "anthropic/claude-opus"),
        ]))
        let zen = groups?.first { $0.key == "opencode" }
        #expect(zen?.name == "OpenCode Zen")
        #expect(zen?.options.map(\.name) == ["Big Pickle", "Claude Haiku"])
        #expect(zen?.options.map(\.value) == ["opencode/big-pickle", "opencode/claude-haiku"])
    }

    @Test func fallsBackToTheValuePrefixWhenNamesDontShareOne() {
        let groups = ModelOptionGroups.derive(modelOption([
            opt("anthropic/claude-opus", "Claude Opus"),
            opt("anthropic/claude-sonnet", "Claude Sonnet"),
            opt("openai/gpt-4o", "GPT-4o"),
        ]))
        let anthropic = groups?.first { $0.key == "anthropic" }
        #expect(anthropic?.name == "anthropic")
        #expect(anthropic?.options.map(\.name) == ["Claude Opus", "Claude Sonnet"])
    }

    @Test func floatsPrefixlessValuesIntoALeadingHeaderlessBucket() {
        let groups = ModelOptionGroups.derive(modelOption([
            opt("default", "Default"), opt("anthropic/opus"), opt("openai/gpt"),
        ])) ?? []
        #expect(groups.first?.name == nil)
        #expect(groups.first?.options.map(\.name) == ["Default"])
        #expect(groups.dropFirst().map(\.name) == ["anthropic", "openai"])
    }

    @Test func groupsALoneProviderOnlyWhenItsRowsRepeatAPrefix() {
        let repeated = ModelOptionGroups.derive(modelOption([opt("anthropic/opus"), opt("anthropic/sonnet")]))
        #expect(repeated?.map(\.name) == ["anthropic"])
        #expect(repeated?.first?.options.map(\.name) == ["opus", "sonnet"])

        let clean = ModelOptionGroups.derive(modelOption([opt("anthropic/opus", "Opus"), opt("anthropic/sonnet", "Sonnet")]))
        #expect(clean == nil)
    }

    @Test func doesNotMistakeALoneSlashedDisplayNameForAProviderPrefix() {
        let groups = ModelOptionGroups.derive(modelOption([
            opt("anthropic/claude-opus"), opt("meta/llama", "Big/Thing"),
        ]))
        let meta = groups?.first { $0.key == "meta" }
        #expect(meta?.name == "meta")
        #expect(meta?.options.map(\.name) == ["Big/Thing"])
    }

    @Test func groupsMultiSegmentValuesUnderTheirFirstSegment() {
        let groups = ModelOptionGroups.derive(modelOption([
            opt("openrouter/anthropic/claude"), opt("openrouter/openai/gpt"), opt("ollama/llama3"),
        ]))
        #expect(groups?.map(\.name) == ["openrouter", "ollama"])
        #expect(groups?.first?.options.map(\.name) == ["anthropic/claude", "openai/gpt"])
    }

    @Test func treatsLeadingAndTrailingSlashesAsUngroupable() {
        let groups = ModelOptionGroups.derive(modelOption([
            opt("/leading"), opt("trailing/"), opt("anthropic/opus"),
        ])) ?? []
        #expect(groups.first?.name == nil)
        #expect(groups.first?.options.map(\.value) == ["/leading", "trailing/"])
        #expect(groups.dropFirst().map(\.name) == ["anthropic"])
    }

    // MARK: listGroups

    @Test func listGroupsPrefersDerivedThenServerThenOneFlatGroup() {
        let derived = ModelOptionGroups.listGroups(modelOption([opt("anthropic/opus"), opt("openai/gpt-4o")]))
        #expect(derived.map(\.name) == ["anthropic", "openai"])

        let served = ModelOptionGroups.listGroups(modelOption([], groups: [
            SessionConfigSelectGroup(group: "fast", name: "Fast", options: [opt("a", "A"), opt("b", "B")]),
            SessionConfigSelectGroup(group: "smart", name: "Smart", options: [opt("c", "C")]),
        ]))
        #expect(served.map(\.name) == ["Fast", "Smart"])
        #expect(served.flatMap(\.options).map(\.value) == ["a", "b", "c"])

        let flat = ModelOptionGroups.listGroups(modelOption([opt("a", "A"), opt("b", "B"), opt("c", "C")]))
        #expect(flat.count == 1)
        #expect(flat.first?.name == nil)
        #expect(flat.first?.options.map(\.value) == ["a", "b", "c"])
    }

    // MARK: filter

    private var sample: [ModelOptionGroup] {
        [
            ModelOptionGroup(key: "__ungrouped__", name: nil, options: [opt("default", "Default")]),
            ModelOptionGroup(key: "anthropic", name: "anthropic", options: [opt("anthropic/opus", "opus"), opt("anthropic/sonnet", "sonnet")]),
            ModelOptionGroup(key: "openai", name: "openai", options: [opt("openai/gpt-4o", "gpt-4o")]),
        ]
    }

    @Test func returnsTheGroupsUnchangedForABlankQuery() {
        #expect(ModelOptionGroups.filter(sample, query: "   ") == sample)
    }

    @Test func matchesTheDisplayNameCaseInsensitivelyAndDropsEmptyGroups() {
        let result = ModelOptionGroups.filter(sample, query: "OPUS")
        #expect(result.map(\.key) == ["anthropic"])
        #expect(result.first?.options.map(\.value) == ["anthropic/opus"])
    }

    @Test func matchesTheValueIdEvenWhenTheLabelWasStripped() {
        #expect(ModelOptionGroups.filter(sample, query: "openai").map(\.key) == ["openai"])
    }

    @Test func returnsNothingWhenNothingMatches() {
        #expect(ModelOptionGroups.filter(sample, query: "zzz").isEmpty)
    }
}
