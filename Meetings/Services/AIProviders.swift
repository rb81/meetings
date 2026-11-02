import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIEndpoints {
    static let openRouter = URL(string: "https://openrouter.ai/api/v1")!
}

struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum AIError: LocalizedError {
    case invalidResponse
    case server(String)
    case offline(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The AI provider sent a reply the app couldn't read."
        case .server(let message): message
        case .offline(let message): message
        }
    }
}

/// A chat model that takes one system prompt and one user message and returns text.
protocol LanguageModel: Sendable {
    /// Characters of prompt that fit the context window with room left for the reply.
    var promptBudget: Int { get }
    /// Shown as "Written by" on generated notes.
    var label: String { get }

    /// `json` asks the provider to constrain the reply to JSON when it can.
    func complete(system: String, user: String, json: Bool) async throws -> String
}

enum HTTP {
    static func json(_ request: URLRequest, provider: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(http.statusCode) else {
            let nested = (json?["error"] as? [String: Any])?["message"] as? String
            let flat = json?["error"] as? String
            throw AIError.server(nested ?? flat ?? "\(provider) returned HTTP \(http.statusCode).")
        }
        guard let json else { throw AIError.invalidResponse }
        return json
    }

    static func get(_ url: URL, headers: [String: String] = [:], provider: String) async throws -> [String: Any] {
        guard NetworkPolicy.allows(url) else { throw AIError.offline(offlineMessage) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await json(request, provider: provider)
    }

    static func post(_ url: URL, body: [String: Any], headers: [String: String], provider: String) async throws -> [String: Any] {
        guard NetworkPolicy.allows(url) else { throw AIError.offline(offlineMessage) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await json(request, provider: provider)
    }

    static let offlineMessage = "Offline mode only allows AI on this Mac. Turn offline mode off to use this provider."
}

/// Any server that speaks the OpenAI chat API: OpenRouter, OpenAI, LM Studio, llama.cpp, vLLM, and similar.
struct OpenAICompatibleModel: LanguageModel {
    let baseURL: URL
    let apiKey: String?
    let model: String
    let promptBudget: Int
    let provider: String
    var extraHeaders: [String: String] = [:]

    var label: String { model }

    func complete(system: String, user: String, json: Bool) async throws -> String {
        var headers = extraHeaders
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let reply = try await HTTP.post(
            baseURL.appendingPathComponent("chat/completions"),
            body: body,
            headers: headers,
            provider: provider
        )
        let choices = reply["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let content = message?["content"] as? String else { throw AIError.invalidResponse }
        return content
    }

    static func listModels(baseURL: URL, apiKey: String?, provider: String) async throws -> [ModelOption] {
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        let json = try await HTTP.get(baseURL.appendingPathComponent("models"), headers: headers, provider: provider)
        let items = json["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ModelOption(id: id, name: item["name"] as? String ?? id)
        }
        .sorted { $0.id < $1.id }
    }
}

/// Ollama's native API. Used instead of its OpenAI-compatible route because that route can't set the
/// context window. Ollama's default window is small, and a longer transcript would be cut off without any error.
struct OllamaModel: LanguageModel {
    let baseURL: URL
    let model: String
    let contextTokens: Int

    var promptBudget: Int { max(2_000, (contextTokens - 1_500) * 3) }
    var label: String { "Ollama · \(model)" }

    func complete(system: String, user: String, json: Bool) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "options": ["num_ctx": contextTokens, "temperature": 0.2],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if json {
            body["format"] = "json"
        }
        let reply = try await HTTP.post(
            baseURL.appendingPathComponent("api/chat"),
            body: body,
            headers: [:],
            provider: "Ollama"
        )
        let message = reply["message"] as? [String: Any]
        guard let content = message?["content"] as? String else { throw AIError.invalidResponse }
        return content
    }

    static func listModels(baseURL: URL) async throws -> [ModelOption] {
        let json = try await HTTP.get(baseURL.appendingPathComponent("api/tags"), provider: "Ollama")
        let items = json["models"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return ModelOption(id: name, name: name)
        }
        .sorted { $0.id < $1.id }
    }
}

/// Apple's on-device model. Nothing leaves the Mac. Its context window is small, so the notes pipeline
/// splits transcripts into parts for it.
@available(macOS 26.0, *)
struct AppleIntelligenceModel: LanguageModel {
    let promptBudget = 6_000
    let label = "Apple Intelligence"

    /// Nil when the on-device model can be used.
    static var problem: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings."
            case .modelNotReady: return "Apple Intelligence is still getting its model ready."
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        @unknown default:
            return "Apple Intelligence isn't available right now."
        }
        #else
        return "This build of Meetings doesn't include Apple Intelligence."
        #endif
    }

    func complete(system: String, user: String, json: Bool) async throws -> String {
        #if canImport(FoundationModels)
        // A new session per request. A reused session keeps every earlier exchange in its context window.
        let session = LanguageModelSession(instructions: system)
        let response = try await session.respond(to: user)
        return response.content
        #else
        throw AIError.server("This build of Meetings doesn't include Apple Intelligence.")
        #endif
    }
}

enum AppleIntelligence {
    static var problem: String? {
        guard #available(macOS 26.0, *) else { return "Needs macOS 26 or later." }
        return AppleIntelligenceModel.problem
    }
}
