import Foundation
import Supabase

/// Manages Supabase authentication state.
@Observable
final class AuthManager {
    enum AuthState {
        case unknown
        case signedOut
        case signedIn
    }

    private(set) var state: AuthState = .unknown
    private(set) var userId: String?
    private(set) var userEmail: String?
    var errorMessage: String?

    let client: SupabaseClient

    var accessToken: String? {
        guard case .signedIn = state else { return nil }
        return _cachedAccessToken
    }

    private var _cachedAccessToken: String?
    private var authListenerTask: Task<Void, Never>?

    init() {
        client = SupabaseClient(
            supabaseURL: URL(string: "https://shsqgiwneybuogyowopy.supabase.co")!,
            supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNoc3FnaXduZXlidW9neW93b3B5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU4MDU3MTMsImV4cCI6MjA4MTM4MTcxM30.6GqX5LgjUPSj8PTpz-Q2LKV2N4yH_-F0Z33kOAHT5h8"
        )
    }

    /// Restore session on app launch and listen for auth changes.
    func restoreSession() {
        authListenerTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in self.client.auth.authStateChanges {
                await MainActor.run {
                    switch event {
                    case .initialSession, .signedIn, .tokenRefreshed:
                        if let session {
                            self._cachedAccessToken = session.accessToken
                            self.userId = session.user.id.uuidString
                            self.userEmail = session.user.email
                            self.state = .signedIn
                            Task { await self.ensureProfile() }
                        } else {
                            self._cachedAccessToken = nil
                            self.userId = nil
                            self.userEmail = nil
                            self.state = .signedOut
                        }
                    case .signedOut:
                        self._cachedAccessToken = nil
                        self.userId = nil
                        self.userEmail = nil
                        self.state = .signedOut
                    default:
                        break
                    }
                }
            }
        }
    }

    func signIn(email: String, password: String) async {
        errorMessage = nil
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            _cachedAccessToken = session.accessToken
            userId = session.user.id.uuidString
            userEmail = session.user.email
            state = .signedIn
            await ensureProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async {
        errorMessage = nil
        do {
            let response = try await client.auth.signUp(email: email, password: password)
            if let session = response.session {
                _cachedAccessToken = session.accessToken
                userId = session.user.id.uuidString
                userEmail = session.user.email
                state = .signedIn
                await ensureProfile()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Get-or-create user profile in user_profiles table (required before fork_graph RPC).
    private func ensureProfile() async {
        guard let userId else { return }
        let displayName = userEmail?.components(separatedBy: "@").first

        // Check if profile exists
        let existing = try? await client
            .from("user_profiles")
            .select("user_id")
            .eq("user_id", value: userId)
            .single()
            .execute()

        if existing?.data != nil,
           let json = try? JSONSerialization.jsonObject(with: existing!.data) as? [String: Any],
           json["user_id"] != nil {
            return  // Profile already exists
        }

        // Create profile
        do {
            try await client
                .from("user_profiles")
                .insert(["user_id": userId, "display_name": displayName ?? "Player"])
                .execute()
            print("[Auth] Profile created for \(userId)")
        } catch {
            print("[Auth] Profile creation failed (may already exist): \(error.localizedDescription)")
        }
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
        _cachedAccessToken = nil
        userId = nil
        userEmail = nil
        state = .signedOut
    }
}
