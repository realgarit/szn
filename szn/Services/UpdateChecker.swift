import Foundation
import Cocoa

final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var availableVersion: String?
    @Published private(set) var downloadURL: URL?
    /// Direct URL to the .dmg asset for in-app updates.
    @Published private(set) var dmgAssetURL: URL?
    @Published private(set) var isUpdating = false

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

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard self.isNewer(remoteVersion, than: self.currentVersion) else { return }

            let releaseURL = (json["html_url"] as? String).flatMap { URL(string: $0) }

            // Find the .dmg asset URL from the release assets
            var dmgURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let urlString = asset["browser_download_url"] as? String {
                        dmgURL = URL(string: urlString)
                        break
                    }
                }
            }

            DispatchQueue.main.async {
                self.availableVersion = remoteVersion
                self.downloadURL = releaseURL
                self.dmgAssetURL = dmgURL
                NotificationCenter.default.post(name: .updateAvailable, object: nil)
            }
        }.resume()
    }

    /// Download the DMG, mount it, replace the current app, and relaunch.
    func performUpdate(onProgress: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard let dmgURL = dmgAssetURL else {
            // Fallback to opening the release page
            if let url = downloadURL {
                NSWorkspace.shared.open(url)
            }
            return
        }

        isUpdating = true
        onProgress("Downloading update...")

        let task = URLSession.shared.downloadTask(with: dmgURL) { [weak self] tempURL, _, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    onError("Download failed: \(error.localizedDescription)")
                }
                return
            }

            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    onError("Download failed: no file received.")
                }
                return
            }

            // Move to a stable temp location (download task file is ephemeral)
            let dmgPath = NSTemporaryDirectory() + "szn-update.dmg"
            let dmgFileURL = URL(fileURLWithPath: dmgPath)
            try? FileManager.default.removeItem(at: dmgFileURL)

            do {
                try FileManager.default.moveItem(at: tempURL, to: dmgFileURL)
            } catch {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    onError("Failed to save download: \(error.localizedDescription)")
                }
                return
            }

            DispatchQueue.main.async {
                onProgress("Installing update...")
                self.installFromDMG(at: dmgPath, onError: onError)
            }
        }
        task.resume()
    }

    // MARK: - Private

    private func installFromDMG(at dmgPath: String, onError: @escaping (String) -> Void) {
        let appBundlePath = Bundle.main.bundlePath
        let appName = (appBundlePath as NSString).lastPathComponent // "szn.app"

        // Mount the DMG
        let mountPoint = NSTemporaryDirectory() + "szn-mount"
        try? FileManager.default.removeItem(atPath: mountPoint)

        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mount.arguments = ["attach", dmgPath, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]

        do {
            try mount.run()
            mount.waitUntilExit()
        } catch {
            isUpdating = false
            onError("Failed to mount update: \(error.localizedDescription)")
            return
        }

        guard mount.terminationStatus == 0 else {
            isUpdating = false
            onError("Failed to mount the DMG.")
            return
        }

        let newAppPath = (mountPoint as NSString).appendingPathComponent(appName)

        guard FileManager.default.fileExists(atPath: newAppPath) else {
            unmount(mountPoint)
            isUpdating = false
            onError("Could not find \(appName) in the update.")
            return
        }

        // Replace the current app bundle
        let backupPath = appBundlePath + ".bak"
        try? FileManager.default.removeItem(atPath: backupPath)

        do {
            // Move current app to backup
            try FileManager.default.moveItem(atPath: appBundlePath, toPath: backupPath)
            // Copy new app into place
            try FileManager.default.copyItem(atPath: newAppPath, toPath: appBundlePath)
            // Strip quarantine from the new app
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", appBundlePath]
            try? xattr.run()
            xattr.waitUntilExit()
            // Remove backup
            try? FileManager.default.removeItem(atPath: backupPath)
        } catch {
            // Restore from backup if possible
            if FileManager.default.fileExists(atPath: backupPath),
               !FileManager.default.fileExists(atPath: appBundlePath) {
                try? FileManager.default.moveItem(atPath: backupPath, toPath: appBundlePath)
            }
            unmount(mountPoint)
            isUpdating = false
            onError("Failed to install update: \(error.localizedDescription)")
            return
        }

        unmount(mountPoint)
        try? FileManager.default.removeItem(atPath: dmgPath)

        // Relaunch
        relaunch()
    }

    private func unmount(_ mountPoint: String) {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountPoint, "-quiet"]
        try? detach.run()
        detach.waitUntilExit()
    }

    private func relaunch() {
        let appPath = Bundle.main.bundlePath
        // Use a small shell script to wait for this process to exit, then reopen
        let script = """
        sleep 1
        open "\(appPath)"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()

        NSApp.terminate(nil)
    }

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
