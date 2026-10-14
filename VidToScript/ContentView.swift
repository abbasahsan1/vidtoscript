//  ContentView.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import SwiftUI
import SwiftData
import AVFoundation

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, UIImage>()
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

struct ContentView: View {
    // MARK: - Environment
    @Environment(DependencyContainer.self) private var dependencies
    
    // MARK: - State
    @State private var selectedTab: Tab = .projects
    
    // MARK: - Body
    var body: some View {
        TabView(selection: $selectedTab) {
            // 1. Projects Tab (Main Home Experience)
            ProjectsView()
                .tabItem {
                    Label("Projects", systemImage: "folder.fill")
                }
                .tag(Tab.projects)
            
            // 2. Settings Tab
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(Tab.settings)
        }
        .tint(.blue)
    }
    
    // MARK: - Types
    private enum Tab: Hashable {
        case projects
        case settings
    }
}

// MARK: - Projects View (Unified Main Home Screen)
struct ProjectsView: View {
    @Environment(DependencyContainer.self) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \PersistedProject.creationDate, order: .reverse) private var projects: [PersistedProject]
    
    @State private var searchText = ""
    @State private var showNewTranscriptionSheet = false
    @State private var showDeleteConfirmation = false
    @State private var projectToDelete: PersistedProject?
    @State private var showRenameSheet = false
    @State private var projectToRename: PersistedProject?
    @State private var newProjectTitle = ""
    
    // Navigation for newly created modal project
    @State private var navigationPath = NavigationPath()
    
    var filteredProjects: [PersistedProject] {
        if searchText.isEmpty {
            return projects
        }
        return projects.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText) ||
            ($0.targetLanguage?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if projects.isEmpty {
                    EmptyProjectsView(onStartImport: {
                        showNewTranscriptionSheet = true
                    })
                } else {
                    ProjectsListView(
                        projects: filteredProjects,
                        onDelete: { project in
                            projectToDelete = project
                            showDeleteConfirmation = true
                        },
                        onRename: { project in
                            projectToRename = project
                            newProjectTitle = project.displayTitle
                            showRenameSheet = true
                        }
                    )
                }
            }
            .navigationTitle("Projects")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects...")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showNewTranscriptionSheet = true }) {
                        Image(systemName: "plus")
                            .font(.headline)
                    }
                    .accessibilityLabel("New Transcription")
                }
            }
            .sheet(isPresented: $showNewTranscriptionSheet) {
                NewTranscriptionSheet { createdProject in
                    navigationPath.append(createdProject.id)
                }
            }
            .navigationDestination(for: UUID.self) { projectID in
                if let project = projects.first(where: { $0.id == projectID }) {
                    ProjectDetailView(project: project)
                } else {
                    ProgressView("Loading workspace...")
                }
            }
        }
        .alert(
            "Delete Project?",
            isPresented: $showDeleteConfirmation,
            presenting: projectToDelete
        ) { project in
            Button("Delete", role: .destructive) {
                deleteProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text("Are you sure you want to delete '\(project.displayTitle)'? This cannot be undone.")
        }
        .sheet(isPresented: $showRenameSheet) {
            NavigationStack {
                Form {
                    Section("Project Title") {
                        TextField("Enter title", text: $newProjectTitle)
                    }
                }
                .navigationTitle("Rename Project")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showRenameSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let project = projectToRename, !newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                renameProject(project, newTitle: newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            showRenameSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.height(200)])
        }
        .task {
            await importPendingSharedVideos()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await importPendingSharedVideos() } }
        }
    }
    
    private func deleteProject(_ project: PersistedProject) {
        let projectID = project.id
        ProjectProgressStore.shared.activeTasks[projectID]?.cancel()
        ProjectProgressStore.shared.prune(projectID: projectID)
        Task {
            try? await dependencies.projectRepository.deleteProject(byID: projectID)
        }
    }

    @MainActor
    private func importPendingSharedVideos() async {
        guard let defaults = AppSettings.sharedDefaults else { return }
        var paths = defaults.stringArray(forKey: AppSettings.SharedKey.pendingSharedVideoPaths) ?? []
        if let legacy = defaults.string(forKey: AppSettings.SharedKey.pendingSharedVideoURL) { paths.append(legacy) }
        guard !paths.isEmpty else { return }
        defaults.removeObject(forKey: AppSettings.SharedKey.pendingSharedVideoPaths)
        defaults.removeObject(forKey: AppSettings.SharedKey.pendingSharedVideoURL)
        for path in paths {
        let sourceURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            continue
        }
        let projectID = UUID()
        do {
            let destination = try await dependencies.storageService.saveVideoFile(from: sourceURL, for: projectID)
            let title = sourceURL.deletingPathExtension().lastPathComponent
            let preferredLanguage = UserDefaults.standard.string(forKey: AppSettings.lastSelectedLanguage) ?? "ur"
            let persisted = PersistedProject(id: projectID, title: title, videoFilePath: destination.path,
                                             status: .importing, targetLanguage: preferredLanguage)
            modelContext.insert(persisted)
            try modelContext.save()
            try? FileManager.default.removeItem(at: sourceURL)
            navigationPath.append(projectID)
        } catch {
            AppLogger.shared.error("Could not import shared video: \(error.localizedDescription)", category: .storage)
        }
        }
    }
    
    private func renameProject(_ project: PersistedProject, newTitle: String) {
        project.title = newTitle
        project.lastModifiedDate = Date()
        try? modelContext.save()
    }
}


// MARK: - Empty Projects View
struct EmptyProjectsView: View {
    var onStartImport: () -> Void = {}
    
    var body: some View {
        ContentUnavailableView {
            Label("No Projects Yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Import a video to get started with high-accuracy transcription & speaker detection.")
        } actions: {
            Button(action: onStartImport) {
                Label("New Transcription", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Projects List View
struct ProjectsListView: View {
    let projects: [PersistedProject]
    let onDelete: (PersistedProject) -> Void
    let onRename: (PersistedProject) -> Void
    
    var body: some View {
        List {
            ForEach(projects) { project in
                NavigationLink(value: project.id) {
                    ProjectRowView(project: project)
                }
                .contextMenu {
                    Button(action: { onRename(project) }) {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: { onDelete(project) }) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    onDelete(projects[index])
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Project Row View
struct ProjectRowView: View {
    let project: PersistedProject
    @State private var thumbnailImage: Image?
    
    private var liveStatus: ProjectStatus {
        ProjectProgressStore.shared.statuses[project.id] ?? project.status
    }
    
    private var liveProgress: Double {
        ProjectProgressStore.shared.progresses[project.id] ?? project.progress
    }
    
    var statusColor: Color {
        switch liveStatus {
        case .draft, .cancelled:
            return .gray
        case .queued, .importing, .extractingAudio, .processingAudio, .detectingSpeakers, .transcribing:
            return .blue
        case .ready, .editing:
            return .green
        case .exporting:
            return .orange
        case .error:
            return .red
        }
    }
    
    var body: some View {
        HStack(spacing: 14) {
            // Video Thumbnail Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 48, height: 48)
                
                if let thumbnailImage {
                    thumbnailImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "play.rectangle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
            }
            .task {
                await generateThumbnail()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(project.displayTitle)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    // Status Badge
                    HStack(spacing: 4) {
                        if liveStatus == .importing || liveStatus == .transcribing || liveStatus == .extractingAudio || liveStatus == .processingAudio || liveStatus == .detectingSpeakers {
                            ProgressView()
                                .controlSize(.mini)
                            Text("\(liveStatus.displayName)... \(Int(liveProgress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text(liveStatus.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    // Duration Badge
                    if liveStatus == .ready || liveStatus == .editing || liveStatus == .exporting {
                        Text(formatDuration(project.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Language Tag
                    Text((project.detectedLanguage ?? project.targetLanguage ?? "UR").uppercased())
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            
            Spacer()
            
            Text(formatDate(project.creationDate))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "0:00" }
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated; return formatter
    }()
    private func formatDate(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
    
    private func generateThumbnail() async {
        guard let url = project.videoFileURL else { return }
        if let image = ThumbnailCache.shared.image(for: url) {
            thumbnailImage = Image(uiImage: image)
            return
        }
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 100, height: 100)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            let image = UIImage(cgImage: cgImage)
            ThumbnailCache.shared.set(image, for: url)
            self.thumbnailImage = Image(uiImage: image)
        } catch { }
    }
}

// MARK: - Project Detail View
struct ProjectDetailView: View {
    let project: PersistedProject
    @Environment(DependencyContainer.self) private var dependencies
    @State private var runtimeProject: VideoProject?
    
    var body: some View {
        Group {
            if let runtimeProject {
                if runtimeProject.status.isProcessing || runtimeProject.status == .error {
                    ProjectProcessingView(project: runtimeProject)
                } else {
                    TimelineEditorView(project: runtimeProject)
                        .onDisappear {
                            Task {
                                let snapshot = await MainActor.run { ProjectSnapshot(runtimeProject) }
                                try? await dependencies.projectRepository.syncRuntimeProject(snapshot)
                            }
                        }
                }
            } else {
                ProgressView("Loading transcript...")
                    .onAppear {
                        runtimeProject = ProjectProgressStore.shared.activeProjects[project.id]
                            ?? VideoProject(from: project)
                    }
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}
