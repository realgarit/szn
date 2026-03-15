import Foundation

final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var availableVersion: String?
    @Published private(set) var downloadURL: URL?

    private let repo = "realgarit/szn"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var isUpdateAvailable: Bool {
        availableVersion != nil
    }

    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self,
                  error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }

            // tag is like "v1.2.0", strip the "v"
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard self.isNewer(remoteVersion, than: self.currentVersion) else { return }

            // Find the .dmg asset URL
            let releaseURL = (json["html_url"] as? String).flatMap { URL(string: $0) }

            DispatchQueue.main.async {
                self.availableVersion = remoteVersion
                self.downloadURL = releaseURL
                NotificationCenter.default.post(name: .updateAvailable, object: nil)
            }
        }.resume()
    }

    /// Simple semver comparison: returns true if `a` is newer than `b`.
    private func isNewer(_ a: String, than b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(partsA.count, partsB.count) {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va > vb { return true }
            if va < vb { return false }
        }
        return false
    }
}

extension Notification.Name {
    static let updateAvailable = Notification.Name("szn.updateAvailable")
}
