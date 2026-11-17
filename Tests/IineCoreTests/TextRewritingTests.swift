import Foundation
import Testing
@testable import IineCore

struct TextRewritingTests {
    @Test func rewriteRequestKeepsSourceSeparateFromWritingPreferences() throws {
        let text = "明天下午三点请李老师参加会议。\n备注原文：请保留 3 个议题。"
        let options = RewriteOptions(tone: .professional, length: .longer, instruction: "用于工作邮件，请保留称呼。")
        let body = DeepSeekTranslationProvider.rewriteRequestBody(text: text, model: "configured-model", options: options)
        let endpoint = URL(string: "https://example.invalid/v1/chat/completions")!
        let request = try DeepSeekTranslationProvider.makeRequest(body: body, apiKey: "test-key", endpoint: endpoint)
        let payload = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: String]])
        let system = try #require(messages.first?["content"])

        #expect(request.url == endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(payload["model"] as? String == "configured-model")
        #expect(payload["stream"] as? Bool == false)
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1] == ["role": "user", "content": text])
        #expect(!system.contains(text))
        #expect(system.contains("original language"))
        #expect(system.contains("meaning, facts, names, numbers"))
        #expect(system.contains("professional tone"))
        #expect(system.contains("Do not invent examples or facts"))
        #expect(system.contains(options.instruction))
        #expect(system.contains("Output only the rewritten text"))
    }

    @Test func everyToneAndLengthAffectsTheRewriteRequest() {
        var instructions = Set<String>()
        for tone in RewriteTone.allCases {
            for length in RewriteLength.allCases {
                let body = DeepSeekTranslationProvider.rewriteRequestBody(text: "原文", model: "configured-model",
                    options: RewriteOptions(tone: tone, length: length))
                instructions.insert(body.messages[0].content)
                #expect(body.messages[1].content == "原文")
            }
        }
        #expect(instructions.count == RewriteTone.allCases.count * RewriteLength.allCases.count)
    }

    @Test func blankAdditionalInstructionUsesDefaultRewriteRequest() {
        let defaults = DeepSeekTranslationProvider.rewriteRequestBody(text: "原文", model: "model", options: RewriteOptions())
        let whitespace = DeepSeekTranslationProvider.rewriteRequestBody(text: "原文", model: "model",
            options: RewriteOptions(instruction: " \n\t "))
        #expect(defaults == whitespace)
        #expect(defaults.messages[0].content.contains("same length"))
        #expect(defaults.messages[0].content.contains("natural, fluent tone"))
    }

    @Test func rewritingRequiresCredentialBeforeNetworkAccess() async {
        for credential in [nil, "", " \n\t "] as [String?] {
            let provider = DeepSeekTranslationProvider(model: "model", endpoint: "https://example.invalid/v1/chat/completions",
                loadCredential: { credential })
            await #expect(throws: TranslationError.missingCredential) {
                try await provider.rewrite("请润色这段话", options: RewriteOptions())
            }
        }
    }

    @Test func whitespaceOnlyServiceResultIsAnError() {
        let payload = #"{"choices":[{"message":{"content":" \n\t "}}]}"#
        #expect(throws: TranslationError.badResponse(payload)) {
            try DeepSeekTranslationProvider.parseResponse(Data(payload.utf8))
        }
    }
}
