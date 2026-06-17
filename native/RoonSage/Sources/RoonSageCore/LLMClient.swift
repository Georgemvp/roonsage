import Foundation

// MARK: - Config

public struct LLMConfig: Sendable {
    public enum Provider: String, Sendable, CaseIterable {
        case ollama    = "Ollama"
        case anthropic = "Anthropic"
        case openai    = "OpenAI"
        case custom    = "Custom"
    }
    public var provider: Provider
    public var baseURL:  String
    public var model:    String
    public var apiKey:   String

    public init(
        provider: Provider = .ollama,
        baseURL:  String   = "http://localhost:11434",
        model:    String   = "qwen3.5:4b-mlx",
        apiKey:   String   = ""
    ) {
        self.provider = provider
        self.baseURL  = baseURL
        self.model    = model
        self.apiKey   = apiKey
    }
}

// MARK: - Config store (UserDefaults + Keychain)

public enum LLMConfigStore {

    public static func load() -> LLMConfig {
        let d = UserDefaults.standard
        let p = LLMConfig.Provider(rawValue: d.string(forKey: "llm_provider") ?? "") ?? .ollama
        return LLMConfig(
            provider: p,
            baseURL:  d.string(forKey: "llm_base_url") ?? "http://localhost:11434",
            model:    d.string(forKey: "llm_model")    ?? "qwen3.5:4b-mlx",
            apiKey:   KeychainStore.load(key: "llm_apikey_\(p.rawValue)") ?? ""
        )
    }

    public static func save(_ c: LLMConfig) {
        let d = UserDefaults.standard
        d.set(c.provider.rawValue, forKey: "llm_provider")
        d.set(c.baseURL,           forKey: "llm_base_url")
        d.set(c.model,             forKey: "llm_model")
        if !c.apiKey.isEmpty {
            KeychainStore.save(key: "llm_apikey_\(c.provider.rawValue)", value: c.apiKey)
        }
    }

    public static func fetchOllamaModels(baseURL: String) async -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }
    }
}

// MARK: - Client

public actor LLMClient {

    public static let shared = LLMClient()

    /// Returns the LLM's text response.
    public func complete(system: String, user: String, config: LLMConfig) async throws -> String {
        switch config.provider {
        case .ollama:           return try await ollamaChat(system: system, user: user, config: config)
        case .anthropic:        return try await anthropicMessages(system: system, user: user, config: config)
        case .openai, .custom:  return try await openAICompletions(system: system, user: user, config: config)
        }
    }

    /// Preload the model so the first real `complete` doesn't pay the cold-start
    /// load cost (which can exceed the request timeout and silently fall back).
    /// Only meaningful for local Ollama — cloud providers have no load step.
    /// Best-effort: errors are swallowed; the real call surfaces any failure.
    /// `keep_alive` keeps the model resident long enough for a burst of calls.
    public func warmUp(config: LLMConfig) async {
        guard config.provider == .ollama,
              let url = URL(string: "\(config.baseURL)/api/generate") else { return }
        let body: [String: Any] = ["model": config.model, "keep_alive": "10m"]
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: Ollama

    private func ollamaChat(system: String, user: String, config: LLMConfig) async throws -> String {
        guard let url = URL(string: "\(config.baseURL)/api/chat") else { throw LLMError.badURL }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ],
            "stream": false,
            "think": false          // disable chain-of-thought for Qwen3 / deepseek-r1
        ]
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg  = json["message"] as? [String: Any],
              let text = msg["content"] as? String
        else { throw LLMError.invalidResponse }
        return stripThinking(text)
    }

    // MARK: Anthropic

    private func anthropicMessages(system: String, user: String, config: LLMConfig) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw LLMError.badURL }
        let model = config.model.isEmpty ? "claude-haiku-4-5-20251001" : config.model
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey,      forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text    = content.first?["text"] as? String
        else { throw LLMError.invalidResponse }
        return text
    }

    // MARK: OpenAI-compatible

    private func openAICompletions(system: String, user: String, config: LLMConfig) async throws -> String {
        let base = config.provider == .openai ? "https://api.openai.com" : config.baseURL
        guard let url = URL(string: "\(base)/v1/chat/completions") else { throw LLMError.badURL }
        let model = config.model.isEmpty ? "gpt-4.1-mini" : config.model
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ]
        ]
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json",        forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg     = choices.first?["message"] as? [String: Any],
              let text    = msg["content"] as? String
        else { throw LLMError.invalidResponse }
        return text
    }

    // MARK: Helpers

    private func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>\s*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

public enum LLMError: LocalizedError {
    case badURL
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .badURL:           "Invalid LLM endpoint URL."
        case .invalidResponse:  "Unexpected response format from LLM."
        }
    }
}
