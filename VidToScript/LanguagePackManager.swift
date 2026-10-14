//  LanguagePackManager.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import BackgroundAssets
import SwiftUI

// MARK: - Status & Model
enum LanguagePackStatus: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
}

struct LanguagePack: Identifiable, Equatable {
    let id: String
    let displayName: String
    let tierName: String
    let fileName: String
    let sizeInMB: Int
    var status: LanguagePackStatus
    var localModelURL: URL?
    let remoteURL: URL
}

// MARK: - Manager
/// Manages high-accuracy multilingual and Urdu GGML models downloaded directly
/// from HuggingFace to the shared App Group directory (`group.cognetex.VidToScript/Models/`).
@Observable
final class LanguagePackManager: NSObject {

    static let shared = LanguagePackManager()

    var packs: [LanguagePack] = []
    
    private let appGroupIdentifier = AppSettings.appGroupID
    private var activeDownloads: [String: URLSessionDownloadTask] = [:]
    private var progressObservers: [String: NSKeyValueObservation] = [:]

    private override init() {
        super.init()
        setupInitialPacks()
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.checkInstalledPacks()
            }
        }
    }

    // MARK: - Setup Catalog
    private func setupInitialPacks() {
        packs = [
            LanguagePack(
                id: "ur-large-turbo",
                displayName: "Highest Accuracy Pack (1.62 GB)",
                tierName: "Highest Accuracy",
                fileName: "ggml-large-v3-turbo.bin",
                sizeInMB: 1620,
                status: .notInstalled,
                remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
            ),
            LanguagePack(
                id: "multilingual-small",
                displayName: "Balanced Pack (264 MB)",
                tierName: "Balanced",
                fileName: "ggml-small-q8_0.bin",
                sizeInMB: 264,
                status: .notInstalled,
                remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin")!
            ),
            LanguagePack(
                id: "multilingual-base",
                displayName: "Fast Pack (82 MB)",
                tierName: "Fast",
                fileName: "ggml-base-q8_0.bin",
                sizeInMB: 82,
                status: .notInstalled,
                remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q8_0.bin")!
            )
        ]
    }

    func checkInstalledPacks() {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return }
        let modelsDir = groupURL.appendingPathComponent("Models")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in 0..<self.packs.count {
                let modelURL = modelsDir.appendingPathComponent(self.packs[i].fileName)
                if FileManager.default.fileExists(atPath: modelURL.path) {
                    self.packs[i].status = .installed
                    self.packs[i].localModelURL = modelURL
                } else {
                    if case .downloading = self.packs[i].status {
                        // preserve active progress
                    } else {
                        self.packs[i].status = .notInstalled
                        self.packs[i].localModelURL = nil
                    }
                }
            }
        }
    }

    // MARK: - Active Model Resolution
    /// Returns details of the currently active model (selected or auto-resolved).
    func activeModelSummary() -> (fileName: String, displayName: String, isDownloaded: Bool) {
        let selectedFilename = UserDefaults.standard.string(forKey: AppSettings.selectedModelFilename) ?? ""
        let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        let modelsDir = groupURL?.appendingPathComponent("Models")
        
        // 1. Explicit user selection
        if !selectedFilename.isEmpty {
            if let modelsDir {
                let fileURL = modelsDir.appendingPathComponent(selectedFilename)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let pack = packs.first(where: { $0.fileName == selectedFilename })
                    return (selectedFilename, pack?.displayName ?? selectedFilename, true)
                }
            }
            // Check bundle fallback if user selected a bundled model name
            let baseName = selectedFilename.replacingOccurrences(of: ".bin", with: "")
            if Bundle.main.url(forResource: baseName, withExtension: "bin") != nil {
                return (selectedFilename, "Bundled \(baseName)", true)
            }
        }
        
        // 2. Automatic resolution: Large Turbo > Large Turbo Quantized > Small > Base
        let priorityList = [
            ("ggml-large-v3-turbo.bin", "Urdu & Multilingual Studio (Large Turbo)"),
            ("ggml-large-v3-turbo-q8_0.bin", "Urdu & Multilingual (Large Turbo)"),
            ("ggml-small-q8_0.bin", "Multilingual Small"),
            ("ggml-base-q8_0.bin", "Multilingual Base")
        ]
        
        if let modelsDir {
            for (fileName, displayName) in priorityList {
                let fileURL = modelsDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    return (fileName, "\(displayName) (Auto)", true)
                }
            }
        }
        
        // 3. Fallback to bundled model
        if let bundledURL = TranscribeService.locateBundledModel() {
            return (bundledURL.lastPathComponent, "Bundled Fallback (\(bundledURL.lastPathComponent))", false)
        }
        
        return ("None", "No Model Available", false)
    }

    // MARK: - Actions
    func download(pack: LanguagePack) {
        guard let index = packs.firstIndex(where: { $0.id == pack.id }) else { return }
        packs[index].status = .downloading(progress: 0.01)

        let task = URLSession.shared.downloadTask(with: pack.remoteURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            
            defer {
                DispatchQueue.main.async {
                    self.progressObservers.removeValue(forKey: pack.id)
                    self.activeDownloads.removeValue(forKey: pack.id)
                }
            }
            
            if let error {
                AppLogger.shared.warning("Download failed for \(pack.displayName): \(error)", category: .general)
                DispatchQueue.main.async {
                    if let idx = self.packs.firstIndex(where: { $0.id == pack.id }) {
                        self.packs[idx].status = .notInstalled
                    }
                }
                return
            }
            
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let tempURL, let groupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: self.appGroupIdentifier
            ) else {
                AppLogger.shared.warning("Model download returned an invalid response for \(pack.fileName)", category: .general)
                DispatchQueue.main.async {
                    if let idx = self.packs.firstIndex(where: { $0.id == pack.id }) {
                        self.packs[idx].status = .notInstalled
                    }
                }
                return
            }
            
            let modelsDir = groupURL.appendingPathComponent("Models")
            do {
                try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
                var directoryValues = URLResourceValues()
                directoryValues.isExcludedFromBackup = true
                var mutableModelsDir = modelsDir
                try? mutableModelsDir.setResourceValues(directoryValues)
            } catch {
                return self.markDownloadFailed(pack, error: error)
            }
            let finalURL = modelsDir.appendingPathComponent(pack.fileName)
            
            do {
                let downloadedSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64 ?? 0
                let minimumExpectedBytes = Int64(pack.sizeInMB) * 1_000_000 * 9 / 10
                guard downloadedSize >= minimumExpectedBytes else {
                    throw CocoaError(.fileReadCorruptFile)
                }

                // Replace atomically where possible. Do not delete a known-good
                // installed model before the new download has passed validation.
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                }
                DispatchQueue.main.async {
                    if let idx = self.packs.firstIndex(where: { $0.id == pack.id }) {
                        self.packs[idx].status = .installed
                        self.packs[idx].localModelURL = finalURL
                    }
                }
            } catch {
                self.markDownloadFailed(pack, error: error)
            }
        }
        
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if let idx = self.packs.firstIndex(where: { $0.id == pack.id }) {
                    self.packs[idx].status = .downloading(progress: progress.fractionCompleted)
                }
            }
        }
        
        progressObservers[pack.id] = observation
        activeDownloads[pack.id] = task
        task.resume()
    }

    private func markDownloadFailed(_ pack: LanguagePack, error: Error) {
        AppLogger.shared.warning("Failed to save model file \(pack.fileName): \(error)", category: .general)
        DispatchQueue.main.async {
            if let idx = self.packs.firstIndex(where: { $0.id == pack.id }) {
                self.packs[idx].status = .notInstalled
            }
        }
    }

    func delete(pack: LanguagePack) {
        guard let index = packs.firstIndex(where: { $0.id == pack.id }) else { return }
        if let localURL = packs[index].localModelURL {
            try? FileManager.default.removeItem(at: localURL)
        }
        packs[index].status = .notInstalled
        packs[index].localModelURL = nil
    }
}
