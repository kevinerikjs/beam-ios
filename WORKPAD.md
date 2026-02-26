# Beam iOS - Work State

## Current Status: Pre-Testing Polish Pass Complete ✅

## Completed
- [x] Project directory created
- [x] CLAUDE.md with architecture rules and conventions
- [x] Target project structure defined
- [x] **Beam.xcodeproj** - Full Xcode project (auto-generated), links 21 Swift files + 8 frameworks
- [x] **Streaming/Protocol.swift** - Wire protocol (mirrors macOS; kept in sync manually for now)
- [x] **BeamApp.swift** - `@main` SwiftUI entry, `RootView` navigation
- [x] **BeamAppState.swift** - Central `@Observable` state (pairing, discovery, streaming, session)
- [x] **Streaming/VideoRenderer.swift** - `AVSampleBufferDisplayLayer` UIView wrapper + SwiftUI bridge
- [x] **Streaming/AudioPlayer.swift** - `AVAudioEngine` + AAC-LC → PCM decoding + ADTS parsing
- [x] **Streaming/StreamReceiver.swift** - Packet reassembly (video fragmentation), SPS/PPS handling, audio dispatch
- [x] **Streaming/PiPController.swift** - Full `AVPictureInPictureController` setup with `AVPictureInPictureSampleBufferPlaybackDelegate`
- [x] **Network/BonjourBrowser.swift** - `NWBrowser` for `_beam._tcp` discovery
- [x] **Network/ConnectionManager.swift** - TCP connection lifecycle, auth handshake, packet dispatch
- [x] **Network/ControlChannel.swift** - Media key command wrapper
- [x] **Pairing/KeyStore.swift** - Keychain persistence for `PairedMac` + stable device ID (survives reinstall)
- [x] **Pairing/PairingManager.swift** - Full pairing state machine (hello → challenge → code verify → pair_success)
- [x] **Pairing/QRScanner.swift** - Camera QR scanner with `AVCaptureMetadataOutput`
- [x] **Store/StoreManager.swift** - StoreKit 2 IAP (`com.beam.ios.unlimited` one-time purchase + restore)
- [x] **Store/SessionManager.swift** - 10-min free tier timer + 24h cooldown (Keychain-backed timestamps)
- [x] **Views/HomeView.swift** - Full home screen (search, connection status, start button, free tier info)
- [x] **Views/StreamView.swift** - Full-screen stream view with PiP, session timer hook, auto-hiding overlay
- [x] **Views/StreamOverlay.swift** - Media controls (prev/play/pause/next), PiP button, quality indicator, free-tier timer
- [x] **Views/PairingView.swift** - QR scanner + manual code entry + pairing flow UI
- [x] **Views/PaywallView.swift** - Full paywall UI (feature list, IAP purchase button, restore, try again tomorrow)
- [x] **Views/OnboardingView.swift** - 3-page swipeable onboarding with "Set up Beam" CTA
- [x] **Info.plist** - NSCameraUsageDescription, NSLocalNetworkUsageDescription, Bonjour, audio background mode
- [x] **Beam.entitlements** - App sandbox, network client, IAP product ID
- [x] Build: **ZERO errors, ZERO warnings** ✅

## Architecture Notes
- `BeamAppState` is the observable hub; all views consume it via `@Environment`
- `PairedMac.id` = the iOS device's Keychain-stable UUID (survives reinstall) - matches what macOS stores
- `DiscoveredHost.endpoint` typed as `any Sendable` for module separation; cast to `NWEndpoint` at use sites
- `VideoRenderer` is a `UIView` subclass wrapping `AVSampleBufferDisplayLayer` - PiP works from day 1
- Audio decoding: ADTS frame → `AVAudioCompressedBuffer` → `AVAudioConverter` → `AVAudioPCMBuffer` → player
- Free tier: Keychain timestamps survive reinstall; `StoreManager.isPurchased` checked before starting timer

## Next Steps (In Order)
1. **Open both projects** - Open both `.xcodeproj` files in Xcode, set Development Team in Signing & Capabilities
2. **Configure StoreKit** - Create `StoreKit Configuration.storekit` file for local IAP testing, add `com.beam.ios.unlimited` product
3. **Real device test - macOS side**:
   - Run BeamHost, grant Screen Recording permission
   - Verify Bonjour service `_beam._tcp` is advertised (use Discovery app or similar)
4. **Real device test - iOS side**:
   - Run Beam on iPhone, verify Bonjour discovery finds the Mac
   - Complete pairing flow (QR or manual code)
   - Tap "Start Beam" - verify stream appears
5. **Latency tuning** - Measure end-to-end and adjust buffer depths if needed
6. **PiP testing** - Verify PiP works with `audio` background mode entitlement
7. **IAP testing** - Test purchase + restore flow via StoreKit configuration file
8. **Free tier timing** - Test 10-min session expiry and 24h cooldown
9. **Polish** - App icons, launch screen, any rough UX edges

## Polish Pass Fixes Applied
- **[FIXED] DiscoveredHost type safety** - `endpoint: any Sendable` changed to `endpoint: NWEndpoint`. All use-sites (ConnectionManager, PairingManager) removed the `as? NWEndpoint` cast. Import Network added to BeamAppState.swift.
- **[FIXED] Connection quality metric** - `ConnectionManager` now tracks `lastPacketReceivedAt` on every incoming packet. A 2-second repeating timer maps elapsed time (< 0.3s → 1.0, < 0.8s → 0.75, < 1.5s → 0.5, else → 0.25) to `BeamAppState.connectionQuality`. The StreamOverlay bars now show live signal quality.
- **[FIXED] Heartbeat pong** - iOS already responded to `.heartbeat` packets with a JSON `.pong`. Now the macOS side sends a heartbeat every 5 seconds, keeping idle connections alive through NAT.

## Known Issues / Notes for Testing
- `ConnectionManager` currently uses TCP for all stream data. If latency is too high on congested WiFi,
  upgrade to UDP (StreamServer on macOS already supports it architecturally).
- `AVAudioCompressedBuffer` init is non-failable in Swift; ADTS parsing assumes standard 44100Hz stereo.
  If Mac sends different sample rate, update `AudioPlayer.decodeAAC()`.
- PiP requires `audio` background mode in Info.plist AND AVAudioSession active. Both are set up.
- The `BonjourBrowser` resolves host via a temporary NWConnection (connect → get endpoint → cancel).
  This is a known pattern; latency of ~0.5s before host is "discovered" is expected.
- StoreKit 2 product `com.beam.ios.unlimited` must be created in App Store Connect before TestFlight.
  For development, use a local `.storekit` configuration file.

## Files Created
```
beam-ios/
├── CLAUDE.md
├── WORKPAD.md
├── Beam.xcodeproj/
│   ├── project.pbxproj         ← Auto-generated
│   └── project.xcworkspace/
│       └── contents.xcworkspacedata
└── Beam/
    ├── BeamApp.swift
    ├── BeamAppState.swift
    ├── Info.plist
    ├── Beam.entitlements
    ├── Streaming/
    │   ├── Protocol.swift
    │   ├── StreamReceiver.swift
    │   ├── VideoRenderer.swift
    │   ├── AudioPlayer.swift
    │   └── PiPController.swift
    ├── Network/
    │   ├── BonjourBrowser.swift
    │   ├── ConnectionManager.swift
    │   └── ControlChannel.swift
    ├── Pairing/
    │   ├── KeyStore.swift
    │   ├── PairingManager.swift
    │   └── QRScanner.swift
    ├── Store/
    │   ├── StoreManager.swift
    │   └── SessionManager.swift
    ├── Views/
    │   ├── HomeView.swift
    │   ├── StreamView.swift
    │   ├── StreamOverlay.swift
    │   ├── PairingView.swift
    │   ├── PaywallView.swift
    │   └── OnboardingView.swift
    └── Resources/
        └── Assets.xcassets/
```
