import Foundation

// MARK: - Config

public struct LLMConfig: Sendable {
    public enum Provider: String, Sendable, CaseIterable {
        case ollama    = "Ollama"
        case anthropic = "Anthropic"
        case openai    = "OpenAI"
        case gemini    = "Gemini"
        case custom    = "Custom"

        /// Cloud providers authenticate with an API key; Ollama is local.
        public var needsAPIKey: Bool { self != .ollama }
        /// Self-hosted providers expose a configurable base URL.
        public var usesBaseURL: Bool { self == .ollama || self == .custom }

        /// A sane default model id when the user hasn't chosen one.
        public var defaultModel: String {
            switch self {
            case .ollama:    "qwen3:4b"
            case .anthropic: "claude-haiku-4-5-20251001"
            case .openai:    "gpt-4.1-mini"
            case .gemini:    "gemini-2.5-flash"
            case .custom:    ""
            }
        }
    }
    public var provider: Provider
    public var baseURL:  String
    public var model:    String
    public var apiKey:   String

    public init(
        provider: Provider = .ollama,
        baseURL:  String   = "http://localhost:11434",
        model:    String   = "qwen3:4b",
        apiKey:   String   = ""
    ) {
        self.provider = provider
        self.baseURL  = baseURL
        self.model    = model
        self.apiKey   = apiKey
    }

    /// The model id to send: the configured one, else the provider default.
    public var effectiveModel: String {
        let m = model.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? provider.defaultModel : m
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
            model:    d.string(forKey: "llm_model")    ?? "qwen3:4b",
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
    ///
    /// - jsonMode: ask the provider for guaranteed-JSON output (Ollama `format`,
    ///   OpenAI/Gemini `response_format`). Anthropic has no safe equivalent on
    ///   Claude 4.5+, so it relies on the prompt + the downstream regex extractor.
    /// - temperature: lower (~0.2) for faithful analysis/curation, higher (~0.8)
    ///   for creative titles. `nil` = provider default.
    /// - maxTokens: response cap; small for numbers-only curation, larger for prose.
    public func complete(
        system: String, user: String, config: LLMConfig,
        jsonMode: Bool = false, temperature: Double? = nil, maxTokens: Int = 1024
    ) async throws -> String {
        switch config.provider {
        case .ollama:
            return try await ollamaChat(system: system, user: user, config: config,
                                        jsonMode: jsonMode, temperature: temperature, maxTokens: maxTokens)
        case .anthropic:
            return try await anthropicMessages(system: system, user: user, config: config,
                                               temperature: temperature, maxTokens: maxTokens)
        case .openai, .custom, .gemini:
            return try await openAICompletions(system: system, user: user, config: config,
                                               jsonMode: jsonMode, temperature: temperature, maxTokens: maxTokens)
        }
    }

    /// Preload a local model so the first real `complete` doesn't pay the
    /// cold-start load cost. Only meaningful for Ollama; best-effort (errors
    /// swallowed — the real call surfaces any failure). `keep_alive` keeps the
    /// model resident for a burst of calls.
    public func warmUp(config: LLMConfig) async {
        guard config.provider == .ollama,
              let url = URL(string: "\(config.baseURL)/api/generate") else { return }
        let body: [String: Any] = ["model": config.effectiveModel, "keep_alive": "10m"]
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Lightweight connectivity/credential probe used by the Settings "Test
    /// verbinding" button. Returns nil on success, or a Dutch error sentence.
    public func test(config: LLMConfig) async -> String? {
        do {
            // 128 tokens so a reasoning model (e.g. Gemini 2.5, deepseek-r1) has
            // room to emit the reply after any hidden thinking — an 8-token cap
            // can be fully consumed by thinking and read as a false failure.
            _ = try await complete(system: "You are a connection test. Reply with the single word OK.",
                                   user: "OK", config: config, temperature: 0, maxTokens: 128)
            return nil
        } catch {
            return (error as? LLMError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Ollama

    private func ollamaChat(
        system: String, user: String, config: LLMConfig,
        jsonMode: Bool, temperature: Double?, maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "\(config.baseURL)/api/chat") else { throw LLMError.badURL }
        var options: [String: Any] = ["num_ctx": 8192]
        if maxTokens > 0 { options["num_predict"] = maxTokens }
        if let temperature { options["temperature"] = temperature }
        var body: [String: Any] = [
            "model": config.effectiveModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ],
            "stream": false,
            "think": false,          // disable chain-of-thought for Qwen3 / deepseek-r1
            "options": options
        ]
        if jsonMode { body["format"] = "json" }

        let data = try await send(jsonBody: body, to: url,
                                  headers: ["Content-Type": "application/json"], provider: .ollama)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg  = json["message"] as? [String: Any],
              let text = msg["content"] as? String
        else { throw LLMError.invalidResponse }
        return stripReasoning(text)
    }

    // MARK: Anthropic

    private func anthropicMessages(
        system: String, user: String, config: LLMConfig,
        temperature: Double?, maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw LLMError.badURL }
        var body: [String: Any] = [
            "model": config.effectiveModel,
            "max_tokens": max(maxTokens, 1),
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        if let temperature { body["temperature"] = temperature }

        let data = try await send(jsonBody: body, to: url, headers: [
            "Content-Type": "application/json",
            "x-api-key": config.apiKey,
            "anthropic-version": "2023-06-01"
        ], provider: .anthropic)
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { throw LLMError.invalidResponse }
        // Pick the first text block (a response may lead with a non-text block).
        let text = (content.first { ($0["type"] as? String) == "text" }?["text"] as? String)
            ?? (content.first?["text"] as? String)
        guard let text else { throw LLMError.invalidResponse }
        return stripReasoning(text)
    }

    // MARK: OpenAI-compatible (OpenAI · Gemini · custom)

    private func openAICompletions(
        system: String, user: String, config: LLMConfig,
        jsonMode: Bool, temperature: Double?, maxTokens: Int
    ) async throws -> String {
        let endpoint: String
        switch config.provider {
        case .openai: endpoint = "https://api.openai.com/v1/chat/completions"
        case .gemini: endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        default:      endpoint = "\(config.baseURL)/v1/chat/completions"
        }
        guard let url = URL(string: endpoint) else { throw LLMError.badURL }
        var body: [String: Any] = [
            "model": config.effectiveModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ]
        ]
        if let temperature { body["temperature"] = temperature }
        if maxTokens > 0 { body["max_tokens"] = maxTokens }
        if jsonMode { body["response_format"] = ["type": "json_object"] }

        let data = try await send(jsonBody: body, to: url, headers: [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(config.apiKey)"
        ], provider: config.provider)
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg     = choices.first?["message"] as? [String: Any],
              let text    = msg["content"] as? String
        else { throw LLMError.invalidResponse }
        return stripReasoning(text)
    }

    // MARK: Networking core (status-aware + bounded retry)

    /// Sends a JSON request and returns the raw body, translating HTTP status
    /// codes into typed `LLMError`s and retrying only *transient* failures
    /// (timeouts, dropped connections, 429, 5xx) with exponential backoff.
    /// 401/403/4xx fail fast — retrying a bad key just wastes the user's time.
    private func send(
        jsonBody: [String: Any], to url: URL, headers: [String: String], provider: LLMConfig.Provider
    ) async throws -> Data {
        let timeout: TimeInterval = provider == .ollama ? 180 : 60
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)

        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if (200...299).contains(code) { return data }

                let message = Self.extractAPIError(from: data)
                switch code {
                case 401, 403:
                    throw LLMError.unauthorized
                case 429:
                    guard attempt < maxAttempts else { throw LLMError.rateLimited }
                    let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    try await backoff(attempt: attempt, retryAfter: retryAfter)
                case 500...599:
                    guard attempt < maxAttempts else { throw LLMError.serverError(code: code, message: message) }
                    try await backoff(attempt: attempt, retryAfter: nil)
                default:
                    throw LLMError.providerError(message ?? "HTTP \(code)")
                }
            } catch let urlError as URLError {
                guard Self.isTransient(urlError), attempt < maxAttempts else { throw LLMError.network(urlError) }
                try await backoff(attempt: attempt, retryAfter: nil)
            }
        }
    }

    private func backoff(attempt: Int, retryAfter: Double?) async throws {
        let seconds = retryAfter.map { min(max($0, 0), 10) } ?? (0.5 * pow(2, Double(attempt - 1)))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Pull a human-readable error out of a provider body. OpenAI/Anthropic/Gemini
    /// nest it under `error.message`; Ollama uses a flat `{"error": "..."}`.
    static func extractAPIError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        }
        if let err = json["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = json["error"] as? String { return m }
        if let m = json["message"] as? String { return m }
        return nil
    }

    /// Only failures worth retrying — a missing host or refused connection is
    /// retried briefly in case Ollama is still warming up.
    static func isTransient(_ e: URLError) -> Bool {
        switch e.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost,
             .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // MARK: Helpers

    /// Strip leaked chain-of-thought from reasoning models: `<think>`,
    /// `<thinking>`, `<reasoning>` blocks (case-insensitive, multi-line),
    /// including an unterminated trailing tag that never closes.
    nonisolated static func stripReasoning(_ text: String) -> String {
        var s = text
        let patterns = [
            #"(?is)<think>.*?</think>\s*"#,
            #"(?is)<thinking>.*?</thinking>\s*"#,
            #"(?is)<reasoning>.*?</reasoning>\s*"#,
            #"(?is)<think>.*$"#,
            #"(?is)<thinking>.*$"#,
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripReasoning(_ text: String) -> String { Self.stripReasoning(text) }
}

// MARK: - Errors

public enum LLMError: LocalizedError {
    case badURL
    case invalidResponse
    case unauthorized
    case rateLimited
    case serverError(code: Int, message: String?)
    case providerError(String)
    case network(URLError)

    public var errorDescription: String? {
        switch self {
        case .badURL:
            "Ongeldige LLM-URL — controleer de Base URL bij Instellingen → LLM."
        case .invalidResponse:
            "Onverwacht antwoord van de AI — controleer het gekozen model en de provider."
        case .unauthorized:
            "Ongeldige of ontbrekende API-sleutel — controleer deze bij Instellingen → LLM."
        case .rateLimited:
            "Te veel verzoeken naar de AI — wacht even en probeer het opnieuw."
        case .serverError(let code, let message):
            if let message, !message.isEmpty { "De AI-server gaf een fout (\(code)): \(message)" }
            else { "De AI-server is tijdelijk niet beschikbaar (fout \(code))." }
        case .providerError(let message):
            "De AI gaf een fout: \(message)"
        case .network(let e):
            LLMError.describe(e)
        }
    }

    /// Map a low-level networking failure to a Dutch sentence the user can act on.
    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet:
            return "Geen internetverbinding."
        case .timedOut:
            return "De AI reageerde niet op tijd — is het model geladen en de server bereikbaar?"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Kan de AI-server niet bereiken — controleer de Base URL en of de server draait."
        default:
            return "Netwerkfout bij de AI: \(e.localizedDescription)"
        }
    }
}
