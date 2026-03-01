# Beam iOS Client App

## Overview
iPhone app that connects to a paired Mac running Beacon and displays the Mac's screen stream with audio. Supports PiP and basic media controls.

## Key References
- **PRD:** `../PRD.md` (source of truth for all requirements)
- **Work State:** `./WORKPAD.md` (current progress and next steps)
- **macOS Counterpart:** `../beam-macos/` (the streaming source)

## Tech Stack
- Swift / SwiftUI
- iOS 17.0+ deployment target
- Network.framework (UDP stream receiving + TCP control)
- Bonjour / NWBrowser (discover Mac on network)
- AVSampleBufferDisplayLayer (low-latency video rendering)
- AVAudioEngine (audio playback)
- AVPictureInPictureController (PiP support)
- StoreKit 2 (IAP for unlimited unlock)
- AVKit (media playback infrastructure)

## Architecture Rules
- **Instant start.** When a paired Mac is available, the stream should start within 2 seconds of tapping "Start". Preconnect via Bonjour as soon as the app opens.
- **PiP is first-class.** The video layer must be set up for PiP from the start, not bolted on later. Use AVSampleBufferDisplayLayer + AVPictureInPictureController.
- **Background audio.** The app needs the `audio` background mode so audio continues when PiP is active or screen is locked.
- **StoreKit 2 only.** Use the modern StoreKit 2 API for IAP. No legacy StoreKit.
- **Free tier enforcement.** Session timer logic must be tamper-resistant (server-side validation ideal, but for v1 use Keychain-stored timestamps that survive app reinstall).
- **No third-party SDKs.** No analytics, no crash reporting, no ad SDKs in v1. Pure Apple.

## Project Structure (Target)
```
beam-ios/
├── CLAUDE.md
├── WORKPAD.md
├── Beam/
│   ├── BeamApp.swift               # App entry point
│   ├── Views/
│   │   ├── HomeView.swift           # Main screen (connection status, start button)
│   │   ├── StreamView.swift         # Full-screen streaming view
│   │   ├── StreamOverlay.swift      # Controls overlay (media keys, PiP, disconnect)
│   │   ├── PairingView.swift        # QR scanner + manual code entry
│   │   ├── PaywallView.swift        # Upgrade prompt (free tier limit hit)
│   │   └── OnboardingView.swift     # First-launch welcome + setup
│   ├── Streaming/
│   │   ├── VideoRenderer.swift      # AVSampleBufferDisplayLayer wrapper
│   │   ├── AudioPlayer.swift        # AVAudioEngine playback
│   │   ├── StreamReceiver.swift     # Network.framework UDP receive + reassembly
│   │   ├── PiPController.swift      # PiP setup and management
│   │   └── Protocol.swift           # Shared message definitions (keep in sync with macOS!)
│   ├── Network/
│   │   ├── BonjourBrowser.swift     # Discover _beam._tcp services
│   │   ├── ConnectionManager.swift  # Manage connection lifecycle
│   │   └── ControlChannel.swift     # TCP control messages (send media keys, etc.)
│   ├── Pairing/
│   │   ├── PairingManager.swift     # Handle pairing flow
│   │   ├── QRScanner.swift          # Camera QR code scanner
│   │   └── KeyStore.swift           # Persist paired device keys (Keychain)
│   ├── Store/
│   │   ├── StoreManager.swift       # StoreKit 2 IAP logic
│   │   └── SessionManager.swift     # Free tier timer + cooldown logic
│   └── Resources/
│       └── Assets.xcassets
├── Beam.xcodeproj
└── BeamTests/
```

## Coding Conventions
- Use Swift concurrency (async/await, actors) for all asynchronous work
- Use `@Observable` (Observation framework) instead of `ObservableObject`/`@Published`
- SwiftUI for all UI - no UIKit unless absolutely necessary (camera for QR scanning may need UIKit)
- Use structured concurrency (TaskGroup, etc.) over raw Task {} where possible
- Error handling: use typed throws where practical, always handle errors gracefully in UI
- Naming: follow Swift API Design Guidelines exactly
- No force unwraps (`!`) except for known-safe static resources
- All user-facing strings should be localizable from day one (`String(localized:)`)
