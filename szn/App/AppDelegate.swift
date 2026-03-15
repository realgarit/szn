import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var windowManager: WindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()

        AccessibilityService.shared.requestPermissionIfNeeded { [weak self] in
            self?.startWindowManager()
        }

        // Check for updates in the background
        UpdateChecker.shared.checkForUpdates()
    }

    private func startWindowManager() {
        guard windowManager == nil else { return }
        windowManager = WindowManager()
        windowManager?.startObserving()
    }
}
