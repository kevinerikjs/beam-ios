// PaywallView.swift
// Shown when the 30-minute free session limit is hit, or when the user taps
// "Unlock Beam Unlimited" from the daily-limit state on HomeView.

import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = StoreManager.shared
    @State private var showSuccess = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Close button — plain style prevents the default blue tint
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Spacer()

                // Main content
                VStack(spacing: 36) {
                    // Icon + title
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 72, height: 72)

                            Image(systemName: "infinity.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.orange)
                        }

                        VStack(spacing: 6) {
                            Text("Your free session has ended")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)

                            Text("Get unlimited streaming with a one-time purchase.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }

                    // Feature list
                    VStack(spacing: 10) {
                        FeatureRow(icon: "infinity",   text: "Unlimited session length")
                        FeatureRow(icon: "iphone",     text: "Stream from any Mac, anytime")
                        FeatureRow(icon: "pip",        text: "Picture-in-Picture support")
                        FeatureRow(icon: "music.note", text: "Full media controls")
                    }
                    .padding(.horizontal, 32)

                    // Actions
                    VStack(spacing: 10) {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            Group {
                                if store.isPurchasing {
                                    ProgressView().tint(.black)
                                } else {
                                    Text("Purchase Beam Unlimited for $3.79")
                                        .fontWeight(.semibold)
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
                        .disabled(store.isPurchasing)

                        HStack(spacing: 20) {
                            Button("Try again tomorrow") {
                                dismiss()
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)

                            Text("·")
                                .foregroundStyle(.tertiary)

                            Button("Restore Purchase") {
                                Task { await store.restore() }
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                        }
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

                Text("One-time purchase · No subscription")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 20)
            }
            .opacity(showSuccess ? 0 : 1)

            // Purchase success overlay
            if showSuccess {
                purchaseSuccessView
                    .transition(.opacity)
            }
        }
        .task {
            await store.loadProduct()
        }
        .onChange(of: store.isPurchased) { _, purchased in
            if purchased {
                withAnimation(.spring(duration: 0.4)) {
                    showSuccess = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Success Screen

    @ViewBuilder
    private var purchaseSuccessView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 88, height: 88)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Beam Unlimited is now active.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
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
                .frame(width: 22)

            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))

            Spacer()
        }
    }
}
