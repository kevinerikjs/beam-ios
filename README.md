# Beam — iOS Client App

Beam is the iPhone app that connects to a paired Mac running Beacon and displays its screen stream with audio. Supports Picture-in-Picture, media controls, viewport locking, and quality selection.

**macOS counterpart:** [beam-macos](https://github.com/flowtheci/beam-macos) — **Download Beacon:** [Beacon.dmg](https://github.com/flowtheci/beacon-releases/releases/latest/download/Beacon.dmg)

---

## Requirements

- iOS 17.0+
- Xcode 15+
- A Mac running Beacon on the same local network

## Local Development

```bash
git clone git@github.com:flowtheci/beam-ios.git
cd beam-ios
git checkout develop        # active development branch
open Beam.xcodeproj
```

Select the `Beam` scheme and a real iOS device as the destination. Build and run.

> **Note:** The simulator cannot test Bonjour discovery, real network streaming, or audio. Always test on a real device.

## Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Production — **protected**. Only updated via PR from `develop`. Triggers Xcode Cloud build → App Store Connect. |
| `develop` | Active development. All feature work and bug fixes go here. |

**Workflow:**
1. Work on `develop` (or a short-lived branch off `develop`)
2. Open a PR from `develop` → `main` when ready to ship
3. Merging to `main` kicks off the Xcode Cloud CI/CD pipeline automatically

## CI/CD — Xcode Cloud

`main` is connected to Xcode Cloud. Merging to `main`:
- Runs a clean build
- Archives and signs with the App Store distribution certificate
- Submits to App Store Connect for review

No manual archive/upload step is needed. If you need to trigger a build manually, use [App Store Connect → Xcode Cloud](https://appstoreconnect.apple.com/teams/R4KDRC8S4D/activityFeed).

> Do **not** push directly to `main` — always go through a PR so Xcode Cloud picks up a clean merge commit.

## Project Structure

```
Beam/
├── BeamApp.swift
├── Views/
│   ├── HomeView.swift          # Connection screen + start button
│   ├── StreamView.swift        # Full-screen streaming view
│   ├── StreamOverlay.swift     # Controls overlay (media keys, PiP, disconnect)
│   ├── PairingView.swift       # Device pairing flow
│   ├── PaywallView.swift       # Free tier limit / upgrade prompt
│   └── OnboardingView.swift
├── Streaming/
│   ├── VideoRenderer.swift     # AVSampleBufferDisplayLayer wrapper
│   ├── AudioPlayer.swift       # AVAudioEngine playback
│   ├── StreamReceiver.swift    # Packet reassembly + video/audio dispatch
│   ├── VideoMotionDetector.swift # Auto video region detection (VTDecompression)
│   ├── PiPController.swift     # Picture-in-Picture management
│   └── Protocol.swift          # Wire protocol (keep in sync with beam-macos)
├── Network/
│   ├── BonjourBrowser.swift    # Discover _beam._tcp on local network
│   └── ConnectionManager.swift # TCP connection lifecycle + auth
├── Pairing/
│   ├── PairingManager.swift
│   └── KeyStore.swift          # Keychain-stored pairing credentials
└── Store/
    ├── StoreManager.swift      # StoreKit 2 IAP
    └── SessionManager.swift    # Free tier timer (Keychain-persisted)
```

## Key Architecture Notes

- Uses `@Observable` (Swift Observation framework) — no `ObservableObject`/`@Published`
- Video: `AVSampleBufferDisplayLayer` for low-latency rendering + PiP
- Audio: `AVAudioEngine` with Float32 PCM, A/V sync via host clock comparison
- Free tier: 30 min session, 24h cooldown, timestamps stored in Keychain (survive reinstall)
- IAP product: `com.beam.ios.unlimited` — one-time $3.79 unlock

## AI Development (Claude Code)

**Install Claude Code:**
```bash
npm install -g @anthropic-ai/claude-code
claude  # run from the repo root
```

`CLAUDE.md` contains shared AI agent rules — architecture constraints, coding conventions, feature status. It's tracked in git and applies to all contributors.

**Personal customization:** Create a `CLAUDE.local.md` in the repo root for your own overrides, notes, or local workflow preferences. It's gitignored and never committed.

```markdown
# CLAUDE.local.md (example)
- My test device is an iPhone 15 Pro on iOS 18.3
- Prefer running on device over simulator always
- My local Beacon host is usually at 192.168.1.x
```
