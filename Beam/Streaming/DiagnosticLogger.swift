// DiagnosticLogger.swift
// Persistent rolling log for connection diagnostics.
// Survives app restarts — entries are appended to a file in Caches so they're
// available even if the user opens feedback after killing and reopening the app.
// The file is rotated when it exceeds ~100 KB, keeping the most recent half.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "Diagnostics")

final class DiagnosticLogger {

    static let shared = DiagnosticLogger()

    private let logFile: URL
    private let fileQueue = DispatchQueue(label: "com.beam.ios.diagnosticlog", qos: .utility)
    private let maxFileBytes = 100_000   // ~100 KB
    private let trimToBytes  =  50_000  // keep most recent ~50 KB after rotation

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        logFile = caches.appendingPathComponent("beam_diagnostic.log")
        // Write a session-start marker so it's clear where each launch begins
        let marker = sessionMarker()
        fileQueue.async { [weak self] in
            self?.appendLine(marker)
        }
    }

    // MARK: - Public API

    /// Harness only: sees every line as it is logged.
    var mirror: ((_ message: String, _ category: String) -> Void)?

    func log(_ message: String, category: String = "General") {
        logger.debug("[\(category)] \(message)")
        mirror?(message, category)
        let line = formatted(message: message, category: category)
        fileQueue.async { [weak self] in
            self?.appendLine(line)
        }
    }

    /// Returns the full contents of the persistent log file.
    func export() -> String {
        fileQueue.sync {
            (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        }
    }

    func clear() {
        fileQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: logFile)
        }
    }

    // MARK: - File I/O

    private func appendLine(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                let size = handle.offsetInFile
                try? handle.close()
                if size > maxFileBytes { rotateFile() }
            }
        } else {
            try? data.write(to: logFile, options: .atomic)
        }
    }

    /// Keeps the most recent `trimToBytes` bytes so the file doesn't grow unboundedly.
    private func rotateFile() {
        guard let existing = try? Data(contentsOf: logFile),
              existing.count > trimToBytes else { return }
        let trimmed = existing.suffix(trimToBytes)
        // Find the first newline so we don't start mid-line
        if let newlineIdx = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
            let clean = trimmed[(newlineIdx + 1)...]
            try? Data(clean).write(to: logFile, options: .atomic)
        } else {
            try? Data(trimmed).write(to: logFile, options: .atomic)
        }
    }

    // MARK: - Formatting

    private func formatted(message: String, category: String) -> String {
        let ts = DateFormatter.logFormatter.string(from: Date())
        return "[\(ts)] [\(category)] \(message)"
    }

    private func sessionMarker() -> String {
        let ts = DateFormatter.logFormatter.string(from: Date())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "[\(ts)] [Session] App launched — v\(version) (\(build)) iOS \(os)"
    }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
