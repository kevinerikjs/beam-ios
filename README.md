# Beam

**See and lightly control your Mac from your iPhone.**

Beam connects to a Mac running [Beacon](https://github.com/kevinerikjs/beacon-macos) and plays its
screen and audio, over your local network or your own Tailscale network. It supports
Picture-in-Picture, tap-to-click, live keyboard input with sticky modifiers, media controls, custom
buttons, viewport locking, and quality selection. No cables, no Beam account, and no Beam relay.

### [Get Beam on the App Store](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962)

You will also need **[Beacon](https://github.com/kevinerikjs/beacon-macos/releases/latest/download/Beacon.dmg)**,
the free macOS companion app, on the Mac you want to stream from.

## Why this exists: Apple doesn't do this direction

Getting a Mac screen onto an iPhone is the one mirroring direction Apple has never supported, and
the features people find while looking all run the other way:

- **AirPlay** — iPhones send AirPlay, they never receive it. A Mac can AirPlay to an Apple TV, a
  compatible TV, or another Mac, but not to a phone.
- **Sidecar** — iPad only, always has been.
- **iPhone Mirroring** — shows your *iPhone* on your *Mac*. The opposite of this.

So: no cables, no cloud, no account, and on your own WiFi nothing leaves your network.

Beam is viewer-first with light control: tap to click, type with the iPhone keyboard, or use up to
eight custom controls configured in Beacon. It is not a full remote desktop: there is no pointer,
dragging, file transfer, or clipboard sync.

More detail: [can you AirPlay Mac to iPhone?](https://beamscreen.app/guide/airplay-mac-to-iphone) ·
[using an iPhone as a Mac monitor](https://beamscreen.app/guide/iphone-as-mac-monitor) ·
[streaming from away from home](https://beamscreen.app/guide/remote-streaming-tailscale)

> **Why the source is here.** Beam is on the other end of a link that carries your Mac's screen and
> audio. Publishing the code means you do not have to take our word for what it does with that.
> For actually using it, the App Store build is the one you want: it is signed, it updates itself,
> and building it yourself requires a paid Apple Developer account.

---

## How it works

| | |
| --- | --- |
| **Discovery** | Bonjour, browsing for `_beam._tcp` on the local network |
| **Transport** | Network.framework over TCP on your LAN or Tailscale network |
| **Video** | `AVSampleBufferDisplayLayer` for low-latency rendering, which also drives PiP |
| **Audio** | `AVAudioEngine`, Float32 PCM, A/V sync via host clock comparison |
| **Pairing** | Device keys held in the iOS Keychain |
| **Purchases** | StoreKit 2 |

There is no server between your phone and your Mac. Beam talks to Beacon directly.

## Dependencies and what gets collected

Beam has two dependencies, both MIT licensed and both compatible with the AGPL:

| Package | Why |
| --- | --- |
| [posthog-ios](https://github.com/PostHog/posthog-ios) | Anonymous product analytics |
| [PLCrashReporter](https://github.com/microsoft/plcrashreporter) | Pulled in transitively by PostHog for crash reports |

Everything in the streaming path is Apple frameworks. There are no third-party networking, video,
or audio libraries.

The entire analytics surface is one small file, [`Beam/Analytics.swift`](./Beam/Analytics.swift),
readable in a minute. What it does:

- It is **anonymous**. No accounts, no email, no device identifiers, no PII.
- **Screen view capture is off** (`captureScreenViews = false`).
- Events are product counters like `stream_started` and `stream_ended`, with properties such as
  session duration, quality preset, and whether the unlock was purchased.
- **Nothing about what you are streaming is collected.** No screen contents, no audio, no
  filenames, no window titles. Those never leave your local network at all.
- Data goes to `w.beamscreen.app`, a self-hosted endpoint, not to PostHog's cloud.

## Requirements

- iOS 16.0 or later (the optional home screen widget needs a newer iOS)
- A Mac running [Beacon](https://github.com/kevinerikjs/beacon-macos) on the same network, or with
  Tailscale configured for remote access
- Xcode 15 or later, if you are building rather than installing

## Free tier and unlocking

Beam includes a three-day trial with no limits. After the trial, free use is up to 30 minutes total
in each 24-hour window; time adds up across streams. A one-time in-app purchase
(`com.beam.ios.unlimited`) removes the allowance and window restriction permanently. It is a
purchase rather than a subscription, so you pay once and that is the end of it. Current pricing is
on the [App Store listing](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962).

Session timing is stored in the Keychain so that it survives a reinstall. That code is in
`Store/SessionManager.swift` and, like everything else here, you can read exactly what it does.

## Building from source

```bash
git clone https://github.com/kevinerikjs/beam-ios.git
cd beam-ios
open Beam.xcodeproj
```

Select the `Beam` scheme and a **real device** as the destination, then Run.

> The simulator works for most development: it shares the host's network stack, so Bonjour
> discovery, streaming from a Beacon host, and audio playback all function. Test on a physical
> device before shipping anyway, since PiP behaviour, background audio, thermals, and real network
> conditions are where simulator and device diverge.

Note that running your own build on your own phone needs a paid Apple Developer account. With a
free provisioning profile the app expires and has to be re-signed every seven days.

### The feedback secret

`Info.plist` declares `BeamFeedbackSecret` as `$(BEAM_FEEDBACK_SECRET)`, which is empty unless you
supply it. That is expected, and your build works fine without it: the feedback endpoint accepts
unsigned reports and only uses this value to mark one as coming from an official build.

Official builds supply it two ways:

```bash
# local archive
xcodebuild archive -scheme Beam ... BEAM_FEEDBACK_SECRET=<value>
```

On Xcode Cloud it comes from a secret workflow environment variable of the same name, which
`ci_scripts/ci_post_clone.sh` writes into `Info.plist` before the build. Xcode Cloud exposes
workflow variables to that script but not to `xcodebuild`'s build settings, which is why the
script exists rather than the substitution just working.

## Project layout

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
│   ├── VideoRenderer.swift       # AVSampleBufferDisplayLayer wrapper
│   ├── AudioPlayer.swift         # AVAudioEngine playback
│   ├── StreamReceiver.swift      # Packet reassembly + video/audio dispatch
│   ├── VideoMotionDetector.swift # Auto video region detection
│   ├── PiPController.swift       # Picture-in-Picture management
│   └── Protocol.swift            # Beam policy on top of the Phoros wire contract
├── Network/
│   ├── BonjourBrowser.swift    # Discover _beam._tcp
│   └── ConnectionManager.swift # TCP connection lifecycle + auth
├── Pairing/
│   ├── PairingManager.swift
│   └── KeyStore.swift          # Keychain-stored pairing credentials
└── Store/
    ├── StoreManager.swift      # StoreKit 2 IAP
    └── SessionManager.swift    # Free tier timer
```

Beam is built on [Phoros](https://github.com/kevinerikjs/phoros): the wire contract it shares
with Beacon, plus frame reassembly, audio sequencing, the framed TCP connection, the pairing
client, and the format-description and AAC decoding. What lives in this repo is Beam itself:
the views, the audio player, the renderer, PiP, the Keychain, and the policy on top of the
package (`Streaming/Protocol.swift`).

## Contributing

Issues and pull requests are welcome. Before you start:

- Apple frameworks for anything in the streaming path. No third-party networking, video, or audio
  libraries. The dependencies below are the complete list and the bar for adding another is high.
- Swift concurrency (`async`/`await`, actors) for asynchronous work.
- Test on a real device with a real Beacon host. A PR that only compiles has not been tested.
- User-facing strings should be localizable (`String(localized:)`) from the start.
- Discuss larger changes in an issue first.

Contributions require agreeing to a short **[Contributor License Agreement](./CLA.md)**, which is
one line in your PR description. [That document](./CLA.md) explains why, and the short version is
that it is what keeps the dual licensing below possible.

## Project documents

| Document | What it covers |
| --- | --- |
| [SECURITY.md](./SECURITY.md) | How to report a vulnerability privately, and which parts of Beam are worth looking at |
| [LICENSE](./LICENSE) | The AGPL-3.0 text |
| [COMMERCIAL-LICENSE.md](./COMMERCIAL-LICENSE.md) | Using Beam without the AGPL obligations, and how to arrange that |
| [CLA.md](./CLA.md) | The one line contributors add to a PR, and why it is needed |
| [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) | How people are expected to behave here |
| [CLAUDE.md](./CLAUDE.md) | Architecture rules and coding conventions |

**Found a security problem? Do not open an issue.** Read [SECURITY.md](./SECURITY.md) and mail
[support@beamscreen.app](mailto:support@beamscreen.app) instead.

## License

Beam is **dual licensed**.

**By default it is [AGPL-3.0](./LICENSE).** You can use it, study it, modify it, and redistribute
it, including commercially. What the AGPL asks in return is that if you distribute Beam or
something derived from it, you publish your source under the AGPL too.

**A commercial license is available** if you want to build on Beam without those source disclosure
obligations, for instance inside a closed source product. Terms are negotiable.

If that is you, mail **[support@beamscreen.app](mailto:support@beamscreen.app)** with the subject
`Commercial license` and a paragraph on what you are building. See
**[COMMERCIAL-LICENSE.md](./COMMERCIAL-LICENSE.md)** for the full picture.

The **Beam** and **Beacon** names, logos, and icons are not covered by the AGPL grant. Fork the
code freely, but please ship it under your own name.

Copyright © Kevin Erik Iin.

---

## Maintainer notes

| Branch | Purpose |
| --- | --- |
| `main` | Production. Any push triggers an Xcode Cloud build. |
| `develop` | Active development. Feature work and fixes go here. |

The Xcode Cloud workflow has a single `ARCHIVE` action and no post-actions, so a build produces an
archive in App Store Connect and stops there. It does **not** submit anything for review, which
still takes a deliberate step in App Store Connect. Worth knowing before you push to `main`, since
the trigger is any ref change on that branch rather than a merge specifically.
