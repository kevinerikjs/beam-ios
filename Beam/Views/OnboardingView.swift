// OnboardingView.swift
// First-launch welcome flow. Explains what Beam does, then kicks off pairing.

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: BeamAppState
    @State private var currentPage = 0
    @State private var showPairing = false

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "film.fill",
            title: "Never lose your place",
            body: "Watching something on your Mac? Beam streams your screen directly to your \(UIDevice.deviceNoun), instantly.",
            color: .orange
        ),
        OnboardingPage(
            icon: "wifi",
            title: "Local, private, fast",
            body: "Beam uses your home network. No cloud, no accounts, no latency. Just your screen on your phone.",
            color: .blue
        ),
        OnboardingPage(
            icon: "pip.fill",
            title: "Keep it in view",
            body: "Picture-in-Picture keeps your stream visible while you use other apps. Play/pause right from your phone.",
            color: .purple
        )
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Page content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        pageView(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 360)

                // Page indicator
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.orange : Color.white.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.spring(duration: 0.3), value: currentPage)
                    }
                }
                .padding(.top, 24)

                Spacer()

                // CTA
                VStack(spacing: 12) {
                    Button {
                        if currentPage < pages.count - 1 {
                            withAnimation { currentPage += 1 }
                        } else {
                            showPairing = true
                        }
                    } label: {
                        Text(currentPage < pages.count - 1 ? "Next" : "Set up Beam")
                            .fontWeight(.semibold)
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

                    if currentPage == pages.count - 1 {
                        Text("3 days free with no limits, then 30 min/day or upgrade anytime")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)

                        Button("Skip for now") {
                            appState.hasCompletedOnboarding = true
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingView()
                .environmentObject(appState)
                .onDisappear {
                    appState.hasCompletedOnboarding = true
                }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(page.color.opacity(0.15))
                    .frame(width: 100, height: 100)

                Image(systemName: page.icon)
                    .font(.system(size: 44))
                    .foregroundStyle(page.color)
            }

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)

                Text(page.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - OnboardingPage

struct OnboardingPage {
    let icon: String
    let title: String
    let body: String
    let color: Color
}
