//  NewTranscriptionSheet.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import SwiftData

struct NewTranscriptionSheet: View {
    // MARK: - Environment & State
    @Environment(DependencyContainer.self) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage(AppSettings.selectedModelFilename) private var selectedModelFilename: String = "ggml-large-v3-turbo.bin"
    @AppStorage(AppSettings.targetSpeakerCount) private var targetSpeakerCount: Int = 0
    
    let onProjectCreated: (VideoProject) -> Void
    
    // Video selection state
    @State private var selectedVideoURL: URL?
    @State private var selectedVideoTitle: String = ""
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var isProcessingVideo = false
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    
    // Configuration state
    @AppStorage(AppSettings.lastSelectedLanguage) private var storedLanguage = "ur"
    @State private var selectedLanguage: SupportedLanguage = SupportedLanguage.all.first(where: { $0.id == "ur" }) ?? SupportedLanguage.all[0]
    
    var body: some View {
        NavigationStack {
            Form {
                // Section 1: Video File Selection
                Section(header: Text("Select Video")) {
                    if let selectedVideoURL {
                        HStack(spacing: 12) {
                            Image(systemName: "video.fill")
                                .font(.title2)
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedVideoTitle)
                                    .font(.headline)
                                    .lineLimit(1)
                                
                                Text("Ready for transcription")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }

                            Spacer()
                            
                            Button(role: .destructive) {
                                self.selectedVideoURL = nil
                                self.selectedVideoTitle = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack(spacing: 12) {
                            Button(action: { showPhotoPicker = true }) {
                                HStack {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .foregroundStyle(Color.accentColor)
                                    Text("Photos")
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                .cornerRadius(12)
                            }
                            .buttonStyle(CompactMediaButtonStyle())
                            
                            Button(action: { showFilePicker = true }) {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(Color.accentColor)
                                    Text("Files")
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                .cornerRadius(12)
                            }
                            .buttonStyle(CompactMediaButtonStyle())
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                }
                
                // Section 2: Configuration Options
                Section(header: Text("Transcription Settings")) {
                    // Language Selection
                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(SupportedLanguage.all) { lang in
                            HStack {
                                Label(lang.name, systemImage: lang.icon)
                                Spacer()
                                Text(lang.code)
                                    .font(.caption2)
                                    .fontWeight(.bold)
                            }
                            .tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    // Transcription Quality Selection
                    Picker("Transcription quality", selection: $selectedModelFilename) {
                        Text("Highest Accuracy (might take longer)").tag("ggml-large-v3-turbo.bin")
                        Text("Balanced (a balance between accuracy and speed)").tag("ggml-small-q8_0.bin")
                        Text("Fast").tag("ggml-base-q8_0.bin")
                    }
                    .pickerStyle(.menu)
                    
                    // Speaker Detection Selection
                    Picker("Speaker detection", selection: $targetSpeakerCount) {
                        Text("1 Speaker").tag(1)
                        Text("2 Speakers").tag(2)
                        Text("3 Speakers").tag(3)
                        Text("4 Speakers").tag(4)
                        Text("Auto Detect").tag(0)
                    }
                    .pickerStyle(.menu)
                }
                
                // Section 3: Submit Action Button
                Section {
                    Button(action: startTranscription) {
                        HStack {
                            Spacer()
                            if isProcessingVideo {
                                ProgressView()
                                    .tint(.white)
                                    .padding(.trailing, 8)
                                Text(statusMessage.isEmpty ? "Preparing..." : statusMessage)
                                    .fontWeight(.semibold)
                            } else {
                                Image(systemName: "sparkles")
                                Text("Start Transcription")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(selectedVideoURL == nil || isProcessingVideo)
                    .listRowBackground(selectedVideoURL != nil ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundStyle(.white)
                }
            }
            .navigationTitle("New Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photosPickerItem,
                matching: .videos
            )
            .onChange(of: photosPickerItem) { _, newItem in
                if newItem != nil {
                    Task { await handlePhotoSelection(newItem) }
                }
            }
            .alert("Video Import Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Could not load video file.")
            }
        }
        .onAppear {
            selectedLanguage = SupportedLanguage.all.first(where: { $0.id == storedLanguage })
                ?? SupportedLanguage.all.first(where: { $0.id == "ur" })
                ?? SupportedLanguage.all[0]
        }
    }
    
    // MARK: - Handlers
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            self.selectedVideoURL = url
            self.selectedVideoTitle = url.deletingPathExtension().lastPathComponent
        case .failure(let error):
            self.errorMessage = error.localizedDescription
            self.showErrorAlert = true
        }
    }
    
    private func handlePhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        await MainActor.run {
            isProcessingVideo = true
            statusMessage = "Loading from Photos..."
        }
        
        do {
            if let movie = try await item.loadTransferable(type: Movie.self) {
                await MainActor.run {
                    self.selectedVideoURL = movie.url
                    self.selectedVideoTitle = "Photo Video"
                    self.isProcessingVideo = false
                    self.photosPickerItem = nil
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "Could not load video from photo library"
                    self.showErrorAlert = true
                    self.isProcessingVideo = false
                    self.photosPickerItem = nil
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to export video: \(error.localizedDescription)"
                self.showErrorAlert = true
                self.isProcessingVideo = false
                self.photosPickerItem = nil
            }
        }
    }
    
    private func startTranscription() {
        guard let videoURL = selectedVideoURL else { return }
        storedLanguage = selectedLanguage.id
        let selectedModel = selectedModelFilename
        guard let modelURL = TranscribeService.locateBundledModel(preferredModelFilename: selectedModel),
              modelURL.lastPathComponent == selectedModel else {
            errorMessage = "The language pack (\(selectedModel)) is not downloaded yet. Please download it from Settings before starting."
            showErrorAlert = true
            return
        }
        
        Task {
            await MainActor.run {
                isProcessingVideo = true
                statusMessage = "Saving video workspace..."
            }
            
            do {
                let projectID = UUID()
                let savedURL = try await dependencies.storageService.saveVideoFile(from: videoURL, for: projectID)
                
                let title = selectedVideoTitle.isEmpty || selectedVideoTitle.hasPrefix("imported_")
                    ? "Video \(Date().formatted(date: .abbreviated, time: .shortened))"
                    : selectedVideoTitle
                
                let newProject = VideoProject(
                    id: projectID,
                    title: title,
                    videoFileURL: savedURL,
                    targetLanguage: selectedLanguage.id
                )
                
                let persisted = PersistedProject(
                    id: projectID,
                    title: title,
                    videoFilePath: savedURL.path,
                    creationDate: Date(),
                    status: .importing,
                    targetLanguage: selectedLanguage.id
                )
                modelContext.insert(persisted)
                try? modelContext.save()
                
                await MainActor.run {
                    isProcessingVideo = false
                    dismiss()
                    onProjectCreated(newProject)
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to save video: \(error.localizedDescription)"
                    showErrorAlert = true
                    isProcessingVideo = false
                }
            }
        }
    }
}

struct CompactMediaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
