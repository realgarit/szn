import Cocoa

final class WindowManager {
    private var observedPIDs: Set<pid_t> = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var refreshTimer: Timer?
    private var screenChangeWorkItem: DispatchWorkItem?

    func startObserving() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(self, selector: #selector(appDidLaunch(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        nc.addObserver(self, selector: #selector(appDidActivate(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        nc.addObserver(self, selector: #selector(appDidTerminate(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // Re-create AX observers after wake — Mach connections go stale.
        nc.addObserver(self, selector: #selector(onWake),
                       name: NSWorkspace.didWakeNotification, object: nil)

        // Display changes (connect/disconnect) can break AX connections.
        // Debounced — screen params fire multiple times in rapid succession.
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScreenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // When profiles change, install observers for any newly saved apps
        NotificationCenter.default.addObserver(
            self, selector: #selector(onProfilesChanged),
            name: .profilesDidChange, object: nil)

        rescanRunningApps()
        startPeriodicRefresh()
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
        refreshTimer?.invalidate()
        refreshTimer = nil
        screenChangeWorkItem?.cancel()
        screenChangeWorkItem = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeAllObservers()
    }

    // MARK: - Event Handlers

    @objc private func onProfilesChanged() {
        rescanRunningApps()
    }

    @objc private func onWake() {
        // Brief delay to let the AX API fully reconnect after wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.reinstallAllObservers()
        }
    }

    @objc private func onScreenChanged() {
        // Debounce — screen parameter notifications fire in bursts.
        screenChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reinstallAllObservers()
        }
        screenChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - Periodic Refresh

    /// Every 5 minutes, refresh each observer individually.
    /// Unlike the global reinstall, this removes+reinstalls one PID at a time
    /// so there's never a window where ALL observers are gone at once.
    private func startPeriodicRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshAllObservers()
        }
    }

    /// Refresh each observer one at a time — no global teardown gap.
    private func refreshAllObservers() {
        let pids = Array(observedPIDs)
        for pid in pids {
            removeAXObserver(for: pid)
            if let app = NSRunningApplication(processIdentifier: pid) {
                installAXObserver(for: app)
            }
        }
    }

    /// Global teardown + reinstall. Used for wake and screen changes
    /// where ALL Mach connections are likely broken at once.
    private func reinstallAllObservers() {
        removeAllObservers()
        rescanRunningApps()
    }

    private func removeAllObservers() {
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
              bundleID != Bundle.main.bundleIdentifier,
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
              bundleID != Bundle.main.bundleIdentifier,
              ProfileStore.shared.isGloballyEnabled,
              ProfileStore.shared.profile(for: bundleID) != nil else { return }

        // Always refresh the observer for profiled apps on activation.
        // AX Mach connections can silently break at any time — refreshing
        // on activate ensures the observer is alive before the user opens
        // a new window. Cost is ~50μs, completely negligible.
        let pid = app.processIdentifier
        if observedPIDs.contains(pid) {
            removeAXObserver(for: pid)
        }
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
              bundleID != Bundle.main.bundleIdentifier,
              ProfileStore.shared.isGloballyEnabled,
              let profile = ProfileStore.shared.profile(for: bundleID),
              profile.isEnabled else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AccessibilityService.shared.applyFrame(to: element, profile: profile)
        }
    }
}
