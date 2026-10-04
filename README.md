# Beam

**Your Mac's screen and sound on your iPhone or iPad, with enough control to get things done.**

Beam is the iPhone and iPad half of a pair. It connects to [Beacon](https://github.com/kevinerikjs/beacon-macos),
a small menu bar app on your Mac, and plays your Mac's screen with its audio. At home that happens over
your own Wi-Fi. Away from home it can reach your Mac over your own Tailscale network. There is no Beam
account and no Beam server in between.

### [Get Beam on the App Store](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962)

You also need **[Beacon](https://github.com/kevinerikjs/beacon-macos/releases/latest/download/Beacon.dmg)**,
the free Mac app, on the Mac you want to watch.

## What it's for

Apple has no way to put a Mac screen on an iPhone. AirPlay can't send to a phone, Sidecar only works with
an iPad, and iPhone Mirroring goes the other way (your phone on your Mac). Beam fills that gap.

People use it to keep an eye on a render or a download from the couch, finish a film in bed, follow a
livestream from the kitchen, answer a dialog on a Mac in another room, or play Mac games with a controller.

## What it does

- **Whole screen or one window.** Stream the full display, or pick a single Mac window from the phone.
  It stays locked to that window even when other windows cover it on the Mac.
- **Sound included.** Mac system audio plays on the phone. Turn it off and the Mac stops sending it.
- **Picture in Picture.** Keep watching while you use other apps. A tall window gets a tall PiP.
- **Zoom and crop.** Pinch to zoom, or lock the view to one part of the screen. Hold to detect can find
  the edges of a playing video for you.
- **Quality you choose.** Auto, or a fixed preset from 360p up to 1080p. With Beam 3.5 and Beacon 1.8, also
  1440p, 4K and your Mac display's native resolution, at 30 or 60 fps. Beam only lists sizes your Mac's
  display can produce. On a 120 Hz iPhone or iPad, the 60 fps presets run at up to 120 fps when the Mac's
  display refreshes that fast too.
- **Stream modes.** Game favours response time, Video favours picture detail, Auto switches to Game when a
  controller is attached or click mode is on.
- **Click, drag, scroll.** In click mode, tap to click, tap twice to double-click, touch and hold then lift
  to right-click, touch and hold then move to drag, and slide two fingers to scroll.
- **Type on the Mac.** The live keyboard sends each key as you type, with a row of Mac keys on top: esc,
  tab, the arrows, ⌃ ⌥ ⇧ ⌘, and a swipe away from home, end, page up and down, forward delete and F1 to F12.
- **Your own buttons.** Build a bar of up to eight buttons in Beacon: keys, shortcuts, media keys, recorded
  macros, a text box, the keyboard and click.
- **Game controllers.** Pair a controller with the phone and the Mac sees a real gamepad, both sticks and
  analog triggers included.
- **Away from home.** With Beam Unlimited, Beam reaches your Mac over your Tailscale network when it isn't
  on the same Wi-Fi.

What Beam doesn't do: it isn't an extra display (you can't drag windows onto the phone), and it doesn't
move files or sync the clipboard between the phone and the Mac.

Guides with more detail:
[can you AirPlay a Mac to an iPhone?](https://beamscreen.app/guide/airplay-mac-to-iphone) ·
[iPhone as a Mac monitor](https://beamscreen.app/guide/iphone-as-mac-monitor) ·
[streaming from anywhere](https://beamscreen.app/guide/remote-streaming-tailscale) ·
[Mac games with a controller](https://beamscreen.app/guide/controller-passthrough)

> **Why the source is public.** Beam receives a live picture of your Mac. With the code in the open, you can
> check what it does with that instead of taking anyone's word for it. To use Beam, get the App Store build:
> it's signed, it updates itself, and building it yourself needs a paid Apple Developer account.

---

## How it works

| | |
| --- | --- |
| **Discovery** | Bonjour, browsing for `_beam._tcp` on the local network |
| **Control connection** | Network.framework TCP, encrypted with keys from the pairing secret (Phoros: X25519 and AES-256-GCM): pairing, sign-in, settings, phone controls |
| **Media** | A UDP peer transport (ICE, DTLS, SRTP) from [Phoros](https://github.com/kevinerikjs/phoros), with loss repair and forward error correction. Falls back to the TCP connection on its own if the UDP path fails, or when Legacy Transport is on |
| **Video** | HEVC or H.264, rendered with `AVSampleBufferDisplayLayer`, which also drives PiP |
| **Audio** | `AVAudioEngine`, with a buffer that sizes itself to the network |
| **Controller** | GameController framework, sent the moment the controller changes, at most 60 times a second (`PhorosInput`) |
| **Pairing** | You pick your Mac, Beacon shows a 6-digit code, you type it in. The resulting secret lives in the iOS Keychain |
| **Purchases** | StoreKit 2 |

Beam talks to Beacon directly. Beam runs no relay and no server in the stream path.

**Encryption.** Everything Beam and Beacon send each other is encrypted end to end, using the secret your
two devices agree on when you pair: the picture, the sound, and every click and key press. Since Beam 3.6
and Beacon 1.9. See [SECURITY.md](./SECURITY.md).

## Dependencies and what gets collected

Beam has three dependencies, all MIT licensed and all compatible with the AGPL:

| Package | Why |
| --- | --- |
| [Phoros](https://github.com/kevinerikjs/phoros) | The protocol and plumbing Beam shares with Beacon: framing, handshake, sessions, the TCP connection, the UDP media transport, decoders and controller sampling. Pinned to an exact version, because two apps that ship on different days must not drift apart on a shared protocol. |
| [posthog-ios](https://github.com/PostHog/posthog-ios) | Anonymous product analytics |
| [PLCrashReporter](https://github.com/microsoft/plcrashreporter) | Pulled in by PostHog for crash reports |

Beyond Phoros, the streaming path is Apple frameworks: Network.framework, VideoToolbox, AudioToolbox and
AVFoundation.

All analytics code is in one short file, [`Beam/Analytics.swift`](./Beam/Analytics.swift). In short:

- Events are tied to a random anonymous ID. No account, no email, no name.
- Screen view capture is off (`captureScreenViews = false`). App lifecycle events (opened, backgrounded,
  installed, updated) are on.
- The events are product counters such as `stream_started`, `stream_ended`, `pip_activated`,
  `paywall_shown` and the purchase steps, with properties like session length, quality preset and
  whether Beam Unlimited is unlocked.
- Nothing about what you stream is collected: no picture, no audio, no window titles, no file names.
- Simulator and Debug builds send nothing.
- Events go to `w.beamscreen.app`, a proxy on Beam's own domain, which forwards them to PostHog.

The in-app feedback form is separate. It sends your message, and your email and a diagnostic log only if
you add them, to `beamscreen.app/api/feedback`.

## Requirements

- iPhone or iPad with iOS 16 or later
- A Mac running [Beacon](https://github.com/kevinerikjs/beacon-macos), on the same Wi-Fi, or on your
  Tailscale network for remote streaming
- Xcode 15 or later, if you're building it yourself

## Free tier and Beam Unlimited

Your first stream starts a three-day trial with no limits. After that, you can stream for up to 30 minutes
in total in each 24-hour window, added up across streams. A one-time in-app purchase
(`com.beam.ios.unlimited`) removes that limit for good and unlocks streaming from away from home. It's a
purchase, not a subscription. The price is on the
[App Store listing](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962).

Session timing is kept in the Keychain so it survives a reinstall. The code is in
`Store/SessionManager.swift` if you want to read it.

## Building from source

```bash
git clone https://github.com/kevinerikjs/beam-ios.git
cd beam-ios
open Beam.xcodeproj
```

Pick the `Beam` scheme and a device or simulator, then Run.

> The simulator is fine for most work. It shares your Mac's network, so Bonjour discovery, streaming from
> Beacon and audio all work. Test on a real phone before shipping anything, though: PiP, background audio,
> heat and real Wi-Fi are where the two differ.

Running your own build on your own phone needs a paid Apple Developer account. With a free account the
app stops working after seven days and has to be signed again.

### The feedback secret

`Info.plist` declares `BeamFeedbackSecret` as `$(BEAM_FEEDBACK_SECRET)`, which is empty unless you supply
it. That's expected and your build works without it. The feedback endpoint accepts unsigned reports and
only uses this value to mark a report as coming from an official build.

Official builds supply it in one of two ways:

```bash
# local archive
xcodebuild archive -scheme Beam ... BEAM_FEEDBACK_SECRET=<value>
```

On Xcode Cloud it comes from a secret workflow environment variable with the same name, which
`ci_scripts/ci_post_clone.sh` writes into `Info.plist` before the build. Xcode Cloud passes workflow
variables to that script but not to `xcodebuild`'s build settings, which is why the script exists.

## Project layout

```
Beam/
├── BeamApp.swift
├── BeamAppState.swift
├── Analytics.swift
├── Views/
│   ├── HomeView.swift            # Connection screen and Start Beam button
│   ├── StreamView.swift          # Full-screen stream
│   ├── StreamOverlay.swift       # Control bar, quality, window picker, in-stream settings
│   ├── ClickModeSurface.swift    # Click, drag, scroll and zoom gestures
│   ├── ClickModeGuide.swift      # The gesture help sheet
│   ├── KeyboardAccessory.swift   # Mac key row above the keyboard
│   ├── SettingsView.swift
│   ├── PairingView.swift         # Find your Mac, enter the 6-digit code
│   ├── PaywallView.swift
│   ├── WhatsNewView.swift
│   ├── FeedbackView.swift
│   └── OnboardingView.swift
├── Streaming/
│   ├── VideoRenderer.swift       # AVSampleBufferDisplayLayer wrapper
│   ├── AudioPlayer.swift         # AVAudioEngine playback
│   ├── StreamReceiver.swift      # Reassembly and video/audio dispatch
│   ├── VideoMotionDetector.swift # Finds the playing video for the viewport lock
│   ├── PiPController.swift
│   ├── AdvancedSettings.swift
│   ├── DiagnosticLogger.swift
│   └── Protocol.swift            # Beam's policy on top of the Phoros wire contract
├── Network/
│   ├── BonjourBrowser.swift      # Finds _beam._tcp
│   ├── ConnectionManager.swift   # Connection lifecycle, sign-in, transport choice
│   ├── ConnectionRacer.swift     # Local and Tailscale addresses tried side by side
│   ├── ControlChannel.swift
│   └── RemoteSetupProbe.swift    # The "Set Up Automatically" check for remote access
├── Pairing/
│   ├── PairingManager.swift
│   └── KeyStore.swift            # Keychain-stored pairing secret
└── Store/
    ├── StoreManager.swift        # StoreKit 2
    ├── SessionManager.swift      # Trial and free-tier timer
    └── ReviewManager.swift
BeamWidget/                       # Lock Screen widget that starts a stream
```

Beam is built on [Phoros](https://github.com/kevinerikjs/phoros): the wire contract it shares with Beacon,
plus frame reassembly, audio sequencing, the framed TCP connection, the UDP media transport, the pairing
client and the decoders. This repo holds Beam itself: the screens, the audio player, the renderer, PiP,
the Keychain, and the policy on top of the package (`Streaming/Protocol.swift`).

## Contributing

Issues and pull requests are welcome. A few ground rules:

- Anything in the streaming path uses Apple frameworks, through Phoros. No third-party networking, video
  or audio libraries. The dependencies above are the complete list, and the bar for another one is high.
  A wire change starts in Phoros, with a pinned fixture test, and lands here as a version bump.
- Use Swift concurrency (`async`/`await`, actors) for asynchronous work.
- Test on a real phone with a real Beacon. A PR that only compiles hasn't been tested.
- Make user-facing strings localizable (`String(localized:)`) from the start.
- Open an issue to talk through larger changes first.

Contributions need a short **[Contributor License Agreement](./CLA.md)**: one line in your PR description.
[The CLA](./CLA.md) explains why. In short, it's what makes the dual licensing below possible.

## Project documents

| Document | What it covers |
| --- | --- |
| [SECURITY.md](./SECURITY.md) | How to report a vulnerability privately, and what's in scope |
| [LICENSE](./LICENSE) | The AGPL-3.0 text |
| [COMMERCIAL-LICENSE.md](./COMMERCIAL-LICENSE.md) | Using Beam without the AGPL obligations |
| [CLA.md](./CLA.md) | The one line contributors add to a PR, and why |
| [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) | How people are expected to treat each other here |
| [CLAUDE.md](./CLAUDE.md) | Architecture rules and coding conventions |

**Found a security problem? Please don't open an issue.** Read [SECURITY.md](./SECURITY.md) and email
[support@beamscreen.app](mailto:support@beamscreen.app).

## License

Beam is **dual licensed**.

**By default it's [AGPL-3.0](./LICENSE).** You can use, study, change and share it, commercially too. In
return, if you distribute Beam or something built from it, you publish your source under the AGPL as well.

**A commercial license is available** if you want to build on Beam without that obligation, for example
inside a closed-source product. Terms are open to discussion. Email
**[support@beamscreen.app](mailto:support@beamscreen.app)** with the subject `Commercial license` and a
paragraph about what you're building. [COMMERCIAL-LICENSE.md](./COMMERCIAL-LICENSE.md) has the details.

The **Beam** and **Beacon** names, logos and icons aren't part of the AGPL grant. Fork the code freely, but
please ship it under your own name.

Copyright © Kevin Erik Iin.

---

## Maintainer notes

`main` is production. Any push to it starts an Xcode Cloud build, so feature work happens on branches
and arrives by pull request.

The Xcode Cloud workflow has one `ARCHIVE` action and no post-actions. A build produces an archive in App
Store Connect and stops. It never submits anything for review; that's a separate, deliberate step in App
Store Connect. Keep in mind that the trigger is any change to `main`, not only a merge.
