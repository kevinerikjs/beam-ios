// WhatsNewView.swift
// Two independent "what's new" surfaces, both one-shot:
//
//   1. Version changelog — shown once per app version after an update. Lists what shipped
//      in that release.
//   2. Feature-unlock changelog — shown once, ever, the first time a remotely-gated feature
//      latches on (BEAM-18). Lists ONLY that feature.
//
// They are deliberately separate. Controller passthrough ships dark and is switched on
// server-side weeks after the build that contains it, so it must not appear in that build's
// release notes — and when it does light up, the user should see the controller news alone,
// not a re-run of release notes they already read.

import SwiftUI

// MARK: - Changelog data

struct ChangeEntry: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

/// Ships with the release. Must NOT mention any feature that is still behind a flag.
/// Controller passthrough is no longer behind one: the flag went global with Beacon 1.5.0, and
/// 3.1 also arms on the host's own capability. 3.2's latency work heads the list. The 3.0
/// entries stay because most people update straight from 2.x.
private let versionChangelog: [ChangeEntry] = [
    ChangeEntry(
        icon: "bolt.fill",
        title: "Much Lower Latency",
        detail: "A press reaches the screen in about a third of the time it took before. The Mac sends video at the pace your Wi-Fi can carry, and frames go straight to the display. Needs Beacon 1.5.1, which updates itself."
    ),
    ChangeEntry(
        icon: "gauge.with.dots.needle.67percent",
        title: "High Frame Rate and Advanced Settings",
        detail: "High Frame Rate streams at your screen's refresh rate, up to 120 fps, for smoother motion and lower latency. The new Advanced section has frame pacing, a bitrate cap, codec choice and a latency meter."
    ),
    ChangeEntry(
        icon: "gamecontroller.fill",
        title: "Play Mac Games With a Controller",
        detail: "Pair a controller with your iPhone or iPad and your Mac sees a real gamepad: both sticks, analog triggers, every button. Needs Beacon 1.5.0 on the Mac, which updates itself."
    ),
    ChangeEntry(
        icon: "ipad.landscape",
        title: "Beam on iPad",
        detail: "Beam now runs on iPad. Same pairing, same stream, more screen."
    ),
    ChangeEntry(
        icon: "cursorarrow.click",
        title: "Click the Mac From Your Phone",
        detail: "Turn on click mode and tap the stream. The Mac clicks the same point, with zoom, viewport lock and window mode taken into account. Left click and right click are separate buttons in the default bar."
    ),
    ChangeEntry(
        icon: "keyboard",
        title: "Type on the Mac Live",
        detail: "The Keyboard button opens your phone keyboard. Each key goes to the app that has focus on the Mac as you type. In the Computer Use layout, the ⌘ ⌃ ⌥ ⇧ buttons hold a modifier for the next key, so you can type shortcuts."
    ),
    ChangeEntry(
        icon: "slider.horizontal.3",
        title: "Your Buttons, Your Layout",
        detail: "Open Beacon Settings, then Controls, and build your own bar: up to eight buttons, each with its own icon and action. Actions are keys, shortcuts, media keys, recorded macros, a text box, live keyboard and click. Two built-in layouts are included."
    ),
    ChangeEntry(
        icon: "macwindow",
        title: "Pick the Window From Here",
        detail: "Lock the stream to one Mac window from the phone, or go back to the full display. Beacon can also start on a window you choose each time you connect."
    ),
    ChangeEntry(
        icon: "speaker.slash.fill",
        title: "Stream Without Audio",
        detail: "Turn audio off in Settings, or with the speaker button while streaming. With the latest Beacon, the Mac sends no audio at all, so the picture gets all the bandwidth."
    ),
    ChangeEntry(
        icon: "rectangle.dashed",
        title: "Fixes",
        detail: "The viewport lock streams exactly the region you chose. Hold-to-detect finds the video edges precisely. The lock hint no longer hides under the notch. The on-screen controls fit every iPhone."
    ),
    ChangeEntry(
        icon: "shippingbox",
        title: "Built on Phoros",
        detail: "Beam now runs on Phoros, the open protocol and plumbing it shares with Beacon. Nothing changes on the wire, so every Beacon keeps working."
    ),
]

/// Shown on its own when a gated feature unlocks. One entry per feature, nothing else.
private let unlockChangelog: [FeatureFlags.Feature: ChangeEntry] = [
    .controllerPassthrough: ChangeEntry(
        icon: "gamecontroller.fill",
        title: "Game Controller Support",
        detail: "Pair a game controller to your iPhone and it now works on your Mac through Beam. Buttons, both sticks and the analog triggers all pass through, so Mac games see it as a real controller."
    ),
]

// MARK: - View

struct WhatsNewView: View {

    let entries: [ChangeEntry]
    let title: String
    let subtitle: String
    let onDismiss: () -> Void

    init(
        entries: [ChangeEntry],
        title: String = "What's New",
        subtitle: String,
        onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.title = title
        self.subtitle = subtitle
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header and entries scroll together only when they outgrow the screen; the
            // Continue button stays put underneath. `.automatic` disables the bounce when
            // everything fits, so short changelogs look exactly as before.
            ScrollView {
            VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#f59e0b"), Color(hex: "#f97316")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(.top, 48)

                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.4))
            }
            .padding(.bottom, 36)

            // Changelog entries
            if !entries.isEmpty {
                VStack(spacing: 20) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(hex: "#f59e0b").opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Image(systemName: entry.icon)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Color(hex: "#f59e0b"), Color(hex: "#f97316")],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(entry.detail)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(Color.white.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
            }
            .padding(.bottom, 24)
            }
            .modifier(BounceOnlyWhenNeeded())

            Spacer(minLength: 16)

            // CTA
            Button(action: onDismiss) {
                Text("Continue")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "#f59e0b"), Color(hex: "#f97316")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "#0a0a0b").ignoresSafeArea())
    }

}

/// `scrollBounceBehavior` is iOS 16.4+; the app floor is 16.0, where a short list simply
/// bounces a little.
private struct BounceOnlyWhenNeeded: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}

// MARK: - Presentation gate

enum WhatsNewManager {
    private static let key = "whatsNewLastSeenVersion"

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }

    /// The seen marker includes the build number, so a new build of the same version shows
    /// the changelog again. Builds only change per submission, so users see it once per
    /// release; developers see it on every install.
    private static var seenMarker: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(appVersion) (\(build))"
    }

    /// Shared preconditions for interrupting the user with a sheet at launch.
    private static var canInterrupt: Bool {
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return false }
        // Don't interrupt a widget-triggered cold launch — beam.pendingAutoStart is
        // still present here because BeamAppState.init() hasn't run yet.
        guard !UserDefaults.standard.bool(forKey: "beam.pendingAutoStart") else { return false }
        return true
    }

    // MARK: Version changelog

    static var shouldShowVersion: Bool {
        guard !versionChangelog.isEmpty, canInterrupt else { return false }
        let seen = UserDefaults.standard.string(forKey: key) ?? ""
        return seen != seenMarker
    }

    static var versionEntries: [ChangeEntry] { versionChangelog }

    static func markVersionSeen() {
        UserDefaults.standard.set(seenMarker, forKey: key)
    }

    // MARK: Feature-unlock changelog

    /// The unlock changelog owed to the user right now, if any.
    /// Returns nil when nothing has unlocked, when the notice was already shown, or when
    /// the version changelog is still pending — that one goes first so the two never stack.
    @MainActor
    static func pendingUnlock() -> (feature: FeatureFlags.Feature, entry: ChangeEntry)? {
        guard canInterrupt, !shouldShowVersion else { return nil }
        guard let feature = FeatureFlags.shared.pendingUnlockNotice,
              let entry = unlockChangelog[feature] else { return nil }
        return (feature, entry)
    }

    @MainActor
    static func markUnlockSeen(_ feature: FeatureFlags.Feature) {
        FeatureFlags.shared.markUnlockNoticeShown(feature)
    }
}

// MARK: - Color hex helper (local)

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
