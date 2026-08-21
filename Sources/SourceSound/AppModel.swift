import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var applications: [AudioApplication] = []
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var routeStates: [String: RouteState] = [:]
    @Published var searchText = ""
    @Published var lastError: String?
    @Published private(set) var isRefreshing = false

    private var activeRoutes: [String: AudioRoute] = [:]
    private var refreshTimer: Timer?
    private let preferencesKey = "SourceSound.RoutingChoices"
    private let logger = Logger(subsystem: "app.sourcesound.mac", category: "Routing")

    private static let legacyBundleID = "app.soundsource.mac"
    private static let legacyPreferencesKey = "SoundSource.RoutingChoices"

    var filteredApplications: [AudioApplication] {
        guard !searchText.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var activeRouteCount: Int {
        activeRoutes.count
    }

    init() {
        migrateLegacyPreferencesIfNeeded()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(silent: true) }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        activeRoutes.values.forEach { $0.stop() }
    }

    func refresh(silent: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            applications = try CoreAudioSystem.audioApplications()
            devices = try CoreAudioSystem.outputDevices()
            reconcileRoutes()
            if !silent { lastError = nil }
        } catch {
            if !silent { lastError = error.localizedDescription }
        }
    }

    func selectedDeviceUIDs(for application: AudioApplication) -> Set<String> {
        savedPreferences()[application.bundleID] ?? []
    }

    func routeState(for application: AudioApplication) -> RouteState {
        routeStates[application.bundleID] ?? .inactive
    }

    func toggle(deviceUID: String, for application: AudioApplication) {
        var selection = selectedDeviceUIDs(for: application)
        if selection.contains(deviceUID) {
            selection.remove(deviceUID)
        } else {
            selection.insert(deviceUID)
        }
        select(deviceUIDs: selection, for: application)
    }

    func removeDisconnectedOutputs(for application: AudioApplication) {
        let connectedUIDs = Set(devices.map(\.uid))
        select(
            deviceUIDs: selectedDeviceUIDs(for: application).intersection(connectedUIDs),
            for: application
        )
    }

    func select(deviceUIDs: Set<String>, for application: AudioApplication) {
        if let existing = activeRoutes.removeValue(forKey: application.bundleID) {
            existing.stop()
        }

        guard !deviceUIDs.isEmpty else {
            routeStates[application.bundleID] = .inactive
            removePreference(bundleID: application.bundleID)
            return
        }

        savePreference(bundleID: application.bundleID, deviceUIDs: deviceUIDs)
        let connectedDevices = devices.filter { deviceUIDs.contains($0.uid) }

        guard !connectedDevices.isEmpty else {
            routeStates[application.bundleID] = .waiting(deviceUIDs: deviceUIDs)
            logger.notice("Waiting for selected outputs for \(application.bundleID, privacy: .public)")
            lastError = nil
            return
        }

        guard AudioRoute.canCreateRoute(for: application) else {
            routeStates[application.bundleID] = .waiting(deviceUIDs: deviceUIDs)
            logger.notice("Waiting for an audio process from \(application.bundleID, privacy: .public)")
            lastError = nil
            return
        }

        routeStates[application.bundleID] = .starting
        do {
            let route = try AudioRoute(application: application, outputDevices: connectedDevices)
            activeRoutes[application.bundleID] = route
            routeStates[application.bundleID] = .active(deviceUIDs: route.deviceUIDs)
            logger.notice("Activated \(application.bundleID, privacy: .public) on \(route.deviceUIDs.count) output(s)")
            lastError = nil
        } catch {
            routeStates[application.bundleID] = .failed(message: error.localizedDescription)
            logger.error("Failed \(application.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func stopAllRoutes() {
        activeRoutes.values.forEach { $0.stop() }
        activeRoutes.removeAll()
        routeStates = Dictionary(uniqueKeysWithValues: applications.map { ($0.bundleID, .inactive) })
        UserDefaults.standard.removeObject(forKey: preferencesKey)
    }

    func openAudioPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func reconcileRoutes() {
        let liveBundleIDs = Set(applications.map(\.bundleID))
        let staleBundleIDs = activeRoutes.keys.filter { !liveBundleIDs.contains($0) }
        for bundleID in staleBundleIDs {
            activeRoutes.removeValue(forKey: bundleID)?.stop()
            routeStates[bundleID] = .inactive
        }

        for application in applications {
            guard let route = activeRoutes[application.bundleID] else { continue }
            let processRestarted = !route.usesPersistentBundleRouting
                && route.processObjectID != application.processObjectID
            let selectedUIDs = savedPreferences()[application.bundleID] ?? []
            let connectedSelectedUIDs = Set(devices.lazy.map(\.uid).filter(selectedUIDs.contains))
            let outputSetChanged = route.deviceUIDs != connectedSelectedUIDs
            let routingIdentityChanged = route.routingBundleIDs != application.routingBundleIDs
            if processRestarted || outputSetChanged || routingIdentityChanged {
                activeRoutes.removeValue(forKey: application.bundleID)?.stop()
                routeStates[application.bundleID] = .inactive
            }
        }

        let preferences = savedPreferences()
        for application in applications where activeRoutes[application.bundleID] == nil {
            guard let deviceUIDs = preferences[application.bundleID], !deviceUIDs.isEmpty else { continue }
            let connectedUIDs = Set(devices.lazy.map(\.uid).filter(deviceUIDs.contains))

            let needsAudioProcess = !AudioRoute.canCreateRoute(for: application)
            if needsAudioProcess || connectedUIDs.isEmpty {
                routeStates[application.bundleID] = .waiting(deviceUIDs: deviceUIDs)
            } else if case .failed = routeStates[application.bundleID] {
                continue
            } else {
                select(deviceUIDs: deviceUIDs, for: application)
            }
        }
    }

    private func savedPreferences() -> [String: Set<String>] {
        RoutingPreferences.decode(UserDefaults.standard.dictionary(forKey: preferencesKey) ?? [:])
    }

    private func migrateLegacyPreferencesIfNeeded() {
        let defaults = UserDefaults.standard
        guard
            defaults.object(forKey: preferencesKey) == nil,
            let legacyDomain = defaults.persistentDomain(forName: Self.legacyBundleID),
            let legacyPreferences = legacyDomain[Self.legacyPreferencesKey] as? [String: Any]
        else { return }

        let migrated = RoutingPreferences.encode(RoutingPreferences.decode(legacyPreferences))
        if !migrated.isEmpty {
            defaults.set(migrated, forKey: preferencesKey)
        }
    }

    private func savePreference(bundleID: String, deviceUIDs: Set<String>) {
        var preferences = savedPreferences()
        preferences[bundleID] = deviceUIDs
        UserDefaults.standard.set(RoutingPreferences.encode(preferences), forKey: preferencesKey)
    }

    private func removePreference(bundleID: String) {
        var preferences = savedPreferences()
        preferences.removeValue(forKey: bundleID)
        UserDefaults.standard.set(RoutingPreferences.encode(preferences), forKey: preferencesKey)
    }
}
