import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            toggles
            Divider()
            profilesList
            Spacer()
            footer
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .font(.title)
            Text("szn")
                .font(.title.bold())
            Text("- Window Resizer")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable szn", isOn: $store.isGloballyEnabled)
                .toggleStyle(.switch)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin, perform: { value in
                    do {
                        if value {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !value
                    }
                })
        }
    }

    private var profilesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved Profiles")
                .font(.headline)

            if store.profiles.isEmpty {
                Text("No profiles saved yet.\nUse the menu bar icon to save window sizes.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(sortedProfiles) { profile in
                        profileRow(profile)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 150)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("szn v\(updater.currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let newVersion = updater.availableVersion {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("v\(newVersion) available — Update Now") {
                    UpdateChecker.shared.promptAndUpdate()
                }
                .font(.caption)
                .buttonStyle(.link)
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    private var sortedProfiles: [WindowProfile] {
        store.profiles.values.sorted { $0.appName.localizedCompare($1.appName) == .orderedAscending }
    }

    private func profileRow(_ profile: WindowProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .fontWeight(.medium)
                let dims = "\(Int(profile.size.width)) × \(Int(profile.size.height))"
                let detail = profile.savePosition ? "\(dims) + position" : "\(dims) (size only)"
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { profile.isEnabled },
                set: { _ in store.toggleProfile(for: profile.bundleIdentifier) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Button(role: .destructive) {
                store.remove(for: profile.bundleIdentifier)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
