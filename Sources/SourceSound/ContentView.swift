import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAboutRouting = false
    @State private var showingHowToUse = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            mainContent
        }
        .frame(minWidth: 1040, minHeight: 570)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("SourceSound couldn’t update the route", isPresented: errorBinding) {
            Button("Audio Privacy Settings") { model.openAudioPrivacySettings() }
            Button("Dismiss", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
        .sheet(isPresented: $showingAboutRouting) {
            RoutingHelpView()
        }
        .sheet(isPresented: $showingHowToUse) {
            HowToUseView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.indigo, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text("SourceSound")
                        .font(.headline)
                    Text("Per-app audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            Divider()

            VStack(spacing: 6) {
                SidebarRow(
                    title: "Audio Routes",
                    symbol: "point.3.connected.trianglepath.dotted",
                    badge: model.activeRouteCount == 0 ? nil : "\(model.activeRouteCount)",
                    isSelected: true
                )
                Button {
                    showingHowToUse = true
                } label: {
                    SidebarRow(title: "How to use", symbol: "questionmark.circle", badge: nil, isSelected: false)
                }
                .buttonStyle(.plain)
                Button {
                    showingAboutRouting = true
                } label: {
                    SidebarRow(title: "How it works", symbol: "info.circle", badge: nil, isSelected: false)
                }
                .buttonStyle(.plain)
            }
            .padding(10)

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Label("macOS 14.2+", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if model.activeRouteCount > 0 {
                    Button("Stop all routes", role: .destructive) {
                        model.stopAllRoutes()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(16)
        }
        .background(.thinMaterial)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.applications.isEmpty {
                ContentUnavailableView {
                    Label("No audio apps found", systemImage: "speaker.slash")
                } description: {
                    Text("Start playback in an app, then refresh to make it appear here.")
                } actions: {
                    Button("Refresh") { model.refresh() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.filteredApplications) { application in
                            ApplicationRouteRow(application: application)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Routes")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Choose an output now—even before playback starts.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Search apps", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(model.isRefreshing ? .degrees(180) : .zero)
            }
            .buttonStyle(.bordered)
            .help("Refresh apps and audio devices")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }
}

private struct ApplicationRouteRow: View {
    @EnvironmentObject private var model: AppModel
    let application: AudioApplication

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: application.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(application.name)
                        .font(.headline)
                    Circle()
                        .fill(activityColor)
                        .frame(width: 7, height: 7)
                        .help(activityDescription)
                }
                HStack(spacing: 5) {
                    Text(activityDescription)
                    Text("·")
                    Text(application.bundleID)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            ApplicationVolumeControl(application: application)
                .frame(width: 130)

            routeStatus
                .frame(width: 74, alignment: .trailing)

            OutputSelectionMenu(application: application)
                .frame(width: 235)
                .disabled(isStarting)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.045), radius: 8, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var routeStatus: some View {
        switch model.routeState(for: application) {
        case .inactive:
            Text("Default")
                .foregroundStyle(.secondary)
        case let .waiting(deviceUIDs):
            Label(deviceUIDs.count > 1 ? "Waiting ×\(deviceUIDs.count)" : "Waiting", systemImage: "clock")
                .foregroundStyle(.blue)
        case .starting:
            ProgressView()
                .controlSize(.small)
        case let .active(deviceUIDs):
            Label(deviceUIDs.count > 1 ? "\(deviceUIDs.count) outputs" : "Routed", systemImage: "arrow.triangle.branch")
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var isStarting: Bool {
        model.routeState(for: application) == .starting
    }

    private var activityColor: Color {
        if application.isProducingAudio { return .green }
        if application.isConnectedToAudio { return .blue }
        return .secondary.opacity(0.35)
    }

    private var activityDescription: String {
        if application.isProducingAudio { return "Playing audio" }
        if application.isConnectedToAudio { return "Audio ready" }
        return "Open"
    }

}

private struct ApplicationVolumeControl: View {
    @EnvironmentObject private var model: AppModel
    let application: AudioApplication

    private var volume: Float {
        model.volume(for: application)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: volumeSymbol)
                    .frame(width: 15)
                Text("Volume")
                Spacer(minLength: 2)
                Text("\(Int((volume * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Slider(value: volumeBinding, in: 0...1, step: 0.01)
                .controlSize(.small)
                .accessibilityLabel("\(application.name) volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
        }
        .help("Set \(application.name)'s volume when routed through SourceSound")
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(volume) },
            set: { model.setVolume(Float($0), for: application) }
        )
    }

    private var volumeSymbol: String {
        if volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct OutputSelectionMenu: View {
    @EnvironmentObject private var model: AppModel
    let application: AudioApplication

    private var selection: Set<String> {
        model.selectedDeviceUIDs(for: application)
    }

    private var disconnectedCount: Int {
        selection.subtracting(Set(model.devices.map(\.uid))).count
    }

    var body: some View {
        Menu {
            Button {
                model.select(deviceUIDs: [], for: application)
            } label: {
                Label("System Default", systemImage: selection.isEmpty ? "checkmark" : "macbook.and.iphone")
            }

            Divider()

            ForEach(model.devices) { device in
                Toggle(isOn: toggleBinding(for: device.uid)) {
                    Label(device.name, systemImage: device.symbolName)
                }
            }

            if disconnectedCount > 0 {
                Divider()
                Button {
                    model.removeDisconnectedOutputs(for: application)
                } label: {
                    Label(
                        "Remove \(disconnectedCount) disconnected output\(disconnectedCount == 1 ? "" : "s")",
                        systemImage: "speaker.slash"
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selection.isEmpty ? "macbook.and.iphone" : "speaker.wave.2")
                    .foregroundStyle(selection.isEmpty ? Color.secondary : Color.accentColor)
                Text(selectionSummary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .help("Select one or more outputs for \(application.name)")
    }

    private var selectionSummary: String {
        if selection.isEmpty { return "System Default" }
        if selection.count > 1 { return "\(selection.count) Outputs" }
        guard let uid = selection.first else { return "System Default" }
        return model.devices.first(where: { $0.uid == uid })?.name ?? "Output disconnected"
    }

    private func toggleBinding(for deviceUID: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(deviceUID) },
            set: { newValue in
                if newValue != selection.contains(deviceUID) {
                    model.toggle(deviceUID: deviceUID, for: application)
                }
            }
        )
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let badge: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
            Text(title)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

private struct RoutingHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("How routing works")
                        .font(.title2.bold())
                    Text("Private, local, and reversible")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("SourceSound uses Apple’s Core Audio process taps. Choose one or more outputs for any open app; on macOS 26, the route activates immediately and follows browser and audio helper restarts. During routing, macOS captures only that app’s outgoing sound, suppresses its normal playback, and sends an independent real-time stream to every selected device—even when it is not the system default.")

            VStack(alignment: .leading, spacing: 10) {
                Label("Your audio never leaves this Mac.", systemImage: "lock.shield")
                Label("On macOS 14–15, a Waiting route activates when playback begins.", systemImage: "clock.arrow.circlepath")
                Label("Check multiple outputs to play the same app through all of them.", systemImage: "speaker.wave.2.bubble")
                Label("Set a separate volume for every routed application.", systemImage: "slider.horizontal.3")
                Label("Changing back to System Default stops the tap immediately.", systemImage: "arrow.uturn.backward")
                Label("The first route prompts for System Audio Recording access.", systemImage: "checkmark.shield")
            }
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 500)
    }
}

private struct HowToUseView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(String, String, String)] = [
        ("1", "Connect your outputs", "Connect headphones, speakers, displays, or USB audio devices before selecting them."),
        ("2", "Choose an app’s outputs", "Open the output menu beside an app. Check one device, or check several to mirror the same audio."),
        ("3", "Set the app volume", "Use the Volume slider in that app’s row. Each application remembers its own level."),
        ("4", "Allow audio access", "The first active route asks for System Audio Recording permission. Choose Allow."),
        ("5", "Start playback", "The status changes to Routed. On macOS 14–15, an idle app may show Waiting until it begins using audio."),
        ("6", "Return to normal", "Choose System Default to stop that app’s custom route, or use Stop all routes in the sidebar.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("How to use SourceSound")
                        .font(.title2.bold())
                    Text("Route and mix an app in six quick steps")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 15) {
                ForEach(steps, id: \.0) { number, title, detail in
                    HStack(alignment: .top, spacing: 12) {
                        Text(number)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.headline)
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 600)
    }
}
