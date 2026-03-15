import Cocoa
import ApplicationServices

final class AccessibilityService {
    static let shared = AccessibilityService()

    func isPermissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func promptPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
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
}
