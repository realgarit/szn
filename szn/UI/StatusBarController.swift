import Cocoa
import SwiftUI

final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem

    private var settingsWindow: NSWindow?

    /// Tracks the app that was active *before* the user clicked the szn menu.
    private var previousApp: NSRunningApplication?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = Self.createMenuBarIcon()
        }

        rebuildMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(onProfilesChanged),
            name: .profilesDidChange, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(onProfilesChanged),
            name: .updateAvailable, object: nil)

        // Track active app changes so we know which app was in focus before clicking szn
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func onAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousApp = app
    }

    // MARK: - Menu

    @objc private func onProfilesChanged() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Global toggle
        let globalTitle = ProfileStore.shared.isGloballyEnabled ? "Enabled" : "Disabled"
        let globalItem = NSMenuItem(title: globalTitle, action: #selector(toggleGlobal), keyEquivalent: "")
        globalItem.target = self
        if ProfileStore.shared.isGloballyEnabled {
            globalItem.state = .on
        }
        menu.addItem(globalItem)

        menu.addItem(.separator())

        // Save actions
        let saveSize = NSMenuItem(title: "Save Size for Current App", action: #selector(saveSizeOnly), keyEquivalent: "s")
        saveSize.keyEquivalentModifierMask = [.command, .shift]
        saveSize.target = self
        menu.addItem(saveSize)

        let saveBoth = NSMenuItem(title: "Save Size & Position for Current App", action: #selector(saveSizeAndPosition), keyEquivalent: "s")
        saveBoth.keyEquivalentModifierMask = [.command, .shift, .option]
        saveBoth.target = self
        menu.addItem(saveBoth)

        menu.addItem(.separator())

        // Profiles list
        let sorted = ProfileStore.shared.profiles.values.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }

        if sorted.isEmpty {
            let empty = NSMenuItem(title: "No saved profiles", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Saved Profiles", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for profile in sorted {
                let sub = NSMenu()

                let dims = "\(Int(profile.size.width)) × \(Int(profile.size.height))"
                let detail = profile.savePosition ? "\(dims) + position" : dims
                let info = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
                info.isEnabled = false
                sub.addItem(info)
                sub.addItem(.separator())

                let toggle = NSMenuItem(title: profile.isEnabled ? "Disable" : "Enable",
                                        action: #selector(toggleProfile(_:)), keyEquivalent: "")
                toggle.target = self
                toggle.representedObject = profile.bundleIdentifier
                sub.addItem(toggle)

                let apply = NSMenuItem(title: "Apply Now",
                                       action: #selector(applyNow(_:)), keyEquivalent: "")
                apply.target = self
                apply.representedObject = profile.bundleIdentifier
                sub.addItem(apply)

                let remove = NSMenuItem(title: "Remove",
                                        action: #selector(removeProfile(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = profile.bundleIdentifier
                sub.addItem(remove)

                let prefix = profile.isEnabled ? "✓ " : "   "
                let item = NSMenuItem(title: "\(prefix)\(profile.displayName)", action: nil, keyEquivalent: "")
                item.submenu = sub

                // Show the app's icon in the menu
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier) {
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }

                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Update available
        if let version = UpdateChecker.shared.availableVersion {
            let update = NSMenuItem(title: "Update Available: v\(version)", action: #selector(openUpdate), keyEquivalent: "")
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "update")
            update.image?.isTemplate = true
            menu.addItem(update)
            menu.addItem(.separator())
        }

        let checkUpdate = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdate.target = self
        menu.addItem(checkUpdate)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit szn", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleGlobal() {
        ProfileStore.shared.isGloballyEnabled.toggle()
    }

    @objc private func saveSizeOnly() { saveCurrentWindow(withPosition: false) }
    @objc private func saveSizeAndPosition() { saveCurrentWindow(withPosition: true) }

    private func saveCurrentWindow(withPosition: Bool) {
        guard AccessibilityService.shared.isPermissionGranted() else {
            AccessibilityService.shared.requestPermissionIfNeeded { }
            return
        }

        guard let targetApp = previousApp,
              let bundleID = targetApp.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let frame = AccessibilityService.shared.getFocusedWindowFrame(for: targetApp) else {
            showAlert("Could not read window size. Make sure another app's window was in focus before clicking szn.")
            return
        }

        let appName = targetApp.localizedName ?? bundleID

        let profile = WindowProfile(
            bundleIdentifier: bundleID,
            appName: appName,
            size: frame.size,
            position: withPosition ? frame.origin : nil,
            isEnabled: true,
            savePosition: withPosition
        )

        ProfileStore.shared.save(profile)
        showFeedback(for: appName)
    }

    @objc private func toggleProfile(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        ProfileStore.shared.toggleProfile(for: bundleID)
    }

    @objc private func applyNow(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              let profile = ProfileStore.shared.profile(for: bundleID) else { return }

        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
            AccessibilityService.shared.applyProfile(profile, to: app)
        }
    }

    @objc private func removeProfile(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              let profile = ProfileStore.shared.profile(for: bundleID) else { return }

        let alert = NSAlert()
        alert.messageText = "Remove Profile"
        alert.informativeText = "Remove the saved window profile for \(profile.displayName)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ProfileStore.shared.remove(for: bundleID)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "szn - Window Resizer"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 480, height: 420))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openUpdate() {
        UpdateChecker.shared.promptAndUpdate()
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates { updateFound in
            if updateFound {
                UpdateChecker.shared.promptAndUpdate()
            } else {
                let alert = NSAlert()
                alert.messageText = "szn"
                alert.informativeText = "You're on the latest version (v\(UpdateChecker.shared.currentVersion))."
                alert.alertStyle = .informational
                alert.runModal()
            }
        }
    }

    @objc private func doQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Feedback

    private func showFeedback(for appName: String) {
        guard let button = statusItem.button else { return }
        let original = button.image
        let check = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "saved")
        check?.isTemplate = true
        button.image = check
        button.toolTip = "Saved profile for \(appName)"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            button.image = original
            button.toolTip = nil
        }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "szn"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Draw the menu bar icon programmatically — guarantees transparent background.
    private static func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            let inset: CGFloat = 3
            let minX = inset
            let maxX = rect.width - inset
            let minY = inset
            let maxY = rect.height - inset
            let midX = rect.midX
            let midY = rect.midY

            // Expand arrow: bottom-left to top-right
            path.move(to: NSPoint(x: minX, y: minY))
            path.line(to: NSPoint(x: maxX, y: maxY))
            // Arrowhead
            path.move(to: NSPoint(x: midX, y: maxY))
            path.line(to: NSPoint(x: maxX, y: maxY))
            path.line(to: NSPoint(x: maxX, y: midY))

            // Shrink arrow: top-right to bottom-left
            path.move(to: NSPoint(x: maxX, y: minY))
            path.line(to: NSPoint(x: minX, y: maxY))
            // Arrowhead
            path.move(to: NSPoint(x: midX, y: minY))
            path.line(to: NSPoint(x: minX, y: minY))
            path.line(to: NSPoint(x: minX, y: midY))

            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
