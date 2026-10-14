//  Utils.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import UIKit
import OSLog

enum AppSettings {
    static let appGroupID = "group.cognetex.VidToScript"
    static let selectedModelFilename = "selectedModelFilename"
    static let targetSpeakerCount = "targetSpeakerCount"
    static let defaultModelFilename = "ggml-large-v3-turbo.bin"
    static let lastSelectedLanguage = "lastSelectedLanguage"
    static let preferUrduOverHindi = "preferUrduOverHindi"

    /// Keys persisted in the shared App Group. Keep these separate from the
    /// app's ordinary UserDefaults keys so neither target writes unrelated
    /// preferences into the shared `cfprefsd` domain.
    enum SharedKey {
        static let pendingSharedVideoURL = "pendingSharedVideoURL"
        static let pendingSharedVideoPaths = "pendingSharedVideoPaths"
    }

    static var sharedDefaults: UserDefaults? {
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) != nil else {
            AppLogger.shared.error(
                "App Group entitlement is unavailable; shared hand-off is disabled.",
                category: .storage
            )
            return nil
        }
        return UserDefaults(suiteName: appGroupID)
    }
}

/// Shared, reference-counted display-awake lease for processing work. A job
/// releasing its lease cannot re-enable auto-lock while another job still owns
/// one.
@MainActor
final class IdleTimerManager {
    static let shared = IdleTimerManager()
    private var counter = 0

    func retainTimer() {
        counter += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func releaseTimer() {
        counter = max(0, counter - 1)
        if counter == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: - AppLogger (avoiding conflict with OSLog.Logger)
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    private static let subsystem = "com.cognetex.VidToScript"
    
    private init() {}

    private nonisolated func logger(for category: LogCategory) -> Logger {
        Logger(subsystem: Self.subsystem, category: category.rawValue)
    }
    
    nonisolated func debug(_ message: String, category: LogCategory = .default) {
        #if DEBUG
        logger(for: category).debug("\(message, privacy: .private(mask: .hash))")
        #endif
    }
    
    nonisolated func info(_ message: String, category: LogCategory = .default) {
        logger(for: category).info("\(message, privacy: .private(mask: .hash))")
    }
    
    nonisolated func warning(_ message: String, category: LogCategory = .default) {
        logger(for: category).warning("\(message, privacy: .private(mask: .hash))")
    }
    
    nonisolated func error(_ message: String, category: LogCategory = .default) {
        logger(for: category).error("\(message, privacy: .private(mask: .hash))")
    }
}

// MARK: - Log Category
enum LogCategory: String {
    case `default` = "default"
    case general = "general"
    case audio = "audio"
    case storage = "storage"
    case transcription = "transcription"
    case ui = "ui"
}

// MARK: - Project Info
enum ProjectInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    static var copyright: String {
        "© 2026 VidToScript. All rights reserved."
    }
}

// MARK: - URL Extension for Documents Directory
extension URL {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }
}
