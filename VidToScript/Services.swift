//  Services.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import SwiftData

// MARK: - Error Domain
struct ErrorDomain {
    nonisolated static let audio = "com.vidtoscript.audio"
    nonisolated static let storage = "com.vidtoscript.storage"
    nonisolated static let transcription = "com.vidtoscript.transcription"
}

// MARK: - Audio Extraction Result
struct AudioExtractionResult: Sendable {
    let audioURL: URL
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let fileSize: Int64
    let format: AudioFormat
}

enum AudioFormat: String, Sendable {
    case wav = "wav"
    case mp3 = "mp3"
    case m4a = "m4a"
}

// MARK: - Storage Service Protocol
protocol StorageServiceProtocol: Actor {
    func saveVideoFile(from url: URL, for projectID: UUID) async throws -> URL
    func deleteProjectFiles(projectID: UUID) async throws
    func getProjectDirectory(projectID: UUID) async -> URL
    func fileExists(at url: URL) async -> Bool
    func getFileSize(at url: URL) async throws -> Int64
}

// MARK: - Storage Service
actor StorageService: StorageServiceProtocol {
    
    private let fileManager = FileManager.default
    private let documentsDirectory: URL
    
    init() throws {
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StorageError.cannotAccessDocuments
        }
        self.documentsDirectory = docsURL
        
        // Create base directories
        try Self.createBaseDirectories(at: docsURL)
    }
    
    private static func createBaseDirectories(at documentsDirectory: URL) throws {
        let fileManager = FileManager.default
        let projectsDir = documentsDirectory.appendingPathComponent("Projects")
        try fileManager.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableProjectsDirectory = projectsDir
        try? mutableProjectsDirectory.setResourceValues(values)
    }
    
    func saveVideoFile(from url: URL, for projectID: UUID) async throws -> URL {
        let projectDir = try getOrCreateProjectDirectory(projectID: projectID)
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let destinationURL = projectDir.appendingPathComponent("video.\(ext)")

        let sourceSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        try ensureAvailableSpace(at: projectDir, requiredBytes: max(Int64(Double(sourceSize) * 1.1) + 20_000_000, 50_000_000))
        
        // Remove existing file if present
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                    do { try FileManager.default.copyItem(at: coordinatedURL, to: destinationURL) }
                    catch { copyError = error }
                }
                if let coordinationError { continuation.resume(throwing: coordinationError) }
                else if let copyError { continuation.resume(throwing: copyError) }
                else { continuation.resume() }
            }
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDestination = destinationURL
        try? mutableDestination.setResourceValues(resourceValues)
        return destinationURL
    }
    
    func deleteProjectFiles(projectID: UUID) async throws {
        let projectDir = documentsDirectory
            .appendingPathComponent("Projects")
            .appendingPathComponent(projectID.uuidString)
        
        if fileManager.fileExists(atPath: projectDir.path) {
            try fileManager.removeItem(at: projectDir)
        }
    }
    
    func getProjectDirectory(projectID: UUID) async -> URL {
        documentsDirectory
            .appendingPathComponent("Projects")
            .appendingPathComponent(projectID.uuidString)
    }
    
    private func getOrCreateProjectDirectory(projectID: UUID) throws -> URL {
        let projectDir = documentsDirectory
            .appendingPathComponent("Projects")
            .appendingPathComponent(projectID.uuidString)
        
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = projectDir
        try? mutableDirectory.setResourceValues(resourceValues)
        return projectDir
    }

    private func ensureAvailableSpace(at url: URL, requiredBytes: Int64) throws {
        let capacity = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity >= requiredBytes else { throw StorageError.insufficientStorage }
    }
    
    func fileExists(at url: URL) async -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
    
    func getFileSize(at url: URL) async throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }
}

// MARK: - Storage Error
enum StorageError: Error, LocalizedError {
    case cannotAccessDocuments
    case fileNotFound
    case fileCopyFailed
    case directoryCreationFailed
    case insufficientStorage
    
    var errorDescription: String? {
        switch self {
        case .cannotAccessDocuments:
            return "Cannot access documents directory"
        case .fileNotFound:
            return "File not found"
        case .fileCopyFailed:
            return "Failed to copy file"
        case .directoryCreationFailed:
            return "Failed to create directory"
        case .insufficientStorage:
            return "Not enough storage space available"
        }
    }
}

// MARK: - Project Repository Protocol
protocol ProjectRepositoryProtocol: Actor {
    func createProject(title: String, videoURL: URL, targetLanguage: String) async -> Result<VideoProject, ProjectError>
    func getAllProjects() async -> [PersistedProject]
    func getProject(byID id: UUID) async -> PersistedProject?
    func updateProject(_ project: PersistedProject) async throws
    func syncRuntimeProject(_ snapshot: ProjectSnapshot) async throws
    func deleteProject(_ project: PersistedProject) async throws
    func deleteProject(byID id: UUID) async throws
    func reconcileInterruptedProjects() async
}

// MARK: - Project Repository
@ModelActor
actor ProjectRepository: ProjectRepositoryProtocol {
    
    /// The macro-generated `init(modelContainer:)` cannot receive this app
    /// dependency. Keep a nil default so that generated initializer remains
    /// valid; normal app construction injects the concrete storage actor.
    private var storageService: (any StorageServiceProtocol)? = nil

    private func resolvedStorageService() throws -> any StorageServiceProtocol {
        guard let storageService else { throw StorageError.cannotAccessDocuments }
        return storageService
    }
    
    init(storageService: StorageServiceProtocol, modelContainer: ModelContainer) {
        self.storageService = storageService
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
    }
    
    func createProject(title: String, videoURL: URL, targetLanguage: String = "en") async -> Result<VideoProject, ProjectError> {
        do {
            // Save video file
            let projectID = UUID()
            let savedVideoURL = try await resolvedStorageService().saveVideoFile(from: videoURL, for: projectID)
            
            // Create persisted project
            let persistedProject = PersistedProject(
                id: projectID,
                title: title,
                videoFilePath: savedVideoURL.path,
                creationDate: Date(),
                status: .importing,
                targetLanguage: targetLanguage
            )
            
            modelContext.insert(persistedProject)
            try modelContext.save()
            
            // Create runtime project
            let videoProject = VideoProject(
                id: projectID,
                title: title,
                videoFileURL: savedVideoURL,
                creationDate: Date(),
                status: .importing,
                targetLanguage: targetLanguage
            )
            
            return .success(videoProject)
            
        } catch {
            return .failure(.creationFailed(error.localizedDescription))
        }
    }
    
    func getAllProjects() async -> [PersistedProject] {
        let descriptor = FetchDescriptor<PersistedProject>(
            sortBy: [SortDescriptor(\.creationDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    func getProject(byID id: UUID) async -> PersistedProject? {
        let predicate = #Predicate<PersistedProject> { $0.id == id }
        let descriptor = FetchDescriptor<PersistedProject>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }
    
    func updateProject(_ project: PersistedProject) async throws {
        try modelContext.save()
    }
    
    func syncRuntimeProject(_ snapshot: ProjectSnapshot) async throws {
        let projectID = snapshot.id
        let predicate = #Predicate<PersistedProject> { $0.id == projectID }
        let descriptor = FetchDescriptor<PersistedProject>(predicate: predicate)
        if let persisted = try modelContext.fetch(descriptor).first {
            // The editor writes a rename directly to SwiftData. Pipeline
            // progress must never race that user action and restore an older
            // in-memory title.
            persisted.duration = snapshot.duration
            persisted.status = snapshot.status
            persisted.segments = snapshot.segments
            persisted.isVerbatim = snapshot.isVerbatim
            persisted.targetLanguage = snapshot.targetLanguage
            persisted.detectedLanguage = snapshot.detectedLanguage
            persisted.audioFileURL = snapshot.audioFileURL
            persisted.progress = snapshot.progress
            persisted.errorMessage = snapshot.errorMessage
            persisted.lastModifiedDate = Date()
            try modelContext.save()
        }
    }
    
    func deleteProject(_ project: PersistedProject) async throws {
        try await deleteProject(byID: project.id)
    }
    
    func deleteProject(byID id: UUID) async throws {
        // Delete files first
        try await resolvedStorageService().deleteProjectFiles(projectID: id)
        
        // Delete from database context
        let predicate = #Predicate<PersistedProject> { $0.id == id }
        let descriptor = FetchDescriptor<PersistedProject>(predicate: predicate)
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    func reconcileInterruptedProjects() async {
        let descriptor = FetchDescriptor<PersistedProject>()
        guard let projects = try? modelContext.fetch(descriptor) else { return }
        var changed = false
        for project in projects where project.status.isProcessing {
            project.status = .error
            project.errorMessage = "Processing was interrupted. Tap Retry to continue."
            project.progress = 0
            project.lastModifiedDate = Date()
            changed = true
        }
        if changed { try? modelContext.save() }
    }
}

// MARK: - Project Error
enum ProjectError: Error, LocalizedError {
    case creationFailed(String)
    case notFound
    case updateFailed(String)
    case deletionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .creationFailed(let reason):
            return "Failed to create project: \(reason)"
        case .notFound:
            return "Project not found"
        case .updateFailed(let reason):
            return "Failed to update project: \(reason)"
        case .deletionFailed(let reason):
            return "Failed to delete project: \(reason)"
        }
    }
}
