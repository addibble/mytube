import Foundation
import Observation
import Security

/// Models offered up front; any other OpenRouter model can be picked from the catalog.
enum PresetModel: CaseIterable, Identifiable {
    case claude, openAI, gemini, deepSeek, grok

    var id: String { slug }

    var displayName: String {
        switch self {
        case .claude: "Claude Sonnet 5.5"
        case .openAI: "ChatGPT Sol 6.1"
        case .gemini: "Gemini Argon 4"
        case .deepSeek: "DeepSeek Flash 4.1"
        case .grok: "SpaceX Grok 4.7"
        }
    }

    /// OpenRouter model slug.
    var slug: String {
        switch self {
        case .claude: "anthropic/claude-sonnet-5.5"
        case .openAI: "openai/gpt-6.1-sol"
        case .gemini: "google/gemini-4-argon"
        case .deepSeek: "deepseek/deepseek-v4.1-flash"
        case .grok: "x-ai/grok-4.7"
        }
    }
}

/// One entry from OpenRouter's public model catalog.
struct CatalogModel: Identifiable, Decodable {
    let id: String
    let name: String
}

/// The chosen model lives in UserDefaults; the OpenRouter API key lives in the Keychain.
@MainActor @Observable
final class LLMSettings {
    static let shared = LLMSettings()

    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "openRouterModel") }
    }

    private init() {
        model = UserDefaults.standard.string(forKey: "openRouterModel") ?? PresetModel.claude.slug
    }

    var modelName: String {
        PresetModel.allCases.first { $0.slug == model }?.displayName ?? model
    }

    var apiKey: String {
        get { Keychain.read() ?? "" }
        set { Keychain.write(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.drewdibble.mytube.apikey",
        kSecAttrAccount as String: "openrouter",
    ]

    static func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

enum LLMError: LocalizedError {
    case missingKey
    case api(String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your OpenRouter API key in Settings first."
        case .api(let message): message
        case .emptyReply: "The model sent back an empty answer."
        }
    }
}

/// Talks to every model through OpenRouter's OpenAI-style API.
enum OpenRouter {
    private static let base = URL(string: "https://openrouter.ai/api/v1")!

    static func complete(system: String, messages: [(role: String, content: String)], model: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingKey }

        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MyTube", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "system", "content": system]] + messages.map { ["role": $0.role, "content": $0.content] },
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw LLMError.api(message ?? "OpenRouter returned an error.")
        }
        let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        guard let text = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw LLMError.emptyReply }
        return text
    }

    /// Every model OpenRouter offers, for the picker. Needs no key.
    static func catalog() async throws -> [CatalogModel] {
        struct Response: Decodable { let data: [CatalogModel] }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("models"))
        return try JSONDecoder().decode(Response.self, from: data).data.sorted { $0.name < $1.name }
    }
}
