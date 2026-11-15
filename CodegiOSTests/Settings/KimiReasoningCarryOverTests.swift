import Foundation
import Testing
@testable import Codeg

/// An API-key save rebuilds Kimi's managed model block, so a reasoning
/// declaration the save doesn't edit has to go back out as it is on disk.
struct KimiReasoningCarryOverTests {
    private let thinkingOn = #"""
    {"interfaceType":"kimi","modelId":"kimi-k2","hasManagedBlock":true,
     "capabilities":["thinking","image_in"," "],
     "supportEfforts":[" low","medium","high",""],"defaultEffort":"high"}
    """#

    private func apiKeySave() -> UpdateKimiCodeConfigBody {
        UpdateKimiCodeConfigBody(mode: "apikey", interfaceType: "kimi", apiKey: "sk-new", model: "kimi-k2")
    }

    private func encoded(_ body: UpdateKimiCodeConfigBody) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any] ?? [:]
    }

    @Test func theProjectionsReasoningIsRead() {
        let c = KimiManagedConfig.parse(thinkingOn)
        #expect(c.capabilities == ["thinking", "image_in"])
        #expect(c.supportEfforts == ["low", "medium", "high"])
        #expect(c.defaultEffort == "high")
        #expect(c.reasoningEnabled)
        #expect(!c.alwaysThinking)
    }

    @Test func alwaysThinkingCountsAsReasoningOn() {
        let c = KimiManagedConfig.parse(#"{"capabilities":["always_thinking"]}"#)
        #expect(c.reasoningEnabled)
        #expect(c.alwaysThinking)
    }

    @Test func anAPIKeySaveCarriesTheDeclarationOnDisk() throws {
        let json = try encoded(kimiBodyForSave(apiKeySave(), freshConfigJson: thinkingOn))
        #expect(json["reasoningEnabled"] as? Bool == true)
        #expect(json["alwaysThinking"] as? Bool == false)
        #expect(json["supportEfforts"] as? [String] == ["low", "medium", "high"])
        #expect(json["defaultEffort"] as? String == "high")
        #expect(json["apiKey"] as? String == "sk-new")
    }

    @Test func reasoningOffOnDiskStaysOff() throws {
        let json = try encoded(kimiBodyForSave(apiKeySave(), freshConfigJson: #"{"interfaceType":"kimi","hasManagedBlock":true}"#))
        #expect(json["reasoningEnabled"] as? Bool == false)
        #expect(json["supportEfforts"] as? [String] == [])
        #expect(json["defaultEffort"] == nil)
    }

    @Test func loginAndRawSavesPassThrough() throws {
        let login = try encoded(kimiBodyForSave(UpdateKimiCodeConfigBody(mode: "login"), freshConfigJson: thinkingOn))
        #expect(login["reasoningEnabled"] == nil)
        let raw = try encoded(kimiBodyForSave(UpdateKimiCodeConfigBody(mode: "raw", rawConfigToml: "x = 1"),
                                              freshConfigJson: thinkingOn))
        #expect(raw["supportEfforts"] == nil)
        #expect(raw["rawConfigToml"] as? String == "x = 1")
    }
}
