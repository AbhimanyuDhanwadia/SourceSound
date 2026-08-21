import SwiftUI

@main
struct SourceSoundApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 980, height: 650)

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("SourceSound")
                    .font(.title2.bold())
                Text("Per-application audio output routing for macOS 14.2 and later.")
                    .foregroundStyle(.secondary)
                Button("Open System Audio Privacy Settings") {
                    model.openAudioPrivacySettings()
                }
            }
            .padding(24)
            .frame(width: 430)
        }
    }
}
