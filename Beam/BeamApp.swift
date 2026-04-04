// BeamApp.swift
// iOS Beam client app entry point.

import SwiftUI
import UIKit

@main
struct BeamApp: App {

    @StateObject private var appState = BeamAppState()
    @State private var showWhatsNew = WhatsNewManager.shouldShow

    init() {
        Analytics.start()
        observeSystemEvents()
    }

    private func observeSystemEvents() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            DiagnosticLogger.shared.log(
                "Memory warning received (thermal=\(ProcessInfo.processInfo.thermalState.name))",
                category: "System"
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
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
    @EnvironmentObject var appState: BeamAppState
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
        .onChange(of: scenePhase) { phase in
            appState.handleScenePhaseChange(phase)
            DiagnosticLogger.shared.log(
                "Scene phase → \(phase.name) (streaming=\(appState.isStreaming))",
                category: "Lifecycle"
            )
        }
    }
}

// MARK: - Helpers

private extension ScenePhase {
    var name: String {
        switch self {
        case .active:     return "active"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

private extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
