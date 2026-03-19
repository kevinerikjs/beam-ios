// BeamApp.swift
// iOS Beam client app entry point.

import SwiftUI

@main
struct BeamApp: App {

    @State private var appState = BeamAppState()
    @State private var showWhatsNew = WhatsNewManager.shouldShow

    init() {
        Analytics.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .sheet(isPresented: $showWhatsNew) {
                    WhatsNewView {
                        WhatsNewManager.markSeen()
                        showWhatsNew = false
                    }
                    .interactiveDismissDisabled(false)
                }
        }
    }
}

// MARK: - Root Navigation

struct RootView: View {
    @Environment(BeamAppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, phase in
            appState.handleScenePhaseChange(phase)
        }
    }
}
