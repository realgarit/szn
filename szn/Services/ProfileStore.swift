import Foundation

extension Notification.Name {
    static let profilesDidChange = Notification.Name("szn.profilesDidChange")
}

final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [String: WindowProfile] = [:]

    @Published var isGloballyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isGloballyEnabled, forKey: Keys.globalEnabled)
            NotificationCenter.default.post(name: .profilesDidChange, object: nil)
        }
    }

    private enum Keys {
        static let profiles = "szn_profiles"
        static let globalEnabled = "szn_global_enabled"
        static let profilesBackup = "szn_profiles_backup"
    }

    private init() {
        let stored = UserDefaults.standard.object(forKey: Keys.globalEnabled) as? Bool
        self.isGloballyEnabled = stored ?? true
        loadProfiles()
    }

    func save(_ profile: WindowProfile) {
        // Reject nonsensical window sizes
        guard profile.size.width >= 50, profile.size.height >= 50 else { return }

        profiles[profile.bundleIdentifier] = profile
        persist()
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    func remove(for bundleID: String) {
        profiles.removeValue(forKey: bundleID)
        persist()
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    func profile(for bundleID: String) -> WindowProfile? {
        profiles[bundleID]
    }

    func toggleProfile(for bundleID: String) {
        guard var profile = profiles[bundleID] else { return }
        profile.isEnabled.toggle()
        profiles[bundleID] = profile
        persist()
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    // MARK: - Private

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: Keys.profiles) else { return }

        do {
            profiles = try JSONDecoder().decode([String: WindowProfile].self, from: data)
        } catch {
            // If decoding fails (e.g. model changed), keep a backup and start fresh
            UserDefaults.standard.set(data, forKey: Keys.profilesBackup)
            profiles = [:]
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Keys.profiles)
    }
}
