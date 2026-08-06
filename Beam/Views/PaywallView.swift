// PaywallView.swift
// Upgrade to Beam Unlimited — shown proactively (upgrade chip, timer badge)
// or reactively (session expired). Pass triggeredByExpiry = true for the
// reactive case to get context-appropriate dismiss copy.

import SwiftUI

struct PaywallView: View {
    var triggeredByExpiry: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var promoConfig = PromoConfig.shared
    @State private var showSuccess = false
    @State private var now = Date()
    @State private var showingCountdown = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var paywallReason: String { triggeredByExpiry ? "session_expired" : "manual" }

    private var priceLabel: String {
        if let product = store.product {
            return "Purchase Beam Unlimited for \(product.displayPrice)"
        }
        return "Load Beam Unlimited Pricing"
    }

    // MARK: - Promo

    /// Everything needed to state a limited-time price truthfully, or nothing at all (BEAM-28).
    ///
    /// Each condition below is load-bearing, and any one of them failing takes the whole promo
    /// off screen rather than degrading it:
    ///
    ///   - a fresh server config with a future absolute deadline (see `PromoConfig`),
    ///   - both products live in StoreKit, so both prices are real and in the user's currency,
    ///   - the discounted one is genuinely the one on sale right now,
    ///   - and the "regular" price is genuinely higher than it.
    ///
    /// The last check is the one that makes a broken promo impossible rather than merely
    /// unlikely: if App Store Connect ever holds two products the same price, the app stops
    /// claiming a rise instead of counting down to nothing.
    private struct PromoOffer {
        let countdown: PromoConfig.Countdown
        let currentPrice: String
        let futurePrice: String
    }

    private var promoOffer: PromoOffer? {
        guard !store.isPurchased,
              let countdown = promoConfig.activeCountdown, !countdown.hasExpired,
              let promoProduct = store.promoProduct,
              let standardProduct = store.standardProduct,
              store.product?.id == promoProduct.id,
              standardProduct.price > promoProduct.price
        else { return nil }

        return PromoOffer(
            countdown: countdown,
            currentPrice: promoProduct.displayPrice,
            futurePrice: standardProduct.displayPrice
        )
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

                if let offer = promoOffer {
                    promoBanner(offer)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }

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

                    if let offer = promoOffer {
                        VStack(spacing: 3) {
                            // Generated from StoreKit, never from remote copy, so it is right
                            // in every storefront and cannot drift from what is charged.
                            Text("Then \(offer.futurePrice)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let note = offer.countdown.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                        }
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
            // Kick the config fetch and the store load together. The paywall renders from the
            // cached config immediately either way, so nothing here blocks the first frame.
            promoConfig.refresh()
            await store.refreshStoreState()
            if store.isPurchased {
                dismiss()
            }
        }
        .onReceive(ticker) { tick in
            let visible = promoOffer != nil
            // Only churn the view while a countdown is actually on screen.
            if visible { now = tick }
            if showingCountdown != visible {
                showingCountdown = visible
                // The deadline can pass with the paywall open. `activeCountdown` goes nil of its
                // own accord at that instant; this makes the button follow in the same tick, so
                // the price rise the countdown promised is one the user can watch happen.
                store.recomputeOfferedProduct()
            }
        }
        .onChange(of: promoConfig.revision) { _ in
            store.recomputeOfferedProduct()
        }
        .onChange(of: store.isPurchased) { purchased in
            if purchased {
                withAnimation(.spring(duration: 0.4)) { showSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { dismiss() }
            }
        }
    }

    // MARK: - Promo banner

    @ViewBuilder
    private func promoBanner(_ offer: PromoOffer) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock.fill")
                .font(.callout)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(offer.countdown.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                if let remaining = offer.countdown.formattedRemaining {
                    Text("Ends in \(remaining)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.85))
                        // Redrawn by the ticker below, off one fixed absolute deadline. There
                        // is no per-install clock here to reset.
                        .id(now)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(offer.futurePrice)
                    .font(.caption)
                    .strikethrough()
                    .foregroundStyle(.tertiary)
                Text(offer.currentPrice)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
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
