# Beam iOS - Work State

## Current Status: v1.2 — Submitted to App Store review

**App Store URL:** https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962
**Latest version:** 1.1 — published and approved

---

## Completed

### v1.0 — Core App (App Store submission + fixes)
- [x] **Core streaming** — TCP receive, H.264 AVCC decode, `AVSampleBufferDisplayLayer`, Float32 PCM audio
- [x] **A/V sync** — video-master clock; audio scheduled against video PTS with bounded lead/drift
- [x] **PiP** — `AVPictureInPictureController`; auto-PiP on home swipe; audio session `.playback` mode for reliable `isPictureInPicturePossible`
- [x] **Quality picker** — `StreamQualityPreset` enum; `QualityPickerSheet`; liquid glass overlay; host applies + broadcasts `qualityChanged`
- [x] **Viewport lock** — 16:9 selection overlay; confirmed crop sent to host as normalized rect; persists across reconnect/PiP
- [x] **Auto video detection** — `VideoMotionDetector`; heatmap+blur+blob+percentile-trim; hex reveal overlay with user painting; haptics
- [x] **Seek backward/forward** — circular arrow buttons in HUD; maps to left/right arrow keys on Mac
- [x] **Pairing** — 6-digit code entry; `.unpaired` propagation; offline-unpair via `.authFailed`
- [x] **Free tier / IAP** — 30-min/24h session limit (Keychain-backed); 3-day free trial; one-time $4.79 unlock (`com.beam.ios.unlimited`); paywall UI; `StoreManager` + `SessionManager`
- [x] **Onboarding** — mandatory setup flow; "Skip for now" on last page lands on HomeView
- [x] **Ghost session / reconnect fixes** — `isTerminated` guard; inactivity timeout; foreground stale-stream recovery
- [x] **Dynamic audio format handshake** — rebuilds `AVAudioEngine` on `audio_format_changed`
- [x] **App Store review fixes** (rejection → approval):
  - SettingsView added to Xcode target
  - HomeView unpaired state: value prop, expandable setup guide, Mac download link
  - Settings gear always visible; IAP accessible without pairing
  - Onboarding skip button

### v1.2 — iOS 16 Support + Feedback + Analytics
- [x] **iOS 16 deployment target** — lowered from 17.0 to 16.0; full ObservableObject migration
- [x] **In-app feedback** — FeedbackView sheet in Settings → Support; posts to beamscreen.app/api/feedback → Telegram
- [x] **Analytics events** — `trial_expired` (once, on first post-trial open) and `daily_limit_reached` (each time 30m limit hit)
- [x] **What's New changelog** updated for v1.2

### v1.1 — Analytics + What's New + Polish
- [x] **PostHog analytics** — funnel event tracking; EU region; reverse proxy host; `analytics.ts`; `first_pair_completed` event
- [x] **What's New screen** — shown on first launch after update; skipped when changelog is empty
- [x] **Review nudge** — prompts for App Store review at appropriate moment
- [x] **Pairing UX** — show device list instead of auto-connecting to first found device
- [x] **App icons + branding** — app icon updated; stream landing and start pages match beamscreen.app branding
- [x] **IAP price** — updated to $4.79 (was $3.79)
- [x] **Session badge polish** — timer text no longer wraps; stream overlay upgrade button uses `crown.fill` icon
- [x] **Trademark fix** — app name/subtitle updated in App Store Connect (no Apple brand nouns per guideline 5.2.5)

---

## Next Up

- [x] **iOS 16 port shipped as v1.2** — committed and submitted to App Store review
- [ ] **iOS improvements** — post-1.1 features and bug fixes (TBD based on user feedback + analytics)

---

### iOS 16 Port — Change Summary (v1.2)
- Deployment target: `17.0` → `16.0` in project.pbxproj
- All `@Observable` → `ObservableObject` + `@Published` (7 classes: BeamAppState, PairingManager, PiPController, ConnectionManager, StoreManager, SessionManager, VideoMotionDetector)
- All `@Environment(Type.self)` → `@EnvironmentObject` (6 views); `@State`/`@StateObject` creation site updated; singleton observation via `@ObservedObject`
- All `.onChange(of:)` two-param `{ _, new in }` → single-param `{ new in }` (10 instances)
- `@State` for ObservableObject class instances in views → `@StateObject` (PiPController, VideoMotionDetector in StreamView; PairingManager in PairingView; StoreManager in PaywallView)
- `let detector` in AutoDetectOverlay sub-struct → `@ObservedObject var detector`
- `.contentTransition(.symbolEffect(.replace))` removed (iOS 17+ only, lock icon still swaps correctly)
- `.contentMargins(.top, 0, for: .scrollContent)` removed (iOS 17+ only, minor layout difference in quality picker)
- `.sensoryFeedback` → UIKit `UIImpactFeedbackGenerator`/`UINotificationFeedbackGenerator` in `.onChange` (works iOS 16+, same haptic effect)

---

## Architecture Notes
- `BeamAppState` is the observable hub; all views consume it via `@Environment`
- `PairedMac.id` = iOS device's Keychain-stable UUID (survives reinstall) — matches what macOS stores
- `VideoRenderer` is a `UIView` subclass wrapping `AVSampleBufferDisplayLayer` — PiP works from day 1
- Audio path: host sends Float32 interleaved PCM; iOS deinterleaves into `AVAudioPCMBuffer` and schedules on `AVAudioPlayerNode`
- Sync model: video is master; `StreamReceiver` feeds video PTS to `AudioPlayer`, which maps remote PTS deltas onto local host time
- Free tier: Keychain timestamps survive reinstall; `StoreManager.isPurchased` checked before starting timer
- Quality flow: iOS sends `qualityFeedback` every 2s → macOS `VideoQualityManager` adapts in auto mode
- iOS 26 Liquid Glass (`.glassEffect`) requires Xcode 16.4+; `#available(iOS 26, *)` guard ensures backward compat

## Known Issues / Notes for Testing
- Validate audio format renegotiation stability across route changes (speaker ↔ AirPods) during active stream
- StoreKit 2 product `com.beam.ios.unlimited` must exist in App Store Connect; use local `.storekit` config for dev testing
- Viewport lock crop behavior should be validated on real device + PiP path (landscape/portrait transitions)
