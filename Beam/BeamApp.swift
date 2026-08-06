// BeamApp.swift
// iOS Beam client app entry point.

import SwiftUI
import UIKit

// MARK: - App Delegate

/// Catches cold-launch URLs (e.g. widget tap while app is fully terminated).
/// `application(_:open:)` fires before @StateObject BeamAppState is created,
/// so we stash the intent in UserDefaults for BeamAppState.init() to pick up.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if let url = launchOptions?[.url] as? URL,
           url.scheme == "beam", url.host == "start" {
            UserDefaults.standard.set(true, forKey: "beam.pendingAutoStart")
        }
        return true
    }
}

// MARK: - App

@main
struct BeamApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = BeamAppState()
    @ObservedObject private var flags = FeatureFlags.shared
    @State private var whatsNew: WhatsNewPresentation?

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
                .task {
                    if ShotMode.isActive { ShotMode.seed(appState); return }
                    evaluateWhatsNew()
                    FeatureFlags.shared.refresh()
                    PromoConfig.shared.refresh()
                }
                // A feature can latch on mid-session; surface its notice as soon as it does.
                .onChange(of: flags.unlocked) { _ in evaluateWhatsNew() }
                .sheet(item: $whatsNew) { presentation in
                    switch presentation {
                    case .version:
                        WhatsNewView(
                            entries: WhatsNewManager.versionEntries,
                            subtitle: "Version \(WhatsNewManager.appVersion)"
                        ) {
                            WhatsNewManager.markVersionSeen()
                            whatsNew = nil
                            // A gated feature may also be waiting — it was suppressed while
                            // the version notes were pending, so re-check now.
                            evaluateWhatsNew()
                        }
                        .interactiveDismissDisabled(false)
                    case .unlock(let feature, let entry):
                        WhatsNewView(
                            entries: [entry],
                            title: "New in Beam",
                            subtitle: "Just unlocked"
                        ) {
                            WhatsNewManager.markUnlockSeen(feature)
                            whatsNew = nil
                        }
                        .interactiveDismissDisabled(false)
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == "beam", url.host == "start" else { return }
                    // Dismiss What's New if it's up — don't mark seen so it
                    // still appears on the next normal (non-widget) app open.
                    whatsNew = nil
                    appState.requestAutoStart()
                }
        }
    }
}

// MARK: - What's New routing

/// The two changelog surfaces share one sheet slot so they can never stack.
enum WhatsNewPresentation: Identifiable {
    case version
    case unlock(FeatureFlags.Feature, ChangeEntry)

    var id: String {
        switch self {
        case .version:                return "version"
        case .unlock(let feature, _): return "unlock-" + feature.rawValue
        }
    }
}

private extension BeamApp {
    /// Picks the changelog owed to the user, if any. Version notes take precedence;
    /// `pendingUnlock()` self-suppresses while they're outstanding.
    @MainActor
    func evaluateWhatsNew() {
        guard whatsNew == nil else { return }
        if WhatsNewManager.shouldShowVersion {
            whatsNew = .version
        } else if let pending = WhatsNewManager.pendingUnlock() {
            whatsNew = .unlock(pending.feature, pending.entry)
        }
    }
}

// MARK: - Root Navigation

struct RootView: View {
    @EnvironmentObject var appState: BeamAppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if ShotMode.isActive {
                // Screenshot harness drives the screen directly (see ShotMode.swift).
                // Inert in every normal launch.
                ShotMode.rootView()
            } else if appState.hasCompletedOnboarding {
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
            // Re-check flags on every foreground: a user who was offline at launch (or on a
            // LAN with no internet) gets the unlock the moment they next have connectivity.
            if phase == .active {
                FeatureFlags.shared.refresh()
                // Also on foreground, so a promo Kevin ended server-side goes quiet without
                // waiting for a cold launch.
                PromoConfig.shared.refresh()
            }
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
