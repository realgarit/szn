import Cocoa
import ApplicationServices

final class AccessibilityService {
    static let shared = AccessibilityService()

    private var permissionTimer: Timer?
    private var pollAttempts = 0
    private static let maxPollAttempts = 120 // 2 minutes, then stop wasting cycles

    func isPermissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system accessibility prompt and polls until permission is granted.
    func requestPermissionIfNeeded(onGranted: @escaping () -> Void) {
        // Always strip quarantine first — safe and idempotent
        stripQuarantine()

        guard !isPermissionGranted() else {
            onGranted()
            return
        }

        // Clear any stale TCC entry from a previous build whose ad-hoc
        // signature no longer matches. This lets macOS re-evaluate cleanly.
        resetTCCEntry()

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
                DispatchQueue.main.async { self.showTroubleshootingAlert() }
            } else if self.pollAttempts >= Self.maxPollAttempts {
                timer.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    /// Read the focused window's frame for a given app.
    func getFocusedWindowFrame(for app: NSRunningApplication) -> CGRect? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              CFGetTypeID(windowRef!) == AXUIElementGetTypeID() else {
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
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              posRef != nil, sizeRef != nil,
              CFGetTypeID(posRef!) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef!) == AXValueGetTypeID() else {
            return nil
        }

        let posValue = posRef as! AXValue
        let sizeValue = sizeRef as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(posValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    /// Attempt to remove quarantine attribute from the running app bundle.
    /// Quarantined unsigned apps can't reliably hold accessibility permissions on Sequoia.
    private func stripQuarantine() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", bundlePath]
        try? process.run()
        process.waitUntilExit()
    }

    private func showTroubleshootingAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission"
        alert.informativeText = """
szn can't detect accessibility permission yet.

Please make sure szn is enabled in:
System Settings → Privacy & Security → Accessibility

If the toggle is already on, try turning it off and on again.
"""
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")

        if alert.runModal() == .alertFirstButtonReturn {
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
