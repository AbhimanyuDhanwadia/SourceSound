# SourceSound

SourceSound is a native macOS application for routing each app to one or more audio outputs. Send Spotify to the MacBook speakers, Apple Music to headphones, or mirror the same application to several connected devices without changing the system-wide default output.

[![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple)](https://github.com/AbhimanyuDhanwadia/SourceSound/releases/latest)
[![Swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)](Package.swift)
[![GitHub release](https://img.shields.io/github/v/release/AbhimanyuDhanwadia/SourceSound)](https://github.com/AbhimanyuDhanwadia/SourceSound/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Features

- Route individual applications to different speakers, headphones, displays, or audio interfaces.
- Select several outputs for one app and mirror its full stereo signal to all of them.
- Convert sample rates and channel formats independently for each selected output.
- Remember routes by application bundle identifier and restore them after relaunch.
- Group Chromium audio helpers with their visible parent app, including Microsoft Edge.
- Configure idle applications before playback starts on macOS 26.
- Run entirely on the Mac; SourceSound does not record or upload audio.

## Download and install

1. Download the latest `SourceSound-*.dmg` from [GitHub Releases](https://github.com/AbhimanyuDhanwadia/SourceSound/releases/latest).
2. Open the disk image and drag `SourceSound.app` into the Applications folder.
3. Open SourceSound and grant **System Audio Recording** access when macOS asks.

The current release is ad-hoc signed for testing and is not Apple-notarized. If Gatekeeper blocks the first launch, Control-click `SourceSound.app`, choose **Open**, and confirm. You can also use **System Settings → Privacy & Security → Open Anyway**.

## Running from source

Requirements:

- macOS 14.2 or later
- Xcode 26 or later, including the macOS 26 SDK
- Command Line Tools selected in Xcode settings

Build the signed local application bundle and run it:

```sh
git clone https://github.com/AbhimanyuDhanwadia/SourceSound.git
cd SourceSound
make app
open dist/SourceSound.app
```

Run the automated test suite:

```sh
make test
```

Create a distributable disk image:

```sh
make dmg
open dist/SourceSound-1.5.dmg
```

You can also open `Package.swift` directly in Xcode. Testing through the generated `.app` bundle is recommended because it includes the required audio-capture privacy description.

## How to use SourceSound

1. Connect every output you want to use, such as headphones, speakers, displays, or USB audio devices.
2. Open SourceSound. Open foreground applications appear in the **Audio Routes** list.
3. Open the output menu beside an application.
4. Check one output to redirect that app, or check several outputs to mirror it to all of them.
5. Allow **System Audio Recording** when prompted. SourceSound captures only the outgoing audio needed for the active route.
6. Start playback. The row changes to **Routed** or shows the number of active outputs.
7. Select **System Default** to remove the custom route, or use **Stop all routes** in the sidebar.

The **How to use** button in the app sidebar presents these instructions at any time. On macOS 14–15, an idle application can display **Waiting** until it connects to Core Audio. On macOS 26, persistent bundle routing can activate before playback and follow audio-process restarts.

## How routing works

Each route creates an Apple Core Audio process tap for one application. SourceSound suppresses that app's ordinary playback only while the route is active, then sends the captured stereo stream to a private aggregate device containing the selected outputs.

Every output receives its own renderer. Matching formats are copied as complete stereo buffers; differing sample rates or channel formats pass through an independent Audio Converter. Core Audio drift compensation keeps secondary devices synchronized with the primary clock device.

Audio service and helper bundle identifiers are grouped with their visible parent application. This is required for Chromium-based applications such as Microsoft Edge, whose audio is produced by `com.microsoft.edgemac.helper` rather than its main process.

## Project structure

| Path | Purpose |
| --- | --- |
| `Sources/SourceSound` | SwiftUI application, Core Audio discovery, taps, routing, and rendering |
| `Tests/SourceSoundTests` | Unit, conversion, live device, Edge-helper, and multi-output lifecycle tests |
| `Resources/Info.plist` | macOS bundle metadata and audio-capture privacy description |
| `Makefile` | Build, test, application bundle, and DMG commands |
| `Package.swift` | Swift Package Manager manifest |

## Current limitations

- Output devices must be connected before they can be selected.
- Multiple windows belonging to one application share the same route because macOS exposes routing at the application/audio-process level.
- Protected audio may refuse capture according to macOS or content-provider policy.
- Device format changes made while a route is active may require selecting the route again.
- Public releases are not yet Developer ID signed or notarized.

## License

SourceSound is available under the [MIT License](LICENSE).
