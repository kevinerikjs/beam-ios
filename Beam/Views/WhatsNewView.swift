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
private let versionChangelog: [ChangeEntry] = [
    ChangeEntry(
        icon: "chevron.left.forwardslash.chevron.right",
        title: "Beam Is Open Source",
        detail: "Beam and Beacon are both public now, under the AGPL. Beam carries your Mac's screen and audio, so rather than asking you to trust that nothing else happens to them, you can read the code and check. The links are in Settings, under About."
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

            Spacer(minLength: 40)

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

// MARK: - Presentation gate

enum WhatsNewManager {
    private static let key = "whatsNewLastSeenVersion"

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
        guard !versionChangelog.isEmpty, canInterrupt else { return false }
        let seen = UserDefaults.standard.string(forKey: key) ?? ""
        return seen != appVersion
    }

    static var versionEntries: [ChangeEntry] { versionChangelog }

    static func markVersionSeen() {
        UserDefaults.standard.set(appVersion, forKey: key)
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
