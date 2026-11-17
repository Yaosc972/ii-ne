import Foundation
import NaturalLanguage

/// 截图翻译的后端选择。rawValue 用作持久化与日志标识。
public enum TranslationBackend: String, Codable, CaseIterable, Sendable {
    case system
    case deepSeek

    public var title: String {
        switch self {
        case .system: return "系统本地翻译"
        case .deepSeek: return "OpenAI 兼容接口"
        }
    }
}

public enum TranslationError: LocalizedError, Equatable {
    /// 系统版本不支持、语言包未安装、源语言无法识别等本机能力问题。
    case unavailable(String)
    case missingCredential
    case invalidEndpoint
    case badResponse(String)
    case network(String)
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return detail
        case .invalidEndpoint: return "AI 服务地址无效，请在设置中填写完整的 http:// 或 https:// 地址"
        case .missingCredential: return "未配置 AI 服务 API Key，请打开设置中的翻译与润色页面填写"
        case .badResponse(let detail): return "文本服务返回异常：\(detail)"
        case .network(let detail): return "网络请求失败：\(detail)"
        case .httpStatus(401), .httpStatus(403): return "AI 服务拒绝访问，请在设置中检查 API Key 和权限"
        case .httpStatus(429): return "请求过于频繁或额度不足，请稍后重试并检查服务额度"
        case .httpStatus(let status) where status >= 500: return "AI 服务暂时不可用，请稍后重试"
        case .httpStatus(let status): return "请求失败（HTTP \(status)），请检查服务地址与模型设置"
        }
    }
}

public protocol TranslationProvider {
    func translate(_ text: String, to targetLanguage: String) async throws -> String
}

/// 翻译方向。auto 表示按原文语言自动互译：中文译成英文，其他译成中文。
public enum TranslationTarget: String, CaseIterable, Codable, Sendable {
    case auto
    case zh
    case en
    case ja
    case ko

    public var title: String {
        switch self {
        case .auto: return "自动"
        case .zh: return "中文"
        case .en: return "英文"
        case .ja: return "日文"
        case .ko: return "韩文"
        }
    }

    /// 工具条按钮上的短标签，保持两个字符以内。
    public var shortTitle: String {
        switch self {
        case .auto: return "自动"
        case .zh: return "中"
        case .en: return "英"
        case .ja: return "日"
        case .ko: return "韩"
        }
    }

    public var next: TranslationTarget {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

public enum TranslationTargetResolver {
    /// 明确指定方向时原样返回语言码；自动模式按原文语种选对向语言。
    public static func resolve(_ target: TranslationTarget, text: String) -> String {
        guard target == .auto else { return target.rawValue }
        if let language = detectedSourceLanguage(text) {
            return language.hasPrefix("zh") ? "en" : "zh"
        }
        return mostlyChinese(text) ? "en" : "zh"
    }

    public static func detectedSourceLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// 按汉字占比判断语种。短文本和混排都能给出稳定结果，不依赖识别模型。
    static func mostlyChinese(_ text: String) -> Bool {
        var han = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value) {
                han += 1
                letters += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
        }
        guard letters > 0 else { return false }
        return Double(han) / Double(letters) > 0.3
    }
}

/// 翻译与润色共用兼容 OpenAI 的 Chat Completions 接口。
public struct DeepSeekTranslationProvider: TranslationProvider {
    public static let defaultEndpoint = "https://api.deepseek.com/chat/completions"
    private static let timeout: TimeInterval = 20

    public struct CompletionRequest: Encodable, Equatable {
        public struct Message: Encodable, Equatable {
            public let role: String
            public let content: String

            public init(role: String, content: String) {
                self.role = role
                self.content = content
            }
        }

        public let model: String
        public let messages: [Message]
        public let stream: Bool
    }

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            let message: Message
        }
        struct Message: Decodable {
            let content: String?
        }
        let choices: [Choice]?
    }

    private let model: String
    private let endpoint: URL?
    private let loadCredential: () -> String?

    public init(
        model: String,
        endpoint: String = DeepSeekTranslationProvider.defaultEndpoint,
        loadCredential: @escaping () -> String? = { TranslationCredentialStore().load() }
    ) {
        self.model = model
        let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        self.endpoint = url.flatMap { candidate in
            guard ["https", "http"].contains(candidate.scheme?.lowercased() ?? ""),
                  let host = candidate.host, !host.isEmpty else { return nil }
            return candidate
        }
        self.loadCredential = loadCredential
    }

    public func translate(_ text: String, to targetLanguage: String) async throws -> String {
        try await complete(Self.requestBody(text: text, model: model, targetLanguage: targetLanguage))
    }

    public func rewrite(_ text: String, options: RewriteOptions) async throws -> String {
        try await complete(Self.rewriteRequestBody(text: text, model: model, options: options))
    }

    private func complete(_ body: CompletionRequest) async throws -> String {
        try Task.checkCancellation()
        guard let endpoint else { throw TranslationError.invalidEndpoint }
        guard let apiKey = loadCredential()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw TranslationError.missingCredential
        }
        let request = try Self.makeRequest(body: body, apiKey: apiKey, endpoint: endpoint)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut {
                throw TranslationError.network("请求超时，请重试")
            }
            throw TranslationError.network((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        try Task.checkCancellation()
        try Self.validateResponse(response)
        return try Self.parseResponse(data)
    }

    static func validateResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw TranslationError.badResponse("无法读取服务状态，请检查服务地址")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationError.httpStatus(response.statusCode)
        }
    }

    static func requestBody(text: String, model: String, targetLanguage: String) -> CompletionRequest {
        CompletionRequest(
            model: model,
            messages: [
                .init(
                    role: "system",
                    content: "Translate the user's text into \(targetLanguage). Output only the translation, no explanations."
                ),
                .init(role: "user", content: text),
            ],
            stream: false
        )
    }

    static func makeRequest(
        text: String,
        model: String,
        apiKey: String,
        targetLanguage: String,
        endpoint: URL
    ) throws -> URLRequest {
        try makeRequest(body: requestBody(text: text, model: model, targetLanguage: targetLanguage),
            apiKey: apiKey, endpoint: endpoint)
    }

    static func rewriteRequestBody(text: String, model: String, options: RewriteOptions) -> CompletionRequest {
        CompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: options.systemPrompt),
                .init(role: "user", content: text),
            ],
            stream: false
        )
    }

    static func makeRequest(body: CompletionRequest, apiKey: String, endpoint: URL) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func parseResponse(_ data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let content = response.choices?.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            let raw = String(data: data, encoding: .utf8) ?? "响应不是 UTF-8 文本"
            throw TranslationError.badResponse(raw)
        }
        return content
    }
}
