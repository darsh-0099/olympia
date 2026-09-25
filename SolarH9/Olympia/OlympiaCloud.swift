import Combine
import Foundation
import Security

/// Supabase REST client. Only the publishable/anon key belongs on device.
/// The user owns a single versioned JSON training snapshot behind RLS.
@MainActor final class OlympiaCloud: ObservableObject {
    static let shared = OlympiaCloud()
    @Published private(set) var signedInEmail: String?
    @Published private(set) var isBusy = false
    @Published var message: String?
    @Published var projectURL: String { didSet { UserDefaults.standard.set(projectURL, forKey: "olympia.supabase.url") } }
    @Published var publishableKey: String { didSet { UserDefaults.standard.set(publishableKey, forKey: "olympia.supabase.key") } }

    private var accessToken: String? { get { keychain("access") } set { setKeychain("access", newValue) } }
    private var refreshToken: String? { get { keychain("refresh") } set { setKeychain("refresh", newValue) } }
    private var userID: String? { get { keychain("user-id") } set { setKeychain("user-id", newValue) } }
    private var rootURL: URL? {
        guard let url = URL(string: projectURL), url.scheme == "https", url.host?.hasSuffix(".supabase.co") == true else { return nil }
        return url
    }

    private init() {
        projectURL = UserDefaults.standard.string(forKey: "olympia.supabase.url") ?? ""
        publishableKey = UserDefaults.standard.string(forKey: "olympia.supabase.key") ?? ""
        signedInEmail = UserDefaults.standard.string(forKey: "olympia.supabase.email")
    }

    var configured: Bool { rootURL != nil && !publishableKey.isEmpty }
    var signedIn: Bool { userID != nil && refreshToken != nil }

    func signUp(email: String, password: String) async {
        await authenticate(path: "auth/v1/signup", email: email, password: password)
    }

    func signIn(email: String, password: String) async {
        await authenticate(path: "auth/v1/token?grant_type=password", email: email, password: password)
    }

    private func authenticate(path: String, email: String, password: String) async {
        isBusy = true; defer { isBusy = false }
        do {
            let response = try await request(path: path, method: "POST",
                                             body: ["email": email, "password": password], authenticated: false)
            saveSession(response, email: email)
            message = signedIn ? "Signed in. Use Sync now to upload your training data." : "Check your email to confirm your account, then sign in."
        } catch { message = error.localizedDescription }
    }

    func signOut() {
        accessToken = nil; refreshToken = nil; userID = nil; signedInEmail = nil
        UserDefaults.standard.removeObject(forKey: "olympia.supabase.email")
        message = "Signed out. Your local training data remains on this iPhone."
    }

    func sync(store: OlympiaTrainingStore) async {
        isBusy = true; defer { isBusy = false }
        do {
            try await renewSession()
            guard let userID else { throw CloudError("Sign in first.") }
            let query = "rest/v1/training_data?select=payload,revision&user_id=eq.\(userID)"
            let response = try await request(path: query, method: "GET", authenticated: true)
            let rows = response as? [[String: Any]] ?? []
            if let row = rows.first, let payload = row["payload"] {
                let data = try JSONSerialization.data(withJSONObject: payload)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let backup = try decoder.decode(OlympiaBackup.self, from: data)
                store.mergeBackup(backup)
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let object = try JSONSerialization.jsonObject(with: encoder.encode(OlympiaBackup(store: store)))
            let revision = ((rows.first?["revision"] as? Int) ?? 0) + 1
            _ = try await request(path: "rest/v1/training_data?on_conflict=user_id", method: "POST",
                                  body: ["user_id": userID, "payload": object, "revision": revision],
                                  authenticated: true, extraHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"])
            message = "Cloud sync complete. Your workouts and body weight are backed up."
        } catch { message = "Sync failed: \(error.localizedDescription)" }
    }

    private func renewSession() async throws {
        guard let refreshToken else { throw CloudError("Sign in first.") }
        let response = try await request(path: "auth/v1/token?grant_type=refresh_token", method: "POST",
                                         body: ["refresh_token": refreshToken], authenticated: false)
        saveSession(response, email: signedInEmail)
    }

    private func saveSession(_ response: Any, email: String?) {
        guard let value = response as? [String: Any],
              let token = value["access_token"] as? String,
              let refresh = value["refresh_token"] as? String,
              let user = value["user"] as? [String: Any],
              let id = user["id"] as? String else { return }
        accessToken = token; refreshToken = refresh; userID = id
        signedInEmail = email ?? user["email"] as? String
        UserDefaults.standard.set(signedInEmail, forKey: "olympia.supabase.email")
    }

    private func request(path: String, method: String, body: [String: Any]? = nil,
                         authenticated: Bool, extraHeaders: [String: String] = [:]) async throws -> Any {
        guard let rootURL, !publishableKey.isEmpty else { throw CloudError("Enter your Supabase project URL and publishable key.") }
        guard let url = URL(string: path, relativeTo: rootURL) else { throw CloudError("Invalid request URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError("No server response.") }
        guard (200..<300).contains(http.statusCode) else {
            let server = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CloudError((server?["msg"] ?? server?["message"] ?? server?["error_description"] ?? "HTTP \(http.statusCode)") as? String ?? "HTTP \(http.statusCode)")
        }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    private func keychain(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "OlympiaSupabase",
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func setKeychain(_ key: String, _ value: String?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "OlympiaSupabase", kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var insert = query; insert[kSecValueData as String] = data
        SecItemAdd(insert as CFDictionary, nil)
    }

    private struct CloudError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
