import Foundation
import Security

/// Where the app sends things: the Supabase project URL, its publishable key and the ingest token (the same three a
/// Shortcut uses). Kept in the Keychain, typed in once in Settings; never in the code.
struct Credentials: Equatable {
    var url = ""
    var key = ""
    var token = ""

    var isComplete: Bool { !url.isEmpty && !key.isEmpty && !token.isEmpty }

    static func load() -> Credentials {
        Credentials(url: Keychain.get("url") ?? "", key: Keychain.get("key") ?? "", token: Keychain.get("token") ?? "")
    }

    func save() {
        Keychain.set("url", url.trimmingCharacters(in: .whitespacesAndNewlines))
        Keychain.set("key", key.trimmingCharacters(in: .whitespacesAndNewlines))
        Keychain.set("token", token.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum Keychain {
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Not set up: add the URL, key and token in Settings."
        case let .http(code, body): return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

/// The database's RPC endpoints (PostgREST): POST /rest/v1/rpc/<name> with the apikey and x-ingest-token headers.
struct API {
    let creds: Credentials

    func rpc(_ name: String, json: Any = [String: Any]()) async throws -> Data {
        try await post("/rest/v1/rpc/" + name, json: json, timeout: 20)
    }

    /// An Edge Function (/functions/v1/<name>) with the same headers; the AI one can take a minute.
    func function(_ name: String, json: Any, timeout: TimeInterval = 120) async throws -> Data {
        try await post("/functions/v1/" + name, json: json, timeout: timeout)
    }

    private func post(_ path: String, json: Any, timeout: TimeInterval) async throws -> Data {
        var base = creds.url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard creds.isComplete, let url = URL(string: base + path) else { throw APIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(creds.key, forHTTPHeaderField: "apikey")
        req.setValue(creds.token, forHTTPHeaderField: "x-ingest-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }
}
