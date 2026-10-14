//  Views.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import SwiftUI

// MARK: - Settings View
struct SettingsView: View {
    @State private var showCatalogSheet = false
    @AppStorage(AppSettings.preferUrduOverHindi) private var preferUrduOverHindi = true
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Language packs")) {
                    Button(action: { showCatalogSheet = true }) {
                        HStack {
                            Label("Manage language packs", systemImage: "square.stack.3d.up.fill")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Write Urdu/Hindi speech in Urdu script (اردو)", isOn: $preferUrduOverHindi)
                    Text("In Auto Detect, turn this off to use Hindi Devanagari script (हिन्दी) for Urdu/Hindi speech.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section(header: Text("App Information")) {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                }
                
                Section(header: Text("About")) {
                    Text("© 2026 VidToScript. High-Performance On-Device Video Transcription & Diarization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showCatalogSheet) {
                LanguagePackManagerView()
            }
        }
    }
}

// MARK: - Project Processing View
/// Drives the sequential transcription pipeline and reports coarse phase
/// progress (Extracting Audio -> Detecting Speakers -> Transcribing Text -> Done).
struct ProjectProcessingView: View {
    let project: VideoProject
    @Environment(DependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: TranscriptionPipelineCoordinator?

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                if isInProgress {
                    Circle()
                        .stroke(phaseColor.opacity(0.3), lineWidth: 4)
                        .frame(width: 140, height: 140)
                        .scaleEffect(liveProgress > 0 ? 1.2 : 0.8)
                        .opacity(liveProgress > 0 ? 0 : 1)
                        .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: liveProgress)
                }
                
                Image(systemName: phaseIcon)
                    .font(.system(size: 72))
                    .foregroundStyle(phaseColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: isInProgress)
            }
            .padding(.top, 40)

            Text(phaseTitle)
                .font(.title2)
                .fontWeight(.bold)

            if isInProgress {
                ProgressView(value: liveProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                Text("\(Int(liveProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if liveStatus == .ready || liveStatus == .editing {
                Text("\(project.segments.count) segments")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if liveStatus == .error || liveStatus == .cancelled {
                Text(project.errorMessage ?? (liveStatus == .cancelled ? "The transcription was cancelled." : "The transcription could not be completed."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                if liveStatus == .ready || liveStatus == .editing {
                    NavigationLink(destination: TimelineEditorView(project: project)) {
                        Text("View Transcript")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if isInProgress {
                    Button("Cancel", role: .destructive) {
                        Task { await coordinator?.cancelAll() }
                        Task { await dependencies.jobQueue.cancelWait(id: project.id) }
                        ProjectProgressStore.shared.activeTasks[project.id]?.cancel()
                    }
                    .buttonStyle(.bordered)
                } else if liveStatus == .error || liveStatus == .cancelled {
                    Button("Retry") {
                        project.status = .importing
                        project.errorMessage = nil
                        project.progress = 0
                        ProjectProgressStore.shared.statuses[project.id] = .importing
                        ProjectProgressStore.shared.progresses[project.id] = 0
                        runPipeline()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Back to Projects") {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(30)
        .navigationTitle("Processing")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            if project.status == .draft || project.status == .importing || project.status == .queued {
                runPipeline()
            }
        }
    }

    // MARK: - Derived
    private var liveStatus: ProjectStatus {
        ProjectProgressStore.shared.statuses[project.id] ?? project.status
    }
    
    private var liveProgress: Double {
        ProjectProgressStore.shared.progresses[project.id] ?? project.progress
    }

    private var phaseTitle: String {
        if liveStatus == .error { return "Failed" }
        if liveStatus == .cancelled { return "Cancelled" }
        if liveStatus == .ready || liveStatus == .editing { return "Transcription Complete" }
        return liveStatus.displayName
    }
    private var phaseIcon: String {
        switch liveStatus {
        case .extractingAudio: return "waveform"
        case .detectingSpeakers: return "person.2.fill"
        case .transcribing: return "text.bubble.fill"
        case .ready, .editing: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        default: return "waveform"
        }
    }
    private var phaseColor: Color {
        switch liveStatus {
        case .ready, .editing: return .green
        case .error: return .red
        case .cancelled: return .secondary
        default: return .blue
        }
    }
    private var isInProgress: Bool {
        liveStatus.isProcessing
    }

    // MARK: - Pipeline
    private func runPipeline() {
        if ProjectProgressStore.shared.activeTasks[project.id] != nil { return }
        if liveStatus == .ready || liveStatus == .editing || liveStatus == .error || liveStatus == .cancelled { return }
        let selectedModel = UserDefaults.standard.string(forKey: AppSettings.selectedModelFilename)
            ?? AppSettings.defaultModelFilename
        guard let modelURL = TranscribeService.locateBundledModel(preferredModelFilename: selectedModel),
              modelURL.lastPathComponent == selectedModel else {
            project.status = .error
            project.errorMessage = "Required language pack is not downloaded. Download it in Settings."
            ProjectProgressStore.shared.statuses[project.id] = .error
            return
        }
        ProjectProgressStore.shared.activeProjects[project.id] = project
        project.status = .queued
        ProjectProgressStore.shared.statuses[project.id] = .queued

        let task = Task {
            await MainActor.run {
                // A foreground transcription is compute-bound and cannot be
                // checkpointed midway through whisper_full. Keep the display
                // awake while the serial job is active rather than pretending
                // that iOS will continue arbitrary CPU work after suspension.
                IdleTimerManager.shared.retainTimer()
            }
            defer {
                Task { @MainActor in
                    IdleTimerManager.shared.releaseTimer()
                }
            }
            let coord = dependencies.makePipelineCoordinator()
            let pipelineProject = await MainActor.run { PipelineProject(project) }
            await MainActor.run { coordinator = coord }

            let queuedOutcome = await dependencies.jobQueue.run(id: project.id) {
                await coord.run(for: pipelineProject) { p in
                let shouldPersist = await MainActor.run {
                    // Whisper callbacks are asynchronous and can arrive after a
                    // coarse stage update. Never move progress backwards.
                    guard project.status.isProcessing else { return false }
                    let oldFraction = project.progress
                    let fraction = max(oldFraction, p.fraction)
                    project.progress = fraction
                    ProjectProgressStore.shared.progresses[project.id] = fraction
                    ProjectProgressStore.shared.statuses[project.id] = p.phase.toProjectStatus()
                    let currentPercent = Int(fraction * 100)
                    let previousPercent = Int(oldFraction * 100)
                    return p.fraction == 1.0 || (currentPercent / 5) > (previousPercent / 5)
                }
                
                if shouldPersist {
                    let snapshot = await MainActor.run { ProjectSnapshot(project) }
                    try? await dependencies.projectRepository.syncRuntimeProject(snapshot)
                }
                }
            }

            await MainActor.run {
                guard let outcome = queuedOutcome else {
                    project.status = .cancelled
                    project.errorMessage = nil
                    ProjectProgressStore.shared.statuses[project.id] = .cancelled
                    ProjectProgressStore.shared.progresses.removeValue(forKey: project.id)
                    ProjectProgressStore.shared.activeTasks[project.id] = nil
                    ProjectProgressStore.shared.activeProjects[project.id] = nil
                    return
                }
                switch outcome {
                case .success(let res):
                    project.audioFileURL = res.audioURL
                    project.duration = res.audioDuration
                    project.segments = res.segments
                    project.detectedLanguage = res.detectedLanguage
                    project.status = .ready
                    project.errorMessage = nil
                    ProjectProgressStore.shared.progresses[project.id] = 1.0
                    ProjectProgressStore.shared.statuses[project.id] = .ready
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failure(let error):
                    if error == .cancelled {
                        project.status = .cancelled
                        project.errorMessage = nil
                        ProjectProgressStore.shared.statuses[project.id] = .cancelled
                    } else {
                        project.status = .error
                        project.errorMessage = error.errorDescription
                        ProjectProgressStore.shared.statuses[project.id] = .error
                    }
                    project.progress = 0
                    ProjectProgressStore.shared.progresses[project.id] = 0
                }
                ProjectProgressStore.shared.activeTasks[project.id] = nil
                ProjectProgressStore.shared.activeProjects[project.id] = nil
            }
            let snapshot = await MainActor.run { ProjectSnapshot(project) }
            try? await dependencies.projectRepository.syncRuntimeProject(snapshot)
            await MainActor.run { ProjectProgressStore.shared.prune(projectID: project.id) }
        }
        ProjectProgressStore.shared.activeTasks[project.id] = task
    }
}

// MARK: - Info Row
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}
