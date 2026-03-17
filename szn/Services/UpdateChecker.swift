import Foundation
import Cocoa

final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var availableVersion: String?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var dmgAssetURL: URL?

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

    /// Show the update prompt. If the user accepts, start the in-app update flow.
    func promptAndUpdate() {
        guard let version = availableVersion else { return }

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "szn v\(version) is available. You're currently on v\(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let dmgURL = dmgAssetURL {
            let updater = InAppUpdater(dmgURL: dmgURL)
            updater.start()
        } else if let url = downloadURL {
            NSWorkspace.shared.open(url)
        }
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

// MARK: - In-App Updater

/// Handles downloading the DMG, showing progress, installing, and relaunching.
private final class InAppUpdater: NSObject, URLSessionDownloadDelegate {
    private let dmgURL: URL
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var progressWindow: UpdateProgressWindow?

    init(dmgURL: URL) {
        self.dmgURL = dmgURL
    }

    func start() {
        let window = UpdateProgressWindow()
        window.onCancel = { [weak self] in self?.cancel() }
        window.show()
        self.progressWindow = window

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        downloadTask = session?.downloadTask(with: dmgURL)
        downloadTask?.resume()
    }

    private func cancel() {
        downloadTask?.cancel()
        session?.invalidateAndCancel()
        progressWindow?.close()
        progressWindow = nil
    }

    private func fail(_ message: String) {
        progressWindow?.close()
        progressWindow = nil

        let alert = NSAlert()
        alert.messageText = "Update Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Downloads Page")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = UpdateChecker.shared.downloadURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mbWritten = Double(totalBytesWritten) / 1_048_576
        let mbTotal = Double(totalBytesExpectedToWrite) / 1_048_576
        progressWindow?.update(
            progress: progress,
            status: String(format: "Downloading... %.1f / %.1f MB", mbWritten, mbTotal)
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        progressWindow?.update(progress: 1.0, status: "Installing...")
        progressWindow?.setIndeterminate(true)

        let dmgPath = NSTemporaryDirectory() + "szn-update.dmg"
        let dmgFileURL = URL(fileURLWithPath: dmgPath)
        try? FileManager.default.removeItem(at: dmgFileURL)

        do {
            try FileManager.default.moveItem(at: location, to: dmgFileURL)
        } catch {
            fail("Failed to save download: \(error.localizedDescription)")
            return
        }

        install(from: dmgPath)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail("Download failed: \(error.localizedDescription)")
    }

    // MARK: - Install

    private func install(from dmgPath: String) {
        let appBundlePath = Bundle.main.bundlePath
        let appName = (appBundlePath as NSString).lastPathComponent

        let mountPoint = NSTemporaryDirectory() + "szn-mount"
        try? FileManager.default.removeItem(atPath: mountPoint)

        // Mount DMG
        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mount.arguments = ["attach", dmgPath, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]

        do {
            try mount.run()
            mount.waitUntilExit()
        } catch {
            fail("Failed to mount update: \(error.localizedDescription)")
            return
        }

        guard mount.terminationStatus == 0 else {
            fail("Failed to mount the update DMG.")
            return
        }

        let newAppPath = (mountPoint as NSString).appendingPathComponent(appName)

        guard FileManager.default.fileExists(atPath: newAppPath) else {
            unmount(mountPoint)
            fail("Could not find \(appName) in the update.")
            return
        }

        // Replace current app
        let backupPath = appBundlePath + ".bak"
        try? FileManager.default.removeItem(atPath: backupPath)

        do {
            try FileManager.default.moveItem(atPath: appBundlePath, toPath: backupPath)
            try FileManager.default.copyItem(atPath: newAppPath, toPath: appBundlePath)

            // Strip quarantine
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", appBundlePath]
            try? xattr.run()
            xattr.waitUntilExit()

            try? FileManager.default.removeItem(atPath: backupPath)
        } catch {
            // Restore backup
            if FileManager.default.fileExists(atPath: backupPath),
               !FileManager.default.fileExists(atPath: appBundlePath) {
                try? FileManager.default.moveItem(atPath: backupPath, toPath: appBundlePath)
            }
            unmount(mountPoint)
            fail("Failed to install update: \(error.localizedDescription)")
            return
        }

        unmount(mountPoint)
        try? FileManager.default.removeItem(atPath: dmgPath)

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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(appPath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Progress Window

private final class UpdateProgressWindow {
    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var cancelButton: NSButton?
    var onCancel: (() -> Void)?

    func show() {
        let width: CGFloat = 380
        let height: CGFloat = 130

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // App icon + title
        let icon = NSImageView(frame: NSRect(x: 20, y: height - 44, width: 32, height: 32))
        icon.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "szn")
        icon.contentTintColor = .labelColor
        contentView.addSubview(icon)

        let title = NSTextField(labelWithString: "Updating szn")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 58, y: height - 40, width: 200, height: 22)
        contentView.addSubview(title)

        // Status label
        let status = NSTextField(labelWithString: "Preparing...")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 50, width: width - 40, height: 18)
        contentView.addSubview(status)
        self.statusLabel = status

        // Progress bar
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 30, width: width - 40, height: 12))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.isIndeterminate = false
        contentView.addSubview(bar)
        self.progressBar = bar

        // Cancel button
        let cancel = NSButton(title: "Cancel", target: nil, action: #selector(cancelClicked))
        cancel.frame = NSRect(x: width - 90, y: 0, width: 80, height: 28)
        cancel.bezelStyle = .rounded
        cancel.target = self
        contentView.addSubview(cancel)
        self.cancelButton = cancel

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "szn Update"
        win.contentView = contentView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func update(progress: Double, status: String) {
        progressBar?.doubleValue = progress
        statusLabel?.stringValue = status
    }

    func setIndeterminate(_ flag: Bool) {
        progressBar?.isIndeterminate = flag
        if flag { progressBar?.startAnimation(nil) }
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

// MARK: - Notification

extension Notification.Name {
    static let updateAvailable = Notification.Name("szn.updateAvailable")
}
