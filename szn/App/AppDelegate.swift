import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var windowManager: WindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AccessibilityService.shared.isPermissionGranted() {
            AccessibilityService.shared.promptPermission()
        }

        statusBarController = StatusBarController()

        windowManager = WindowManager()
        windowManager?.startObserving()
    }
}
