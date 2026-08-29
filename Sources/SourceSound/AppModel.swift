import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var applications: [AudioApplication] = []
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var routeStates: [String: RouteState] = [:]
    @Published private(set) var applicationVolumes: [String: Float] = [:]
    @Published private(set) var pinnedBundleIDs: Set<String> = []
    @Published var searchText = ""
    @Published var lastError: String?
    @Published private(set) var isRefreshing = false

    private var activeRoutes: [String: AudioRoute] = [:]
    private var pendingRouteTokens: [String: UUID] = [:]
    private var refreshTimer: Timer?
    private let routeCreationQueue = DispatchQueue(
        label: "app.sourcesound.route-creation",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let refreshQueue = DispatchQueue(
        label: "app.sourcesound.device-refresh",
        qos: .userInitiated
    )
    private let routeStartTimeout: TimeInterval = 8
    private let preferencesKey = "SourceSound.RoutingChoices"
    private let volumePreferencesKey = "SourceSound.ApplicationVolumes"
    private let pinnedApplicationsKey = "SourceSound.PinnedApplications"
    private let logger = Logger(subsystem: "app.sourcesound.mac", category: "Routing")

    private static let legacyBundleID = "app.soundsource.mac"
    private static let legacyPreferencesKey = "SoundSource.RoutingChoices"

    var filteredApplications: [AudioApplication] {
        let matchingApplications = searchText.isEmpty ? applications : applications.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
        return ApplicationListOrdering.pinnedFirst(
            matchingApplications,
            pinnedBundleIDs: pinnedBundleIDs
        )
    }

    var activeRouteCount: Int {
        activeRoutes.count
    }

    init() {
        migrateLegacyPreferencesIfNeeded()
        applicationVolumes = savedVolumes()
        pinnedBundleIDs = PinnedApplicationPreferences.decode(
            UserDefaults.standard.stringArray(forKey: pinnedApplicationsKey)
        )

        // Construct the first SwiftUI window before restoring saved Core Audio
        // routes. Creating a tap or opening a hardware device can block while a
        // driver wakes, and doing that here prevents the application window from
        // appearing at all.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.refresh()
            self.startRefreshTimer()
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
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

        refreshQueue.async { [weak self] in
            let result = Result {
                (
                    try CoreAudioSystem.audioApplications(),
                    try CoreAudioSystem.outputDevices()
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case let .success((applications, devices)):
                    self.applications = applications
                    self.devices = devices
                    self.reconcileRoutes()
                    if !silent { self.lastError = nil }
                case let .failure(error):
                    if !silent { self.lastError = error.localizedDescription }
                }
            }
        }
    }

    func selectedDeviceUIDs(for application: AudioApplication) -> Set<String> {
        savedPreferences()[application.bundleID] ?? []
    }

    func routeState(for application: AudioApplication) -> RouteState {
        routeStates[application.bundleID] ?? .inactive
    }

    func volume(for application: AudioApplication) -> Float {
        applicationVolumes[application.bundleID] ?? ApplicationVolumePreferences.defaultVolume
    }

    func setVolume(_ volume: Float, for application: AudioApplication) {
        let volume = ApplicationVolumePreferences.clamped(volume)
        applicationVolumes[application.bundleID] = volume
        UserDefaults.standard.set(
            ApplicationVolumePreferences.encode(applicationVolumes),
            forKey: volumePreferencesKey
        )
        activeRoutes[application.bundleID]?.volume = volume
    }

    func isPinned(_ application: AudioApplication) -> Bool {
        pinnedBundleIDs.contains(application.bundleID)
    }

    func togglePin(for application: AudioApplication) {
        if pinnedBundleIDs.contains(application.bundleID) {
            pinnedBundleIDs.remove(application.bundleID)
        } else {
            pinnedBundleIDs.insert(application.bundleID)
        }
        UserDefaults.standard.set(
            PinnedApplicationPreferences.encode(pinnedBundleIDs),
            forKey: pinnedApplicationsKey
        )
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
        pendingRouteTokens.removeValue(forKey: application.bundleID)
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
        let token = UUID()
        let bundleID = application.bundleID
        let routeVolume = volume(for: application)
        pendingRouteTokens[bundleID] = token

        routeCreationQueue.async { [weak self] in
            let result = Result {
                try AudioRoute(
                    application: application,
                    outputDevices: connectedDevices,
                    volume: routeVolume
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if case let .success(route) = result { route.stop() }
                    return
                }
                guard self.pendingRouteTokens[bundleID] == token else {
                    if case let .success(route) = result { route.stop() }
                    return
                }

                self.pendingRouteTokens.removeValue(forKey: bundleID)
                switch result {
                case let .success(route):
                    guard self.savedPreferences()[bundleID] == deviceUIDs else {
                        route.stop()
                        return
                    }
                    self.activeRoutes[bundleID] = route
                    self.routeStates[bundleID] = .active(deviceUIDs: route.deviceUIDs)
                    self.logger.notice(
                        "Activated \(bundleID, privacy: .public) on \(route.deviceUIDs.count) output(s)"
                    )
                    self.lastError = nil
                case let .failure(error):
                    self.routeStates[bundleID] = .failed(message: error.localizedDescription)
                    self.logger.error(
                        "Failed \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    self.lastError = error.localizedDescription
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + routeStartTimeout) { [weak self] in
            guard let self, self.pendingRouteTokens[bundleID] == token else { return }
            self.pendingRouteTokens.removeValue(forKey: bundleID)
            let message = "Starting the audio route timed out. Check the output connection, then select it again."
            self.routeStates[bundleID] = .failed(message: message)
            self.logger.error("Timed out starting \(bundleID, privacy: .public)")
            self.lastError = message
        }
    }

    func stopAllRoutes() {
        pendingRouteTokens.removeAll()
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
        let stalePendingBundleIDs = pendingRouteTokens.keys.filter { !liveBundleIDs.contains($0) }
        for bundleID in stalePendingBundleIDs {
            pendingRouteTokens.removeValue(forKey: bundleID)
            routeStates[bundleID] = .inactive
        }
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
            let routingProcessesChanged = route.routingProcessObjectIDs
                != application.routingProcessObjectIDs
            if processRestarted || outputSetChanged || routingIdentityChanged || routingProcessesChanged {
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
            } else if case .starting = routeStates[application.bundleID] {
                continue
            } else {
                select(deviceUIDs: deviceUIDs, for: application)
            }
        }
    }

    private func savedPreferences() -> [String: Set<String>] {
        RoutingPreferences.decode(UserDefaults.standard.dictionary(forKey: preferencesKey) ?? [:])
    }

    private func savedVolumes() -> [String: Float] {
        ApplicationVolumePreferences.decode(
            UserDefaults.standard.dictionary(forKey: volumePreferencesKey) ?? [:]
        )
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
