//  TranscriptionPipelineCoordinator.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation

// MARK: - Pipeline Errors
enum PipelineError: Error, LocalizedError, Equatable {
    case extractionFailed(String)
    case diarizationFailed(String)
    case transcriptionFailed(String)
    case noVideoFile
    case cancelled

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let r): return "Audio extraction failed: \(r)"
        case .diarizationFailed(let r): return "Speaker diarization failed: \(r)"
        case .transcriptionFailed(let r): return "Transcription failed: \(r)"
        case .noVideoFile: return "No video file is associated with this project."
        case .cancelled: return "Transcription pipeline was cancelled."
        }
    }
}

// MARK: - Pipeline Progress
/// Coarse-grained progress for the whole sequential pipeline.
enum PipelinePhase: String, Sendable, CaseIterable {
    case idle
    case extractingAudio
    case detectingSpeakers
    case transcribingText
    case done
    case failed

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .extractingAudio: return "Extracting Audio"
        case .detectingSpeakers: return "Detecting Speakers"
        case .transcribingText: return "Transcribing Text"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    func toProjectStatus() -> ProjectStatus {
        switch self {
        case .idle: return .draft
        case .extractingAudio: return .extractingAudio
        case .detectingSpeakers: return .detectingSpeakers
        case .transcribingText: return .transcribing
        case .done: return .ready
        case .failed: return .error
        }
    }
}

struct PipelineProgress: Sendable, Equatable {
    var phase: PipelinePhase
    /// Overall 0.0...1.0 progress across all phases.
    var fraction: Double
    var message: String

    static let idle = PipelineProgress(phase: .idle, fraction: 0.0, message: "Idle")
}

// MARK: - Pipeline Result
/// Final output of the sequential pipeline, handed to UI/persistence state.
struct PipelineResult: Sendable {
    /// The intermediate WAV is intentionally removed after a successful run.
    /// Playback continues from the original video instead.
    let audioURL: URL?
    let audioDuration: TimeInterval
    let speakers: [Speaker]
    let segments: [TranscriptSegment]
    let detectedLanguage: String
}

/// Immutable input captured on the UI actor before a job enters the pipeline.
/// This avoids reading the mutable observable `VideoProject` from services.
struct PipelineProject: Sendable {
    let id: UUID
    let videoURL: URL?
    let targetLanguage: String

    @MainActor init(_ project: VideoProject) {
        id = project.id
        videoURL = project.videoFileURL
        targetLanguage = project.targetLanguage
    }
}

// MARK: - Transcription Pipeline Coordinator
/// Orchestrates the sequential ML pipeline:
///
///   1. `AudioExtractionService`  -> 16 kHz WAV
///   2. `SpeakerDiarizationService` -> speaker map (then released)
///   3. `TranscribeService` -> ASR text aligned to the speaker map (then released)
///
/// RAM contract: stages run **sequentially** and never concurrently. Each
/// service is an `actor` whose instance is created, used, and released within
/// a single phase so peak active RAM stays bounded (target < 750 MB). This
/// coordinator is a `Sendable` value-free orchestrator; it holds no model state.
struct TranscriptionPipelineCoordinator: Sendable {

    let audioService: any AudioExtractionServiceProtocol
    let diarizationService: any SpeakerDiarizationServiceProtocol
    let transcribeService: any TranscriptionServiceProtocol

    init(
        audioService: any AudioExtractionServiceProtocol,
        diarizationService: any SpeakerDiarizationServiceProtocol,
        transcribeService: any TranscriptionServiceProtocol
    ) {
        self.audioService = audioService
        self.diarizationService = diarizationService
        self.transcribeService = transcribeService
    }

    // MARK: - Run
    /// Executes the full pipeline for the given project.
    /// - Parameters:
    ///   - project: The project to transcribe. Must have a `videoFileURL`.
    ///   - progress: Called with coarse overall progress (0%, 33%, 66%, 100%).
    /// - Returns: The pipeline result including aligned transcript segments.
    @discardableResult
    func run(
        for project: PipelineProject,
        progress: @Sendable @escaping (PipelineProgress) async -> Void
    ) async -> Result<PipelineResult, PipelineError> {

        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let videoURL = project.videoURL else { return .failure(.noVideoFile) }

        let projectID = project.id

        // ---- Phase 1: Audio Extraction (0% -> ~33%) -------------------------
        await progress(PipelineProgress(phase: .extractingAudio, fraction: 0.0,
                                        message: "Extracting audio..."))

        let extractionOutcome = await withTaskCancellationHandler(operation: {
            await audioService.extractAudio(
            from: videoURL,
            projectID: projectID,
            progressHandler: { p in
                await progress(PipelineProgress(phase: .extractingAudio,
                                                fraction: 0.33 * p,
                                                message: "Extracting audio... \(Int(p * 100))%"))
            }
            )
        }, onCancel: {
            Task { await cancelAll() }
        })
        let extractionResult: AudioExtractionResult
        switch extractionOutcome {
        case .success(let res):
            extractionResult = res
        case .failure(let err):
            await progress(PipelineProgress(phase: .failed, fraction: 0.0,
                                            message: err.errorDescription ?? "Extraction failed"))
            return .failure(.extractionFailed(err.errorDescription ?? "unknown"))
        }

        await progress(PipelineProgress(phase: .extractingAudio, fraction: 0.33,
                                        message: "Audio extracted"))

        // ---- Phase 2: Speaker Diarization (~33% -> ~66%) -------------------
        await progress(PipelineProgress(phase: .detectingSpeakers, fraction: 0.33,
                                        message: "Detecting speakers..."))

        var diarConfig = DiarizationConfig.default
        let storedCount = UserDefaults.standard.integer(forKey: "targetSpeakerCount")
        diarConfig.targetSpeakerCount = storedCount > 0 ? storedCount : nil

        guard !Task.isCancelled else { return .failure(.cancelled) }
        let diarizationOutcome = await withTaskCancellationHandler(operation: {
            await diarizationService.diarize(
            wavURL: extractionResult.audioURL,
            duration: extractionResult.duration,
            config: diarConfig,
            progressHandler: { p in
                await progress(PipelineProgress(phase: .detectingSpeakers,
                                                fraction: 0.33 + 0.33 * p,
                                                message: "Detecting speakers... \(Int(p * 100))%"))
            }
            )
        }, onCancel: {
            Task { await diarizationService.cancel() }
        })
        let diarization: DiarizationResult
        switch diarizationOutcome {
        case .success(let res):
            diarization = res
        case .failure(let err):
            await progress(PipelineProgress(phase: .failed, fraction: 0.33,
                                            message: err.errorDescription ?? "Diarization failed"))
            return .failure(.diarizationFailed(err.errorDescription ?? "unknown"))
        }

        await progress(PipelineProgress(phase: .detectingSpeakers, fraction: 0.66,
                                        message: "Speakers detected"))

        // Build speaker objects + diarization segments for the ASR alignment step.
        let speakers: [Speaker] = diarization.speakerIDs.map { id in
            Speaker(id: id, name: id)
        }

        // ---- Phase 3: ASR Transcription (~66% -> ~100%) --------------------
        await progress(PipelineProgress(phase: .transcribingText, fraction: 0.66,
                                        message: "Transcribing text..."))

        var config = TranscriptionConfig()
        config.language = project.targetLanguage

        // TranscribeService applies the prompt after resolving the decoding language.

        guard !Task.isCancelled else { return .failure(.cancelled) }
        let transcriptionOutcome = await withTaskCancellationHandler(operation: {
            await transcribeService.transcribe(
            wavURL: extractionResult.audioURL,
            diarization: diarization.segments,
            config: config,
            progressHandler: { p in
                await progress(PipelineProgress(phase: .transcribingText,
                                                fraction: 0.66 + 0.34 * p,
                                                message: "Transcribing text... \(Int(p * 100))%"))
            }
            )
        }, onCancel: {
            Task { await transcribeService.cancel() }
        })
        let transcription: TranscriptionResult
        switch transcriptionOutcome {
        case .success(let res):
            transcription = res
        case .failure(let err):
            await progress(PipelineProgress(phase: .failed, fraction: 0.66,
                                            message: err.errorDescription ?? "Transcription failed"))
            return .failure(.transcriptionFailed(err.errorDescription ?? "unknown"))
        }

        await progress(PipelineProgress(phase: .done, fraction: 1.0,
                                        message: "Transcription complete"))

        try? FileManager.default.removeItem(at: extractionResult.audioURL)
        return .success(PipelineResult(
            audioURL: nil,
            audioDuration: extractionResult.duration,
            speakers: speakers,
            segments: transcription.segments,
            detectedLanguage: transcription.detectedLanguage
        ))
    }

    // MARK: - Cancel
    /// Propagates cancellation to all three services.
    func cancelAll() async {
        await audioService.cancelExtraction()
        await diarizationService.cancel()
        await transcribeService.cancel()
    }
}
