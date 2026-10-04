# Security Policy

## Reporting a vulnerability

Email **[support@beamscreen.app](mailto:support@beamscreen.app)** with the subject `Security`.

Please do not open a public issue for a security problem. Beam receives a live stream of someone's
screen and audio, so a public report gives every user of the shipped build a problem before there
is a fix available, and App Store review means a fix is not same-day.

You should get a first response within 72 hours. If you do not hear back, send a follow-up, since
it more likely means the mail went astray than that it was ignored.

Useful things to include, as far as you have them: what you did, what happened, what you expected,
the Beam version, and your iOS version. A proof of concept helps but is not required to file.

## What is in scope

- **Pairing and authentication.** `Pairing/PairingManager.swift` and `Pairing/KeyStore.swift`.
  Anything that lets Beam connect to a host it was never paired with, or that leaks pairing
  material off the device.
- **The wire protocol and decoder.** `Streaming/Protocol.swift`, `Streaming/StreamReceiver.swift`,
  and `Streaming/VideoRenderer.swift`. Packet reassembly and decode run on data from the network,
  so malformed input handling and memory safety matter most here.
- **Keychain handling.** How pairing credentials and session state are stored and scoped.
- **Anything that sends stream content somewhere it shouldn't go.** Beam should only ever talk to a
  paired Mac, on the local network or over your own Tailscale network. A path that sends screen or
  audio content anywhere else is the most serious kind of bug this app can have.

## How the connection is encrypted

Since Beam 3.6 and Beacon 1.9, the connection to Beacon is encrypted with keys derived from the pairing
secret and a fresh X25519 exchange, then sealed with AES-256-GCM. The UDP media transport's DTLS
fingerprint travels inside that connection, so its DTLS-SRTP is tied to the pairing too. The design and
its limits are in [Phoros SECURITY.md](https://github.com/kevinerikjs/phoros/blob/main/SECURITY.md).
Two limits you don't need to report: Beam still talks plaintext to a Beacon older than 1.9, and pairing
itself has no secret to start from, so someone actively intercepting the connection during the pairing
minute could still read the secret. Anything beyond that is very welcome.

## Out of scope

- **Free tier bypasses.** Session timing lives in the Keychain and a determined person on their own
  device can defeat it. That is a business problem, not a security one, and it does not put anyone
  else at risk. Please do not spend your time here.
- Findings from automated scanners with no demonstrated exploit path
- Denial of service requiring the attacker to already be paired
- Attacks that require a jailbroken device or a device the attacker already controls
- Missing hardening that has no exploit behind it, reported as a finding on its own

## Disclosure

Report privately, give us a reasonable window to ship a fix, then publish whatever you like. Bear
in mind that shipping a fix means App Store review, so the window is realistically longer than for
a web service. If it is taking too long, say so and we will agree a date rather than let it drift.
Release notes will credit you unless you would rather stay anonymous.

There is no bug bounty. This is a one-person project with no budget for one.

## Scope of this policy

This policy covers Beam for iOS (this repository) and
[Beacon for macOS](https://github.com/kevinerikjs/beacon-macos). Report issues in either to the same
address.
