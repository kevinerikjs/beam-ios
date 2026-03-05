# Beam iOS - Work State

## Current Status: Active Development — Testing + Feature Pass

---

## Completed (This Session)

### Bug Fixes
- [x] **Audio: non-interleaved format crash** — `AVAudioPlayerNode` requires `interleaved: false`; fixed outputFormat + decoder ASBD flags/sizes
- [x] **Audio session -50 error** — removed `.allowAirPlay` from session options; kept `[.mixWithOthers]`
- [x] **Black screen** — macOS sends Annex B; `AVSampleBufferDisplayLayer` expects AVCC. Added `annexBToAVCC()` + `cachedFormatDesc` in StreamReceiver
- [x] **Continuous streaming stuck on first frame** — macOS/iOS host clocks are independent; stamped frames with `CMClockGetHostTimeClock()` + set `displayLayer.controlTimebase`
- [x] **Unpair not propagating** — added `.unpaired` protocol message type; ConnectionManager clears KeyStore + sets `appState.pairedMac = nil`; also clears on `.authFailed "Device not paired"` for offline-unpair scenario
- [x] **Pairing stuck at "Connecting to Mac"** — `loadUnaligned` fix + `BeamPacketHeader` stripping before JSON decode in PairingConnection
- [x] **QR code removed** — scrapped QR for MVP; code-entry only flow
- [x] **Post-pairing navigation** — `hasCompletedOnboarding` converted from computed UserDefaults to stored property with `didSet` so `@Observable` tracks it
- [x] **Ghost sessions** — `isTerminated` guard on `disconnect()`; `receiveNextPacket()` calls `disconnect()` on `isComplete=true` and on errors
- [x] **Pinch-to-zoom + pan** — `MagnificationGesture` (1×–5×) + `DragGesture` (only when zoomed, edge-clamped) + double-tap reset in StreamView
- [x] **Quality picker selected value not updating** — host `qualityChanged` payload decodes shape-identical to `qualityRequest`; iOS now maps both payload cases on `.qualityChanged` messages so selected quality updates instantly in client UI
- [x] **Stale/frozen stream sessions** — added inactivity timeout (`8s`) in `ConnectionManager` quality monitor; receiver state resets on connect/disconnect to avoid black-frame reconnect path
- [x] **Quality picker sheet closes unexpectedly** — moved picker sheet ownership from auto-hiding `StreamOverlay` to `StreamView`; overlay lifecycle no longer dismisses the picker after 3s
- [x] **Quality picker taps unreliable** — picker options now use full-row tap targets (`contentShape + onTapGesture`) to make selection behavior deterministic on iOS
- [x] **Frozen-last-frame edge case** — split inactivity tracking into control vs media; iOS now force-disconnects stalled streams when media packets stop (even if heartbeat/control packets still arrive)
- [x] **Reconnect cleanup hardening** — `ConnectionManager` disconnect is idempotent, send failures now force disconnect, and stream start always disconnects any previous manager first
- [x] **Foreground stale-stream recovery** — on scene re-activation, app performs a media-flow health check and drops stale frozen sessions automatically
- [x] **Audio playback restored end-to-end** — replaced fragile AAC/ADTS decode path with direct Float32 PCM playback (`AudioPlayer`), eliminating silent decode failures that caused no-audio streams
- [x] **A/V sync stabilization (video-master clock)** — audio scheduling now follows video PTS timeline with bounded lead + soft catch-up (no routine late-packet drops), reducing drift without periodic click/gap artifacts
- [x] **Dynamic audio format handshake** — host now broadcasts active audio sample rate/channels (`audio_format_changed`), and iOS rebuilds `AVAudioEngine` playback format on change to prevent pitch/tempo distortion from sample-rate mismatches

### Features
- [x] **StreamQualityPreset enum** — in Protocol.swift (both macOS + iOS); auto/360p30/480p30/720p30/720p60/1080p30/1080p60 with display names, dimensions, fps, bitrate
- [x] **Quality control messages** — `qualityRequest` (iOS→macOS), `qualityChanged` (macOS→iOS) added to Protocol.swift; unified `BeamQualityPayload` struct; `BeamQualityFeedbackPayload` updated to `quality: Double`
- [x] **BeamAppState quality state** — `currentQualityPreset` (updated from `.qualityChanged` messages), `preferredQualityPreset` (persisted to UserDefaults, sends `qualityRequest` to host on change)
- [x] **ConnectionManager quality integration** — sends quality preference to host on `authSuccess`; handles `.qualityChanged` messages from macOS (updates `currentQualityPreset`); sends `qualityFeedback` every 2s from quality monitor; `sendQualityFeedback(_:)` and `sendQualityRequest(_:)` methods added; `.control` packets try both pairing and control message decoding
- [x] **StreamOverlay rewrite** — Liquid Glass effect (iOS 26 `.glassEffect`, ultraThinMaterial fallback); quality picker button showing active preset; `QualityPickerSheet` with all presets + checkmark; `BeamGlassModifier` + `beamGlass()` View extension
- [x] **HomeView Mac app download link** — "Copy Mac app download link" button when no Mac paired; copies `https://beamscreen.app/#download` to clipboard with visual confirmation feedback
- [x] **Viewport lock control** — new liquid-glass lock/unlock button in `StreamOverlay`; animated lock symbol state; when locked, zoom/pan gestures are disabled and current zoom viewport is sent to host as normalized crop rectangle
- [x] **Viewport lock 16:9 constraint** — lock requests now always send a centered 16:9 normalized rect (including zoomed state) so PiP/locked output stays framed to a fixed widescreen viewport
- [x] **Viewport lock exact-selection flow** — lock now enters a dedicated selection state with visible 16:9 overlay and Cancel/Confirm actions; confirmed crop is derived from that exact on-screen frame (respecting current zoom/pan) before sending to host
- [x] **Viewport lock preserved in windowed/PiP continuation** — removed automatic host unlock on `StreamView` disappearance so lock state persists when stream transitions out of full-screen view (for example PiP/windowed continuation)
- [x] **Quality picker theme alignment** — removed blue accent behavior and forced orange-tinted controls/checkmarks for quality sheet actions
- [x] **Home branding refresh** — added `BrandFullIcon` assets from root `full-icon.png`; main screen logo now uses icon + lowercase `beam` wordmark styling
- [x] **Home logo parity with web header** — updated iOS home logo block to vertical icon-over-wordmark layout and matched web header wordmark style (`Plus Jakarta Sans`, heavy weight, 20pt, tight tracking, lowercase)
- [x] **Onboarding skip removed** — removed "Skip setup, do it later"; setup flow is now mandatory
- [x] **Quality modal header cleanup** — removed "Active: …" text and collapsed top list spacing so options start at the top of the modal
- [x] **PiP regression fix (button + swipe-home)** — stopped tearing down PiP on `StreamView` disappear, added scene-phase background auto-start attempt, and switched PiP button disabling to support-based gating (with live `isPictureInPicturePossible` observation in controller)
- [x] **PiP audio-session root-cause fix** — audio session is now promoted to `.playback, .moviePlayback, .mixWithOthers` in `AudioPlayer.setupAudioSession()` (at stream start), not at PiP tap time; this makes `isPictureInPicturePossible` true before the button is ever pressed so first-tap PiP works reliably; all mid-stream session-switching machinery removed from `PiPController` (no more `prepareAudioSessionForPiP` / `restoreAudioSessionAfterPiP` / `pendingPiPStart`); trade-off: hardware mute switch no longer silences inline stream audio (`.playback` ignores the ringer switch)
- [x] **Auto-PiP on home swipe** — removed manual `startAutomaticallyForBackgroundTransition()` call from `StreamView.onChange(of: scenePhase)` (it fired on `.inactive` which also triggers for app-switcher opens, causing race conditions with the system's own auto-PiP mechanism and bad UX); `canStartPictureInPictureAutomaticallyFromInline = true` + `.playback` session handles this cleanly — the system starts PiP at exactly the right moment before the view leaves the screen

---

## New Feature Queue (Priority Order)

### Core Product
- [x] **Rolling session timer** — 30-minute (1800s) accumulated active stream time per 24h window, Keychain-backed; resets every 24h; lockout when exhausted (`kSessionLimitSeconds` in `SessionManager.swift`)
- [x] **Paywall + IAP** — show paywall when session expires; one-time $3.79 unlock; purchase success screen; `HomeView` daily-limit section with countdown + "Unlock Beam Unlimited" CTA; subtle "Beam Unlimited" badge in bottomBar post-purchase; debug bypass removed from `StoreManager` so paywall is testable
- [x] **3-day free trial** — `SessionManager.recordFirstStream()` sets Keychain-backed `trialStartDate` on first authSuccess; `isInTrial` bypasses 30-min timer for 3 days; trial chip in `HomeView` bottomBar ("3 days free · Upgrade →"); one-time trial-expired modal when trial ends (→ "your trial ended, 30 min/day now"); `OnboardingView` last page footnote explains the model; `StreamOverlay` timer badge gains inline "Upgrade" button (timer | divider | Upgrade) during free-tier sessions

### UI / Polish
- [ ] **Icons + branding** — update app icon, stream landing, and start pages to match beamscreen.app branding

---

## Architecture Notes
- `BeamAppState` is the observable hub; all views consume it via `@Environment`
- `PairedMac.id` = the iOS device's Keychain-stable UUID (survives reinstall) - matches what macOS stores
- `VideoRenderer` is a `UIView` subclass wrapping `AVSampleBufferDisplayLayer` - PiP works from day 1
- Audio playback path: host sends Float32 interleaved PCM chunks; iOS deinterleaves into `AVAudioPCMBuffer` and schedules on `AVAudioPlayerNode`
- Sync model: video is master; `StreamReceiver` feeds video PTS to `AudioPlayer`, which maps remote PTS deltas onto local host time and schedules audio with bounded lead/drift correction
- Free tier: Keychain timestamps survive reinstall; `StoreManager.isPurchased` checked before starting timer
- Quality flow: iOS sends `qualityFeedback` every 2s → macOS `VideoQualityManager` adapts in auto mode; iOS sends `qualityRequest` on user picker change → macOS applies + broadcasts `qualityChanged` back

## Known Issues / Notes for Testing
- `ConnectionManager` uses TCP for all stream data. UDP upgrade possible in v2.
- Validate on real device that audio format renegotiation is stable across route changes (speaker ↔ AirPods, control center output switch) during an active stream
- PiP requires `audio` background mode in Info.plist AND AVAudioSession active
- StoreKit 2 product `com.beam.ios.unlimited` must exist in App Store Connect; use local `.storekit` config for dev testing
- iOS 26 Liquid Glass (`.glassEffect`) requires Xcode 16.4+ to compile; `#available(iOS 26, *)` guard ensures backward compatibility
- Viewport lock crop behavior should still be validated on real device + PiP path (especially landscape/portrait transitions), but lock rects are now forced to 16:9 on both iOS request generation and host `sourceRect` application
