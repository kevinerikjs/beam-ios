// BeamApp.swift
// iOS Beam client app entry point.

import SwiftUI

@main
struct BeamApp: App {

    @State private var appState = BeamAppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)  // Dark mode first per PRD
        }
    }
}

// MARK: - Root Navigation

struct RootView: View {
    @Environment(BeamAppState.self) private var appState

    var body: some View {
        Group {
            if appState.hasCompletedOnboarding {
                if appState.isStreaming {
                    StreamView()
                } else {
                    HomeView()
                }
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isStreaming)
        .animation(.easeInOut(duration: 0.3), value: appState.hasCompletedOnboarding)
    }
}
