# SourceSound

SourceSound is a native macOS application for routing each app to one or more audio outputs. Send Spotify to the MacBook speakers, Apple Music to headphones, or mirror the same application to several connected devices without changing the system-wide default output.

[![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple)](https://github.com/AbhimanyuDhanwadia/SourceSound/releases/latest)
[![Swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)](Package.swift)
[![GitHub release](https://img.shields.io/github/v/release/AbhimanyuDhanwadia/SourceSound)](https://github.com/AbhimanyuDhanwadia/SourceSound/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Features

- Route individual applications to different speakers, headphones, displays, or audio interfaces.
- Set and remember a separate 0–100% volume for every application.
- Select several outputs for one app and mirror its full stereo signal to all of them.
- Open every selected device independently so non-default USB speakers and headphones work without changing the system output.
- Synchronize each output with a lock-free real-time ring buffer while Core Audio handles that device's clock and sample-rate conversion.
- Remember routes by application bundle identifier and restore them after relaunch.
- Group Chromium and WebKit audio helpers with their visible browser, including Microsoft Edge and Safari.
- Retain system-owned browser audio services when macOS exposes their Core Audio identity but withholds PID metadata.
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
open dist/SourceSound-1.8.dmg
```

You can also open `Package.swift` directly in Xcode. Testing through the generated `.app` bundle is recommended because it includes the required audio-capture privacy description.

## How to use SourceSound

1. Connect every output you want to use, such as headphones, speakers, displays, or USB audio devices.
2. Open SourceSound. Open foreground applications appear in the **Audio Routes** list.
3. Open the output menu beside an application.
4. Check one output to redirect that app, or check several outputs to mirror it to all of them.
5. Set that application’s **Volume** slider anywhere from 0–100%. Each app remembers its own value.
6. Allow **System Audio Recording** when prompted. SourceSound captures only the outgoing audio needed for the active route.
7. Start playback. The row changes to **Routed** or shows the number of active outputs.
8. Select **System Default** to remove the custom route, or use **Stop all routes** in the sidebar.

The **How to use** button in the app sidebar presents these instructions at any time. On macOS 14–15, an idle application can display **Waiting** until it connects to Core Audio. On macOS 26, persistent bundle routing can activate before playback and follow audio-process restarts.

## How routing works

Each route creates an Apple Core Audio process tap for one application. SourceSound suppresses that app's ordinary playback only while the route is active and places only the tap in a private capture aggregate device, following Apple's capture model.

Every selected speaker or headphone is opened directly through its own Core Audio HAL output unit. A preallocated, lock-free ring buffer carries the captured stereo frames to each device independently. The HAL performs device-clock and sample-rate conversion, so a 48 kHz browser tap can continuously feed a non-default 44.1 kHz USB speaker without silent buffer tails or requiring that speaker to become the system default.

Per-app volume is stored independently and delivered to the audio callback through a lock-free C11 atomic. A short gain ramp is applied across each buffer whenever the slider changes, preventing abrupt changes from producing clicks.

Audio service and helper process identifiers are grouped with their visible parent application. This is required for Chromium browsers such as Microsoft Edge, whose audio is produced by `com.microsoft.edgemac.helper`, and Safari, whose audio is produced by `com.apple.WebKit.GPU`. SourceSound keeps the Core Audio object routable even when macOS withholds optional PID or running-state metadata for a system-owned WebKit service. Active routes rebuild automatically when a browser helper starts or restarts.

## Project structure

| Path | Purpose |
| --- | --- |
| `Sources/SourceSound` | SwiftUI application, Core Audio discovery, taps, routing, and rendering |
| `Sources/SourceSoundAtomics` | Lock-free, macOS 14-compatible atomic storage for ring-buffer synchronization and volume updates |
| `Tests/SourceSoundTests` | Unit, ring-buffer, live browser-signal, non-default USB, and simultaneous multi-output tests |
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
