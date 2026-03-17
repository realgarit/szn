import Cocoa
import ApplicationServices

final class AccessibilityService {
    static let shared = AccessibilityService()

    private var permissionTimer: Timer?
    private var pollAttempts = 0

    func isPermissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system accessibility prompt and polls until permission is granted.
    func requestPermissionIfNeeded(onGranted: @escaping () -> Void) {
        guard !isPermissionGranted() else {
            onGranted()
            return
        }

        // Try stripping quarantine from ourselves first — this is the #1 cause
        // of permission not sticking on macOS Sequoia for unsigned apps
        stripQuarantine()

        // Show the system prompt
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Poll until the user grants permission
        pollAttempts = 0
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.pollAttempts += 1

            if AXIsProcessTrusted() {
                timer.invalidate()
                self.permissionTimer = nil
                DispatchQueue.main.async { onGranted() }
            } else if self.pollAttempts == 15 {
                // After 15s of waiting, show troubleshooting help
                DispatchQueue.main.async { self.showTroubleshootingAlert() }
            }
        }
    }

    /// Read the focused window's frame for a given app.
    func getFocusedWindowFrame(for app: NSRunningApplication) -> CGRect? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else {
            return nil
        }

        return frameOf(windowRef as! AXUIElement)
    }

    /// Apply a profile to all current windows of an app.
    func applyProfile(_ profile: WindowProfile, to app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let windows = windowList as? [AXUIElement] else { return }

        for window in windows {
            applyFrame(to: window, profile: profile)
        }
    }

    /// Apply a profile to a single AXUIElement window.
    func applyFrame(to window: AXUIElement, profile: WindowProfile) {
        var size = profile.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }

        if profile.savePosition, let pos = profile.position {
            var origin = pos
            if let posValue = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            }
        }
    }

    // MARK: - Private

    private func frameOf(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    /// Attempt to remove quarantine attribute from the running app bundle.
    /// Quarantined unsigned apps can't reliably hold accessibility permissions on Sequoia.
    private func stripQuarantine() {
        guard let bundlePath = Bundle.main.bundlePath as String? else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", bundlePath]
        try? process.run()
        process.waitUntilExit()
    }

    private func showTroubleshootingAlert() {
        // Try resetting the TCC entry automatically — a stale entry from a
        // previous build (different ad-hoc signature) is the most common cause
        resetTCCEntry()

        let bundleID = Bundle.main.bundleIdentifier ?? "com.szn.app"
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission"
        alert.informativeText = """
            szn still can't detect accessibility permission.

            This can happen after an update or fresh install. To fix:

            1. Quit szn
            2. Open Terminal and run:
               tccutil reset Accessibility \(bundleID) && xattr -cr \(Bundle.main.bundlePath)
            3. Reopen szn and grant permission again

            We've already tried resetting the permission automatically.
            If it still doesn't work, try the terminal command above.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Fix Command")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let command = "tccutil reset Accessibility \(bundleID) && xattr -cr \"\(Bundle.main.bundlePath)\""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// Reset the TCC accessibility entry so macOS re-evaluates the current code signature.
    private func resetTCCEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        try? process.run()
        process.waitUntilExit()
    }
}
