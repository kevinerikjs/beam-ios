// PaywallView.swift
// Shown when the 10-minute free session ends. Offers one-time IAP unlock.

import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = StoreManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Close button
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Spacer()

                // Content
                VStack(spacing: 32) {
                    // Icon + title
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.orange.opacity(0.3), .yellow.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 80, height: 80)

                            Image(systemName: "infinity.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.orange)
                        }

                        VStack(spacing: 8) {
                            Text("Your free session has ended")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)

                            Text("Unlock unlimited streaming with a one-time purchase.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }

                    // Feature list
                    VStack(alignment: .leading, spacing: 12) {
                        FeatureRow(icon: "infinity", text: "Unlimited session length")
                        FeatureRow(icon: "iphone", text: "Stream from any Mac, anytime")
                        FeatureRow(icon: "pip", text: "Picture-in-Picture support")
                        FeatureRow(icon: "music.note", text: "Full media controls")
                    }
                    .padding(.horizontal, 40)

                    // Purchase button
                    VStack(spacing: 12) {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            VStack(spacing: 4) {
                                if store.isPurchasing {
                                    ProgressView().tint(.black)
                                } else {
                                    Text("Beam Unlimited")
                                        .fontWeight(.bold)
                                    if let price = store.product?.displayPrice {
                                        Text("\(price) — one-time")
                                            .font(.callout)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(
                                    colors: [.orange, Color(red: 1, green: 0.6, blue: 0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(store.isPurchasing || store.product == nil)

                        Button("Try again tomorrow") {
                            dismiss()
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        Button("Restore Purchase") {
                            Task { await store.restore() }
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 28)

                    if let error = store.purchaseError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                Spacer()
            }
        }
        .task {
            await store.loadProduct()
        }
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.orange)
                .frame(width: 24)

            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))

            Spacer()
        }
    }
}
