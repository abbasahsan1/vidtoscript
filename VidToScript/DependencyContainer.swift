//  DependencyContainer.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import SwiftUI

/// Limits heavyweight model inference to one project at a time. This avoids
/// two simultaneous Whisper contexts competing for multi-gigabyte memory.
actor PipelineJobQueue {
    private var isRunning = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// Returns nil when this specific job was cancelled while waiting. Running
    /// work is never resumed or cancelled on behalf of another project.
    func run<T: Sendable>(id: UUID, _ operation: @Sendable () async -> T) async -> T? {
        let acquired = await withTaskCancellationHandler(operation: {
            await acquire(id: id)
        }, onCancel: {
            Task { await self.cancelWait(id: id) }
        })
        guard acquired else { return nil }
        guard !Task.isCancelled else {
            release()
            return nil
        }
        defer { release() }
        return await operation()
    }

    private func acquire(id: UUID) async -> Bool {
        if !isRunning { isRunning = true; return true }
        return await withCheckedContinuation { continuation in
            waiters.append((id: id, continuation: continuation))
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            isRunning = false
        }
    }

    func cancelWait(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

// MARK: - Dependency Container
/// Application-wide dependency wiring. Holds long-lived service *protocols*
/// (no model state) plus factories for the per-run pipeline coordinator.
///
/// RAM note: the heavy ML services (`SpeakerDiarizationService`,
/// `TranscribeService`) are `actor`s created fresh for each transcription run
/// by the coordinator, so their model memory is allocated and released per phase.
@Observable
final class DependencyContainer: Sendable {
    let storageService: any StorageServiceProtocol
    let audioExtractionService: any AudioExtractionServiceProtocol
    let projectRepository: any ProjectRepositoryProtocol
    let jobQueue: PipelineJobQueue

    init(
        storageService: any StorageServiceProtocol,
        audioExtractionService: any AudioExtractionServiceProtocol,
        projectRepository: any ProjectRepositoryProtocol,
        jobQueue: PipelineJobQueue = PipelineJobQueue()
    ) {
        self.storageService = storageService
        self.audioExtractionService = audioExtractionService
        self.projectRepository = projectRepository
        self.jobQueue = jobQueue
    }

    /// Each job owns its cancellation-aware processing actors. No state leaks
    /// across projects when one queued or running job is cancelled.
    func makePipelineCoordinator() -> TranscriptionPipelineCoordinator {
        TranscriptionPipelineCoordinator(
            audioService: AudioExtractionService(),
            diarizationService: SpeakerDiarizationService(),
            transcribeService: TranscribeService()
        )
    }
}
