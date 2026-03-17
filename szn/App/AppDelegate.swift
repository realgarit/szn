import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var windowManager: WindowManager?
    private var bootRetryTimer: Timer?

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

        // After system restart, the AX API may not be fully ready when login
        // items launch. Re-scan running apps after a few seconds to catch any
        // observers that silently failed during early boot.
        scheduleBootRescan()
    }

    private func scheduleBootRescan() {
        var attempts = 0
        bootRetryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            attempts += 1
            self?.windowManager?.rescanRunningApps()
            if attempts >= 3 {
                timer.invalidate()
                self?.bootRetryTimer = nil
            }
        }
    }
}
