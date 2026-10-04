// WhatsNewView.swift
// Two independent "what's new" surfaces, both one-shot:
//
//   1. Version changelog — every entry is tagged with the release it shipped in, and the
//      phone remembers which releases the person has already seen and dismissed. After an
//      update it shows only the unseen ones, newest first, so someone updating daily sees one
//      short list per update and someone who skipped a few sees just what they missed.
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
    /// The app version this shipped in ("3.4"). Empty for feature-unlock notes.
    var release: String = ""
}

/// One release's entries. `release` nil means "no heading" (a single-release list).
struct ChangeSection: Identifiable {
    let release: String?
    let entries: [ChangeEntry]
    var id: String { release ?? "all" }
}

/// Every release's notes, newest first, each tagged with its release. Only entries whose
/// release the person hasn't dismissed yet are shown after an update; Settings shows them
/// all. Must NOT mention any feature that is still behind a flag.
private let versionChangelog: [ChangeEntry] = [
    ChangeEntry(
        icon: "lock.fill",
        title: "Encrypted Connection",
        detail: "Everything between Beam and your Mac is now encrypted and locked to your pairing: the picture, the sound, and every click and key you type. Nobody else on your Wi-Fi can read it. Needs the latest Beacon, which updates itself.",
        release: "3.6"
    ),
    ChangeEntry(
        icon: "viewfinder",
        title: "More Resolution Choices",
        detail: "Choose 1440p, 4K, or up to your Mac display's native resolution, at 30 or 60 fps. Beam only shows sizes your Mac display supports. Advanced settings can also force connections through your stored Tailscale address.",
        release: "3.5"
    ),
    ChangeEntry(
        icon: "command",
        title: "Mac Keys Above Your Keyboard",
        detail: "Live keyboard now has a row of Mac keys on top: esc, tab, the arrows and ⌃ ⌥ ⇧ ⌘. Swipe it for home, end, page up and down, forward delete and F1 to F12. Tap a modifier for one key, or hold it to lock it for as many shortcuts as you like. Needs the latest Beacon, which updates itself.",
        release: "3.4"
    ),
    ChangeEntry(
        icon: "cursorarrow.motionlines",
        title: "Double-Click, Right-Click, Drag and Scroll",
        detail: "In click mode, tap twice to double-click. Touch and hold, then move to drag windows or select text, or lift to right-click. Slide two fingers to scroll. The cursor button in the bar shows every gesture. Needs the latest Beacon.",
        release: "3.4"
    ),
    ChangeEntry(
        icon: "keyboard",
        title: "Type and Click Together",
        detail: "Keyboard and click mode can be on at the same time. When the keyboard opens, the picture slides up so the keyboard doesn't cover it.",
        release: "3.4"
    ),
    ChangeEntry(
        icon: "wrench.and.screwdriver",
        title: "Fixes",
        detail: "Zooming out no longer leaves the picture hanging off the edge. Turning the phone keeps the keyboard open. In landscape, the key row stays clear of the notch.",
        release: "3.4"
    ),
    ChangeEntry(
        icon: "antenna.radiowaves.left.and.right",
        title: "New Streaming Engine",
        detail: "Video, audio and controller input now travel over a transport built for games: lost packets are repaired in milliseconds instead of stalling the stream, so a busy Wi-Fi network no longer means hitches. If it ever struggles, Beam falls back to the old path on its own. Needs Beacon 1.6, which updates itself.",
        release: "3.3"
    ),
    ChangeEntry(
        icon: "gamecontroller.fill",
        title: "Stream Modes",
        detail: "Game mode trades a little picture detail for the tightest input response. Video mode gives the picture everything. Auto picks Game whenever a controller is attached or click mode is on. Change it in Settings or from the in-stream sheet, it applies live.",
        release: "3.3"
    ),
    ChangeEntry(
        icon: "waveform",
        title: "Audio That Stays Put",
        detail: "Sound no longer crackles or drops out when the radio hiccups. Beam now sizes its audio buffer to what your network actually does.",
        release: "3.3"
    ),
    ChangeEntry(
        icon: "bolt.fill",
        title: "Much Lower Latency",
        detail: "A press reaches the screen in about a third of the time it took before. The Mac sends video at the pace your Wi-Fi can carry, and frames go straight to the display. Needs Beacon 1.5.1, which updates itself.",
        release: "3.2"
    ),
    ChangeEntry(
        icon: "gauge.with.dots.needle.67percent",
        title: "120 fps and Advanced Settings",
        detail: "Beam streams at your screen's refresh rate, up to 120 fps, for smoother motion and lower latency. The Advanced section has frame pacing, a bitrate cap, codec choice, a Legacy Transport switch and a latency meter.",
        release: "3.2"
    ),
    ChangeEntry(
        icon: "gamecontroller.fill",
        title: "Play Mac Games With a Controller",
        detail: "Pair a controller with your iPhone or iPad and your Mac sees a real gamepad: both sticks, analog triggers, every button. Needs Beacon 1.5.0 on the Mac, which updates itself.",
        release: "3.1"
    ),
    ChangeEntry(
        icon: "ipad.landscape",
        title: "Beam on iPad",
        detail: "Beam now runs on iPad. Same pairing, same stream, more screen.",
        release: "3.0"
    ),
    ChangeEntry(
        icon: "cursorarrow.click",
        title: "Click the Mac From Your Phone",
        detail: "Turn on click mode and tap the stream. The Mac clicks the same point, with zoom, viewport lock and window mode taken into account. Left click and right click are separate buttons in the default bar.",
        release: "3.0"
    ),
    ChangeEntry(
        icon: "keyboard",
        title: "Type on the Mac Live",
        detail: "The Keyboard button opens your phone keyboard. Each key goes to the app that has focus on the Mac as you type. In the Computer Use layout, the ⌘ ⌃ ⌥ ⇧ buttons hold a modifier for the next key, so you can type shortcuts.",
        release: "3.0"
    ),
    ChangeEntry(
        icon: "slider.horizontal.3",
        title: "Your Buttons, Your Layout",
        detail: "Open Beacon Settings, then Controls, and build your own bar: up to eight buttons, each with its own icon and action. Actions are keys, shortcuts, media keys, recorded macros, a text box, live keyboard and click. Two built-in layouts are included.",
        release: "3.0"
    ),
    ChangeEntry(
        icon: "macwindow",
        title: "Pick the Window From Here",
        detail: "Lock the stream to one Mac window from the phone, or go back to the full display. Beacon can also start on a window you choose each time you connect.",
        release: "3.0"
    ),
    ChangeEntry(
        icon: "speaker.slash.fill",
        title: "Stream Without Audio",
        detail: "Turn audio off in Settings, or with the speaker button while streaming. With the latest Beacon, the Mac sends no audio at all, so the picture gets all the bandwidth.",
        release: "3.0"
    ),
    ChangeEntry(
        icon: "rectangle.dashed",
        title: "Fixes",
        detail: "The viewport lock streams exactly the region you chose. Hold-to-detect finds the video edges precisely. The lock hint no longer hides under the notch. The on-screen controls fit every iPhone.",
        release: "3.0"
    ),
    ChangeEntry(
        icon: "shippingbox",
        title: "Built on Phoros",
        detail: "Beam now runs on Phoros, the open protocol and plumbing it shares with Beacon. Nothing changes on the wire, so every Beacon keeps working.",
        release: "3.0"
    ),
]

/// The release whose notes announce a formerly gated feature. Someone who has seen those
/// notes doesn't also get the unlock notice.
private let unlockCoveredByRelease: [FeatureFlags.Feature: String] = [
    .controllerPassthrough: "3.1",
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

    let sections: [ChangeSection]
    let title: String
    let subtitle: String
    let onDismiss: () -> Void

    /// Release notes, one section per release. Each release gets a small heading when more
    /// than one is shown.
    init(
        sections: [ChangeSection],
        title: String = "What's New",
        subtitle: String,
        onDismiss: @escaping () -> Void
    ) {
        self.sections = sections
        self.title = title
        self.subtitle = subtitle
        self.onDismiss = onDismiss
    }

    /// A single list with no headings, as a feature-unlock notice uses.
    init(
        entries: [ChangeEntry],
        title: String = "What's New",
        subtitle: String,
        onDismiss: @escaping () -> Void
    ) {
        self.init(sections: [ChangeSection(release: nil, entries: entries)],
                  title: title, subtitle: subtitle, onDismiss: onDismiss)
    }

    private var showsReleaseHeadings: Bool { sections.count > 1 }

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
            if sections.contains(where: { !$0.entries.isEmpty }) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sections) { section in
                    if showsReleaseHeadings, let release = section.release {
                        Text("Version \(release)")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundColor(Color.white.opacity(0.4))
                            .padding(.top, section.id == sections.first?.id ? 0 : 8)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(section.entries) { entry in
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
    /// Releases whose notes the person has dismissed ("3.3", "3.4", ...).
    private static let seenReleasesKey = "whatsNewSeenReleases"
    /// Before per-release tracking: the last version shown, as "3.3 (15)". Read once to
    /// migrate, so an existing user doesn't get the whole history again.
    private static let legacyKey = "whatsNewLastSeenVersion"

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
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
        migrateIfNeeded()
        guard canInterrupt else { return false }
        return !unseenEntries.isEmpty
    }

    /// What the person hasn't seen yet, one section per release, newest first.
    static var unseenSections: [ChangeSection] { sections(unseenEntries) }

    /// The whole history, for reopening from Settings.
    static var allSections: [ChangeSection] { sections(shippedEntries) }

    /// "Version 3.4" for one release, a softer line when several are being caught up on.
    static func subtitle(for sections: [ChangeSection]) -> String {
        sections.count > 1 ? "Since your last update" : "Version \(sections.first?.release ?? appVersion)"
    }

    static func markVersionSeen() {
        migrateIfNeeded()
        var seen = seenReleases
        seen.formUnion(shippedEntries.map(\.release))
        UserDefaults.standard.set(Array(seen).sorted(), forKey: seenReleasesKey)
    }

    /// Entries for this version and older. Notes written ahead of a version bump stay hidden
    /// until the build that carries them.
    private static var shippedEntries: [ChangeEntry] {
        versionChangelog.filter { compare($0.release, appVersion) <= 0 }
    }

    private static var unseenEntries: [ChangeEntry] {
        let seen = seenReleases
        return shippedEntries.filter { !seen.contains($0.release) }
    }

    private static var seenReleases: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenReleasesKey) ?? [])
    }

    private static func sections(_ entries: [ChangeEntry]) -> [ChangeSection] {
        var order: [String] = []
        var byRelease: [String: [ChangeEntry]] = [:]
        for entry in entries {
            if byRelease[entry.release] == nil { order.append(entry.release) }
            byRelease[entry.release, default: []].append(entry)
        }
        order.sort { compare($0, $1) > 0 }
        return order.map { ChangeSection(release: $0, entries: byRelease[$0] ?? []) }
    }

    /// First run of per-release tracking. Someone who last saw "3.3 (15)" has seen every
    /// release up to 3.3. Someone with no record at all is a new install (or never finished
    /// onboarding): nothing already shipped is news to them.
    private static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.stringArray(forKey: seenReleasesKey) == nil else { return }
        let lastSeen = defaults.string(forKey: legacyKey)?
            .components(separatedBy: " ").first
        let cutoff = lastSeen ?? appVersion
        let seen = versionChangelog.map(\.release).filter { compare($0, cutoff) <= 0 }
        defaults.set(Array(Set(seen)).sorted(), forKey: seenReleasesKey)
    }

    /// Numeric version comparison: "3.10" is after "3.9".
    private static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
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
        // Once a feature is in the release notes the person has seen, "just unlocked" is old
        // news (and baffling on a fresh install): retire the notice quietly.
        if let release = unlockCoveredByRelease[feature], seenReleases.contains(release) {
            markUnlockSeen(feature)
            return nil
        }
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
