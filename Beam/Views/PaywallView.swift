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
        GeometryReader { geo in
            // A paywall that scrolls hides its own call to action, so everything has to fit.
            // Below roughly an iPhone SE the full-size layout cannot, and the parts that give
            // way first are decoration: the icon shrinks, the tagline goes, the feature rows
            // tighten to one line each. Nothing that carries meaning is dropped.
            let compact = geo.size.height < 720
            content(compact: compact)
        }
    }

    @ViewBuilder
    private func content(compact: Bool) -> some View {
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
                VStack(spacing: compact ? 8 : 14) {
                    Image("BrandFullIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: compact ? 40 : 56, height: compact ? 40 : 56)
                        .shadow(color: Color(red: 245/255, green: 158/255, blue: 11/255).opacity(0.35), radius: 16)

                    VStack(spacing: 6) {
                        Text("Unlock Beam Unlimited")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        if !compact {
                            Text("Stream freely, without limits.\nOne purchase. Yours forever.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                        }
                    }
                }
                .padding(.horizontal, 32)

                Spacer()

                // Features
                VStack(spacing: 0) {
                    UnlimitedFeatureRow(
                        compact: compact,
                        icon: "infinity",
                        title: "No session limits",
                        subtitle: "Stream as long as you need, with no timers and no cutoffs"
                    )
                    featureDivider
                    UnlimitedFeatureRow(
                        compact: compact,
                        icon: "pip.fill",
                        title: "Picture-in-Picture",
                        subtitle: "Keep your stream visible while using other apps"
                    )
                    featureDivider
                    UnlimitedFeatureRow(
                        compact: compact,
                        icon: "playpause.fill",
                        title: "Full media controls",
                        subtitle: "Play, pause, and skip directly from your iPhone"
                    )
                    featureDivider
                    UnlimitedFeatureRow(
                        compact: compact,
                        icon: "globe",
                        title: "Stream from anywhere",
                        subtitle: "Reach your Mac when you're away from home, over your own Tailscale network"
                    )
                    featureDivider
                    UnlimitedFeatureRow(
                        compact: compact,
                        icon: "lock.open.fill",
                        title: "One-time unlock",
                        subtitle: "Pay once, keep forever."
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                // CTA + actions
                VStack(spacing: 12) {
                    EmberPurchaseButton(
                        headline: ctaHeadline,
                        strikePrice: promoOffer?.futurePrice,
                        detail: ctaDetail,
                        isBusy: store.isPurchasing,
                        isEmber: promoOffer != nil
                    ) {
                        Task {
                            if store.product == nil {
                                await store.loadProduct()
                            } else {
                                await store.purchase()
                            }
                        }
                    }
                    .disabled(store.isPurchasing)
                    // Redrawn by the ticker, off one fixed absolute deadline. There is no
                    // per-install clock here to reset.
                    .id(now)

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
                .padding(.top, compact ? 10 : 20)
                .padding(.bottom, compact ? 14 : 28)
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

    // MARK: - CTA copy

    /// Everything the offer needs to say lives on the button, so there is one thing to read
    /// and one thing to tap. Both strings come from StoreKit and the countdown, never from
    /// remote copy, so they cannot drift from what is actually charged.
    private var ctaHeadline: String {
        guard let offer = promoOffer else { return priceLabel }
        return "Unlock now for \(offer.currentPrice)"
    }

    /// Answers, in one line: what this is, when it ends, how long is left, and what it costs
    /// afterwards. The date is absolute so it survives the app being closed; the remaining
    /// time is relative so it reads as urgent.
    private var ctaDetail: String? {
        guard let offer = promoOffer else { return nil }
        let ends = offer.countdown.deadline.formatted(.dateTime.day().month(.abbreviated))
        var parts = ["\(offer.countdown.headline) ends \(ends)"]
        if let remaining = offer.countdown.formattedRemaining {
            parts.append("\(remaining) left")
        }
        parts.append("then \(offer.futurePrice) for good")
        return parts.joined(separator: "  ·  ")
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
    let compact: Bool
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
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
                    .lineLimit(compact ? 1 : nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 8 : 14)
    }
}

// MARK: - Ember purchase button

/// The single call to action. It carries the whole offer, so the paywall does not need a
/// separate banner above it and a line of small print below it competing for the same glance.
///
/// The ember treatment is on a timer rather than a Metal shader because the deployment target
/// is iOS 16 and `.colorEffect` is iOS 17+. A drifting radial highlight over the brand gradient
/// gets the same "still warm" read at a fraction of the complexity, and it degrades to a flat
/// gradient under Reduce Motion, where a permanently animating buy button would be hostile.
private struct EmberPurchaseButton: View {
    let headline: String
    let strikePrice: String?
    let detail: String?
    let isBusy: Bool
    let isEmber: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let amber = Color(red: 245/255, green: 158/255, blue: 11/255)
    private let orange = Color(red: 249/255, green: 115/255, blue: 22/255)
    private let deep = Color(red: 234/255, green: 88/255, blue: 12/255)

    var body: some View {
        Button(action: action) {
            VStack(spacing: detail == nil ? 0 : 3) {
                if isBusy {
                    ProgressView().tint(.black)
                } else {
                    HStack(spacing: 8) {
                        Text(headline)
                            .font(.headline.weight(.semibold))
                        if let strikePrice {
                            Text(strikePrice)
                                .font(.subheadline)
                                .strikethrough()
                                .opacity(0.55)
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption.weight(.medium))
                            .opacity(0.72)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, detail == nil ? 17 : 13)
            .background(background)
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: orange.opacity(isEmber ? 0.35 : 0), radius: 18, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(headline). \($0)" } ?? headline)
    }

    private var base: LinearGradient {
        LinearGradient(colors: [amber, orange], startPoint: .leading, endPoint: .trailing)
    }

    @ViewBuilder
    private var background: some View {
        if isEmber && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Two coprime periods so the highlight never lands in the same place twice
                // in a row, which is what stops it reading as a mechanical sweep.
                let x = 0.5 + 0.42 * sin(t / 3.1)
                let y = 0.5 + 0.18 * sin(t / 2.3)
                ZStack {
                    base
                    RadialGradient(
                        colors: [Color.white.opacity(0.32), .clear],
                        center: UnitPoint(x: x, y: y),
                        startRadius: 2,
                        endRadius: 150
                    )
                    RadialGradient(
                        colors: [deep.opacity(0.55), .clear],
                        center: UnitPoint(x: 1 - x, y: 1 - y),
                        startRadius: 2,
                        endRadius: 190
                    )
                    .blendMode(.multiply)
                }
                .drawingGroup()
            }
        } else {
            base
        }
    }
}
