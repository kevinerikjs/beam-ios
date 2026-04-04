// WhatsNewView.swift
// Shown once per app version after an update.

import SwiftUI

// MARK: - Changelog data

private struct ChangeEntry: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

private let changelog: [ChangeEntry] = [
    ChangeEntry(
        icon: "pip.fill",
        title: "Smoother PiP & Reconnects",
        detail: "Streaming in Picture-in-Picture is more stable. If the connection drops unexpectedly, Beam now reconnects automatically instead of stopping the stream."
    ),
    ChangeEntry(
        icon: "antenna.radiowaves.left.and.right",
        title: "Better Connection Handling",
        detail: "Improved tolerance for brief network hiccups — fewer interruptions during active streams."
    ),
    ChangeEntry(
        icon: "bubble.left.and.bubble.right",
        title: "Improved Feedback",
        detail: "You can now attach a diagnostic log when reporting issues, which helps us investigate and fix problems much faster."
    ),
]

// MARK: - View

struct WhatsNewView: View {

    let onDismiss: () -> Void

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

                Text("What's New")
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .foregroundColor(.white)

                Text("Version \(appVersion)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.4))
            }
            .padding(.bottom, 36)

            // Changelog entries
            if !changelog.isEmpty {
                VStack(spacing: 20) {
                    ForEach(changelog) { entry in
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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }
}

// MARK: - Version gate

enum WhatsNewManager {
    private static let key = "whatsNewLastSeenVersion"

    static var shouldShow: Bool {
        guard !changelog.isEmpty else { return false }
        let seen = UserDefaults.standard.string(forKey: key) ?? ""
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return seen != current
    }

    static func markSeen() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        UserDefaults.standard.set(current, forKey: key)
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
