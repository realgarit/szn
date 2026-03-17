import Cocoa

final class WindowManager {
    private var observedPIDs: Set<pid_t> = []
    private var axObservers: [pid_t: AXObserver] = [:]

    func startObserving() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(self, selector: #selector(appDidLaunch(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        nc.addObserver(self, selector: #selector(appDidActivate(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        nc.addObserver(self, selector: #selector(appDidTerminate(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        rescanRunningApps()
    }

    /// Re-scan all running apps and install AX observers for any that have
    /// saved profiles but aren't yet being observed. Safe to call multiple
    /// times — already-observed PIDs are skipped.
    func rescanRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  ProfileStore.shared.profile(for: bundleID) != nil else { continue }
            installAXObserver(for: app)
        }
    }

    func stopObserving() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (_, observer) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                 AXObserverGetRunLoopSource(observer),
                                 .defaultMode)
        }
        axObservers.removeAll()
        observedPIDs.removeAll()
    }

    // MARK: - Notifications

    @objc private func appDidLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              ProfileStore.shared.isGloballyEnabled,
              let profile = ProfileStore.shared.profile(for: bundleID),
              profile.isEnabled else { return }

        // Brief delay for the window to appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            AccessibilityService.shared.applyProfile(profile, to: app)
            self?.installAXObserver(for: app)
        }
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              ProfileStore.shared.isGloballyEnabled,
              ProfileStore.shared.profile(for: bundleID) != nil,
              !observedPIDs.contains(app.processIdentifier) else { return }

        installAXObserver(for: app)
    }

    @objc private func appDidTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        removeAXObserver(for: app.processIdentifier)
    }

    // MARK: - AX Observer

    private func installAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !observedPIDs.contains(pid) else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon = refcon else { return }
            let mgr = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
            mgr.handleNewWindow(element)
        }

        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer = observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)

        axObservers[pid] = observer
        observedPIDs.insert(pid)
    }

    private func removeAXObserver(for pid: pid_t) {
        if let observer = axObservers[pid] {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                 AXObserverGetRunLoopSource(observer),
                                 .defaultMode)
        }
        axObservers.removeValue(forKey: pid)
        observedPIDs.remove(pid)
    }

    private func handleNewWindow(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier,
              ProfileStore.shared.isGloballyEnabled,
              let profile = ProfileStore.shared.profile(for: bundleID),
              profile.isEnabled else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AccessibilityService.shared.applyFrame(to: element, profile: profile)
        }
    }
}
