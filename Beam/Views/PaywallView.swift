// PaywallView.swift
// Upgrade to Beam Unlimited — shown proactively (upgrade chip, timer badge)
// or reactively (session expired). Pass triggeredByExpiry = true for the
// reactive case to get context-appropriate dismiss copy.

import SwiftUI

struct PaywallView: View {
    var triggeredByExpiry: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoreManager.shared
    @State private var showSuccess = false

    private var paywallReason: String { triggeredByExpiry ? "session_expired" : "manual" }

    private var priceLabel: String {
        if let product = store.product {
            return "Purchase Beam Unlimited for \(product.displayPrice)"
        }
        return "Load Beam Unlimited Pricing"
    }

    var body: some View {
        ZStack {
            Color(red: 0.039, green: 0.039, blue: 0.043).ignoresSafeArea()

            VStack(spacing: 0) {
                // Dismiss
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer()

                // Icon + headline
                VStack(spacing: 14) {
                    Image("BrandFullIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .shadow(color: Color(red: 245/255, green: 158/255, blue: 11/255).opacity(0.35), radius: 16)

                    VStack(spacing: 6) {
                        Text("Unlock Beam Unlimited")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Stream freely, without limits.\nOne purchase. Yours forever.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                }
                .padding(.horizontal, 32)

                Spacer()

                // Features
                VStack(spacing: 0) {
                    UnlimitedFeatureRow(
                        icon: "infinity",
                        title: "No session limits",
                        subtitle: "Stream as long as you need, with no timers and no cutoffs"
                    )
                    featureDivider
                    UnlimitedFeatureRow(
                        icon: "pip.fill",
                        title: "Picture-in-Picture",
                        subtitle: "Keep your stream visible while using other apps"
                    )
                    featureDivider
                    UnlimitedFeatureRow(
                        icon: "playpause.fill",
                        title: "Full media controls",
                        subtitle: "Play, pause, and skip directly from your iPhone"
                    )
                    featureDivider
                    UnlimitedFeatureRow(
                        icon: "globe",
                        title: "Stream from anywhere",
                        subtitle: "Reach your Mac when you're away from home, over your own Tailscale network"
                    )
                    featureDivider
                    UnlimitedFeatureRow(
                        icon: "lock.open.fill",
                        title: "One-time unlock",
                        subtitle: "Pay once, keep forever."
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                // CTA + actions
                VStack(spacing: 12) {
                    Button {
                        Task {
                            if store.product == nil {
                                await store.loadProduct()
                            } else {
                                await store.purchase()
                            }
                        }
                    } label: {
                        Group {
                            if store.isPurchasing {
                                ProgressView().tint(.black)
                            } else {
                                Text(priceLabel)
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 245/255, green: 158/255, blue: 11/255),
                                    Color(red: 249/255, green: 115/255, blue: 22/255)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(store.isPurchasing)

                    if store.product == nil {
                        Text("Fetching live App Store pricing…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 20) {
                        Button(triggeredByExpiry ? "Try again tomorrow" : "Maybe later") {
                            dismiss()
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)

                        Text("·").foregroundStyle(.tertiary)

                        Button("Restore Purchase") {
                            Task { await store.restore() }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }

                    if let error = store.purchaseError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 28)

                // Legal footer
                VStack(spacing: 6) {
                    Text("One-time purchase · Not a subscription · No recurring charges")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 16) {
                        Link("Privacy Policy", destination: URL(string: "https://beamscreen.app/privacy")!)
                        Text("·").foregroundStyle(.quaternary)
                        Link("Terms of Use", destination: URL(string: "https://beamscreen.app/terms")!)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .opacity(showSuccess ? 0 : 1)

            // Success overlay
            if showSuccess {
                purchaseSuccessView
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { Analytics.paywallShown(reason: paywallReason) }
        .task {
            await store.refreshStoreState()
            if store.isPurchased {
                dismiss()
            }
        }
        .onChange(of: store.isPurchased) { purchased in
            if purchased {
                withAnimation(.spring(duration: 0.4)) { showSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { dismiss() }
            }
        }
    }

    private var featureDivider: some View {
        Divider()
            .background(Color.white.opacity(0.06))
            .padding(.leading, 56)
    }

    @ViewBuilder
    private var purchaseSuccessView: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
            }
            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Beam Unlimited is now active.\nStream without limits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            Spacer()
        }
    }
}

// MARK: - Feature Row

private struct UnlimitedFeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }
}
