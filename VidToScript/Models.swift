//  Models.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import SwiftData

// MARK: - Project Status
enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case draft = "draft"
    case queued = "queued"
    case importing = "importing"
    case extractingAudio = "extracting_audio"
    case processingAudio = "processing_audio"
    case detectingSpeakers = "detecting_speakers"
    case transcribing = "transcribing"
    case ready = "ready"
    case editing = "editing"
    case exporting = "exporting"
    case cancelled = "cancelled"
    case error = "error"

    var isProcessing: Bool {
        switch self {
        case .queued, .importing, .extractingAudio, .processingAudio, .detectingSpeakers, .transcribing, .exporting:
            return true
        default:
            return false
        }
    }
    
    var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .queued: return "Queued"
        case .importing: return "Importing"
        case .extractingAudio: return "Extracting Audio"
        case .processingAudio: return "Processing Audio"
        case .detectingSpeakers: return "Detecting Speakers"
        case .transcribing: return "Transcribing"
        case .ready: return "Ready"
        case .editing: return "Editing"
        case .exporting: return "Exporting"
        case .cancelled: return "Cancelled"
        case .error: return "Error"
        }
    }
}

import Observation

// MARK: - Project Progress Store
@Observable
final class ProjectProgressStore: @unchecked Sendable {
    static let shared = ProjectProgressStore()
    
    var progresses: [UUID: Double] = [:]
    var statuses: [UUID: ProjectStatus] = [:]
    var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// Canonical in-memory project for an active pipeline. Views must reuse it
    /// instead of creating a second, disconnected VideoProject instance.
    var activeProjects: [UUID: VideoProject] = [:]
    
    private init() {}
}

extension ProjectProgressStore {
    func prune(projectID: UUID) {
        progresses.removeValue(forKey: projectID)
        statuses.removeValue(forKey: projectID)
        activeTasks.removeValue(forKey: projectID)
        activeProjects.removeValue(forKey: projectID)
    }
}

@Observable
final class VideoProject: Identifiable, @unchecked Sendable {
    let id: UUID
    var title: String
    var videoFileURL: URL?
    var audioFileURL: URL?
    var creationDate: Date
    var duration: TimeInterval
    var status: ProjectStatus
    var segments: [TranscriptSegment]
    var isVerbatim: Bool
    var targetLanguage: String
    var detectedLanguage: String?
    var progress: Double
    var errorMessage: String?
    
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("imported_") || (trimmed.count > 30 && trimmed.contains("-")) || trimmed == "Photo Video" {
            return "Transcription - \(creationDate.formatted(date: .abbreviated, time: .shortened))"
        }
        return trimmed.isEmpty ? "Transcription - \(creationDate.formatted(date: .abbreviated, time: .shortened))" : trimmed
    }
    
    nonisolated init(
        id: UUID = UUID(),
        title: String,
        videoFileURL: URL? = nil,
        audioFileURL: URL? = nil,
        creationDate: Date = Date(),
        duration: TimeInterval = 0,
        status: ProjectStatus = .draft,
        segments: [TranscriptSegment] = [],
        isVerbatim: Bool = true,
        targetLanguage: String = "en",
        detectedLanguage: String? = nil,
        progress: Double = 0.0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.videoFileURL = videoFileURL
        self.audioFileURL = audioFileURL
        self.creationDate = creationDate
        self.duration = duration
        self.status = status
        self.segments = segments
        self.isVerbatim = isVerbatim
        self.targetLanguage = targetLanguage
        self.detectedLanguage = detectedLanguage
        self.progress = progress
        self.errorMessage = errorMessage
    }
}

/// Immutable UI-to-storage boundary. Construct on the main actor, then pass
/// only this Sendable value into the SwiftData model actor.
struct ProjectSnapshot: Sendable {
    let id: UUID
    let title: String
    let duration: Double
    let status: ProjectStatus
    let segments: [TranscriptSegment]
    let isVerbatim: Bool
    let targetLanguage: String
    let detectedLanguage: String?
    let audioFileURL: URL?
    let progress: Double
    let errorMessage: String?

    @MainActor init(_ project: VideoProject) {
        id = project.id
        title = project.title
        duration = project.duration
        status = project.status
        segments = project.segments
        isVerbatim = project.isVerbatim
        targetLanguage = project.targetLanguage
        detectedLanguage = project.detectedLanguage
        audioFileURL = project.audioFileURL
        progress = project.progress
        errorMessage = project.errorMessage
    }
}

// MARK: - Transcript Segment
struct WordTiming: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var word: String
    var startTime: TimeInterval
    var endTime: TimeInterval

    nonisolated init(id: UUID = UUID(), word: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speakerID: String
    var text: String
    var isVerbatim: Bool
    /// Real Whisper token-derived timing. Empty for transcripts created before
    /// token timestamps were added; callers should gracefully fall back to
    /// unhighlighted text rather than fabricating even word timing.
    var words: [WordTiming]
    
    nonisolated init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerID: String,
        text: String,
        isVerbatim: Bool = true,
        words: [WordTiming] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
        self.text = text
        self.isVerbatim = isVerbatim
        self.words = words
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, speakerID, text, isVerbatim, words
    }

    /// Existing JSON blobs do not have `words`; retain those projects during
    /// migration by treating the missing field as no token-level timing.
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        startTime = try values.decode(TimeInterval.self, forKey: .startTime)
        endTime = try values.decode(TimeInterval.self, forKey: .endTime)
        speakerID = try values.decode(String.self, forKey: .speakerID)
        text = try values.decode(String.self, forKey: .text)
        isVerbatim = try values.decodeIfPresent(Bool.self, forKey: .isVerbatim) ?? true
        words = try values.decodeIfPresent([WordTiming].self, forKey: .words) ?? []
    }
    
    var duration: TimeInterval {
        endTime - startTime
    }
}

// MARK: - Speaker
struct Speaker: Identifiable, Codable, Sendable {
    let id: String
    var name: String
    var color: String
    var voiceEmbedding: [Float]?
    
    init(
        id: String,
        name: String,
        color: String = "#007AFF",
        voiceEmbedding: [Float]? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.voiceEmbedding = voiceEmbedding
    }
}

// MARK: - Diarization Segment
/// A timestamped speech region attributed to a generic speaker identity
/// (e.g. "Speaker 0"). Produced by `SpeakerDiarizationService` and consumed by
/// `TranscribeService` to label ASR text segments with their speaker.
struct DiarizationSegment: Identifiable, Sendable, Codable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speakerID: String

    nonisolated init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerID: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
    }

    var duration: TimeInterval { endTime - startTime }

    /// Overlap (in seconds) between this segment and the given time range.
    /// Used to attribute an ASR segment to the dominant speaker.
    nonisolated func overlap(with start: TimeInterval, _ end: TimeInterval) -> TimeInterval {
        let lo = max(startTime, start)
        let hi = min(endTime, end)
        return max(0, hi - lo)
    }
}

// MARK: - SwiftData Models

@Model
final class PersistedProject {
    @Attribute(.unique) var id: UUID
    var title: String
    var videoFilePath: String?
    var audioFilePath: String?
    var creationDate: Date
    var lastModifiedDate: Date
    var duration: Double
    var statusRaw: String
    @Attribute(.externalStorage) var segmentsData: Data?
    var speakersData: Data?
    var isVerbatim: Bool
    var targetLanguage: String?
    var detectedLanguage: String?
    var progress: Double
    /// User-visible reason for a failed pipeline.  Keeping it in the project
    /// allows a failed item to be retried after navigating away.
    var errorMessage: String?
    
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("imported_") || (trimmed.count > 30 && trimmed.contains("-")) || trimmed == "Photo Video" {
            return "Transcription - \(creationDate.formatted(date: .abbreviated, time: .shortened))"
        }
        return trimmed.isEmpty ? "Transcription - \(creationDate.formatted(date: .abbreviated, time: .shortened))" : trimmed
    }
    
    init(
        id: UUID = UUID(),
        title: String,
        videoFilePath: String? = nil,
        audioFilePath: String? = nil,
        creationDate: Date = Date(),
        lastModifiedDate: Date = Date(),
        duration: Double = 0,
        status: ProjectStatus = .draft,
        segments: [TranscriptSegment] = [],
        speakers: [Speaker] = [],
        isVerbatim: Bool = true,
        targetLanguage: String? = nil,
        detectedLanguage: String? = nil,
        progress: Double = 0.0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.videoFilePath = ProjectMediaPath.relativePath(for: videoFilePath)
        self.audioFilePath = ProjectMediaPath.relativePath(for: audioFilePath)
        self.creationDate = creationDate
        self.lastModifiedDate = lastModifiedDate
        self.duration = duration
        self.statusRaw = status.rawValue
        self.segmentsData = try? JSONEncoder().encode(segments)
        self.speakersData = try? JSONEncoder().encode(speakers)
        self.isVerbatim = isVerbatim
        self.targetLanguage = targetLanguage
        self.detectedLanguage = detectedLanguage
        self.progress = progress
        self.errorMessage = errorMessage
    }
    
    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }
    
    var segments: [TranscriptSegment] {
        get {
            guard let data = segmentsData else { return [] }
            return (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
        }
        set {
            segmentsData = try? JSONEncoder().encode(newValue)
        }
    }
    
    var speakers: [Speaker] {
        get {
            guard let data = speakersData else { return [] }
            return (try? JSONDecoder().decode([Speaker].self, from: data)) ?? []
        }
        set {
            speakersData = try? JSONEncoder().encode(newValue)
        }
    }
    
    var videoFileURL: URL? {
        get { ProjectMediaPath.url(for: videoFilePath) }
        set { videoFilePath = ProjectMediaPath.relativePath(for: newValue?.path) }
    }
    
    var audioFileURL: URL? {
        get { ProjectMediaPath.url(for: audioFilePath) }
        set { audioFilePath = ProjectMediaPath.relativePath(for: newValue?.path) }
    }
}

/// Database paths are relative to Documents so they remain valid after an app
/// restore or container relocation.  Absolute legacy paths continue to open
/// once and are converted on the next save.
enum ProjectMediaPath {
    nonisolated static func documentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath()
    }

    nonisolated static func relativePath(for path: String?) -> String? {
        guard let path, let documentsURL = documentsURL() else { return path }
        let absolute = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let root = documentsURL.path + "/"
        return absolute.hasPrefix(root) ? String(absolute.dropFirst(root.count)) : path
    }

    nonisolated static func url(for path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).resolvingSymlinksInPath() } // legacy record
        return documentsURL().map { $0.appendingPathComponent(path).resolvingSymlinksInPath() }
    }
}

// MARK: - Persistable Video Project
extension VideoProject {
    nonisolated convenience init(from persisted: PersistedProject) {
        self.init(
            id: persisted.id,
            title: persisted.title,
            videoFileURL: persisted.videoFileURL,
            audioFileURL: persisted.audioFileURL,
            creationDate: persisted.creationDate,
            duration: persisted.duration,
            status: persisted.status,
            segments: persisted.segments,
            isVerbatim: persisted.isVerbatim,
            targetLanguage: persisted.targetLanguage ?? "en",
            detectedLanguage: persisted.detectedLanguage,
            progress: persisted.progress,
            errorMessage: persisted.errorMessage
        )
    }
}

// MARK: - Hashable Conformance
extension VideoProject: Hashable {
    static func == (lhs: VideoProject, rhs: VideoProject) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
