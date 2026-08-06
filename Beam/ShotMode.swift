// ShotMode.swift
// Screenshot-capture hook for the ios-shots harness (INFRA-189, BEAM-24).
//
// Completely inert unless the app is launched with `-beamShotScreen <name>`, which only
// `ios-shots/configs/beam.json` does. It exists so App Store and ad creatives can show the
// REAL app UI rather than hand-built HTML recreations of it: the harness boots a clean
// simulator, launches the app once per screen with that argument, and captures the result.
//
// Two things are needed to make a real screen photograph well without a Mac on the other end:
//
//   1. Seeded state. Most of Beam's interesting screens are empty until a Mac is paired and
//      discovered on the network, which a simulator has no way to do. `seed()` fills in a
//      plausible pairing so HomeView renders its populated "ready to stream" form.
//   2. A poster frame. The streaming view draws decoded video, and there is no video without
//      a host. The harness writes a still into the app's Documents container before launch
//      and StreamView shows that in place of the renderer. The still is a genuine Mac screen
//      capture, so what appears on the phone is what Beam actually puts there.
//
// Nothing here runs in a normal launch: `screen` is nil, `isActive` is false, and every call
// site is behind that check.

import SwiftUI
import UIKit
import Network

enum ShotMode {

    /// The screen the harness asked for, or nil in every normal launch.
    /// `-beamShotScreen home` is parsed into UserDefaults by the standard argument-domain rules.
    static let screen: String? = {
        guard let raw = UserDefaults.standard.string(forKey: "beamShotScreen"),
              !raw.isEmpty else { return nil }
        return raw
    }()

    static var isActive: Bool { screen != nil }

    /// Filename the harness writes into the app's Documents container before launch.
    static let posterFilename = "shot-poster.png"

    /// Still frame shown in place of decoded video while capturing the streaming screen.
    static let poster: UIImage? = {
        guard isActive else { return nil }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(posterFilename).path)
    }()

    // MARK: - State seeding

    /// Fills in the state a screen needs to render populated. Idempotent, main-actor only.
    @MainActor
    static func seed(_ appState: BeamAppState) {
        guard let screen else { return }

        // Never let a changelog sheet land on top of a capture.
        WhatsNewManager.markVersionSeen()

        // Onboarding is the one screen that wants the pre-onboarding state.
        appState.hasCompletedOnboarding = (screen != "onboarding")

        guard screen != "onboarding" else { return }

        appState.pairedMac = PairedMac(
            id: "5B6E1F0C-9A44-4D2E-8C31-2F7A1B0D4E55",
            name: hostName,
            sharedSecret: Data(repeating: 0, count: 32),
            lastConnected: Date()
        )
        appState.discoveredHost = DiscoveredHost(
            name: hostName,
            endpoint: .hostPort(host: "192.168.1.24", port: 7891),
            port: 7891
        )
        appState.discoveredHosts = [appState.discoveredHost!]
        appState.isSearchingForMac = false
        appState.connectionQuality = 1.0
        appState.isStreaming = screen.hasPrefix("stream")

        // Teleprompter mode is a real setting, so it persists across launches in the same
        // simulator. Clear it first or every screen captured after the teleprompter one comes
        // out mirrored.
        UserDefaults.standard.set(false, forKey: "beam.flipHorizontal")
        UserDefaults.standard.set(false, forKey: "beam.flipVertical")

        switch screen {
        case "stream-teleprompter":
            // Seeded rather than mocked, so the capture shows the actual feature.
            UserDefaults.standard.set(true, forKey: "beam.flipHorizontal")

        case "stream-remote":
            // The remote link badge only appears on a Tailscale session. `linkRTT` under 0.25s
            // is what the app itself calls a direct connection, so this captures the green
            // "Direct" state a healthy remote stream actually shows.
            appState.usingRemoteHost = true
            appState.linkRTT = 0.05

        default:
            break
        }
    }

    /// Name shown as the paired Mac. Deliberately generic: a store screenshot should not
    /// carry a real person's device name.
    static let hostName = "MacBook Pro"

    // MARK: - Routing

    /// The view the harness wants captured. Every case is the app's own screen, unmodified.
    @ViewBuilder
    static func rootView() -> some View {
        switch screen {
        case "onboarding": OnboardingView()
        case "pairing":    PairingView()
        case "settings":   SettingsView()
        case "paywall":    PaywallView()
        case "features":
            WhatsNewView(
                entries: WhatsNewManager.versionEntries,
                subtitle: "Version \(WhatsNewManager.appVersion)"
            ) {}
        case "stream", "stream-teleprompter", "stream-remote": StreamView()
        default:           HomeView()
        }
    }
}
