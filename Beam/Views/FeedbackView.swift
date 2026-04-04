// FeedbackView.swift
// In-app feedback sheet. Posts to beamscreen.app/api/feedback → Telegram notification.

import SwiftUI

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var email = ""
    @State private var includeDiagnostics = false
    @State private var status: Status = .idle

    enum Status { case idle, sending, success, failed }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status == .idle
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if status == .success {
                            successView
                        } else {
                            formView
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.orange)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if status == .sending {
                        ProgressView()
                            .tint(.orange)
                    } else {
                        Button("Send") { send() }
                            .fontWeight(.semibold)
                            .foregroundStyle(canSend ? .orange : .secondary)
                            .disabled(!canSend)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your feedback goes straight to the developer.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Message")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                TextEditor(text: $message)
                    .frame(minHeight: 140)
                    .padding(12)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .tint(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Email (optional)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                TextField("If you'd like a reply", text: $email)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .textContentType(.emailAddress)
                    .padding(12)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .tint(.orange)
            }

            diagnosticsCard

            if case .failed = status {
                Text("Couldn't send — check your connection and try again.")
                    .font(.callout)
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
    }

    // MARK: - Diagnostics Card

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Info callout
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange.opacity(0.8))
                    .font(.system(size: 15))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Having a technical issue?")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                    Text("Attaching a diagnostic log gives us connection events, network changes, and error details that help us fix issues faster. No personal data is collected — only app activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Toggle
            Toggle(isOn: $includeDiagnostics) {
                Text("Attach diagnostic log")
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            .tint(.orange)
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 8) {
                Text("Thanks!")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Your feedback was sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Done") { dismiss() }
                .buttonStyle(BeamPrimaryButtonStyle())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Send

    private func send() {
        guard canSend else { return }
        status = .sending

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnosticsSnapshot = includeDiagnostics ? DiagnosticLogger.shared.export() : nil

        Task {
            do {
                guard let url = URL(string: "https://beamscreen.app/api/feedback") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("9179460b909cb21cb15fe3f9a5260f22ecc111535c2343d3581a1cde49737f67", forHTTPHeaderField: "X-Beam-Secret")
                var payload: [String: String] = ["message": trimmedMessage, "source": "ios"]
                if !trimmedEmail.isEmpty { payload["email"] = trimmedEmail }
                if let log = diagnosticsSnapshot, !log.isEmpty {
                    payload["diagnostics"] = log
                }
                req.httpBody = try JSONEncoder().encode(payload)

                let (_, response) = try await URLSession.shared.data(for: req)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200

                await MainActor.run { status = ok ? .success : .failed }
            } catch {
                await MainActor.run { status = .failed }
            }
        }
    }
}
