//  VidToScriptApp.swift
//  VidToScript
//
//  Created by abbas on 23/07/2026.
//

import SwiftUI
import SwiftData
import Darwin

@main
struct VidToScriptApp: App {
    let container: ModelContainer?
    let dependencies: DependencyContainer?
    
    init() {
        let resolvedContainer: ModelContainer?
        let resolvedDependencies: DependencyContainer?
        do {
            let schema = Schema([PersistedProject.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            // Never delete a user's store as a migration recovery strategy.
            // SwiftData performs compatible lightweight migrations; incompatible
            // changes must ship with an explicit versioned migration plan.
            let sharedContainer = try ModelContainer(for: schema, configurations: [config])

            let storageService = try StorageService()
            let audioExtractionService = AudioExtractionService()
            let projectRepository = ProjectRepository(storageService: storageService, modelContainer: sharedContainer)
            let dependencies = DependencyContainer(
                storageService: storageService,
                audioExtractionService: audioExtractionService,
                projectRepository: projectRepository
            )
            resolvedContainer = sharedContainer
            resolvedDependencies = dependencies
            Task { await projectRepository.reconcileInterruptedProjects() }
            
            AppLogger.shared.info("App initialized successfully", category: .general)
            AppLogger.shared.info("Whisper model: \(TranscribeService.locateBundledModel()?.lastPathComponent ?? "NOT FOUND")", category: .transcription)
        } catch {
            // Do not erase a user's store or terminate on migration failure.
            // The screen below preserves the data until a recovery build or
            // support workflow can inspect it.
            resolvedContainer = nil
            resolvedDependencies = nil
            AppLogger.shared.error("Unable to open the project store: \(error.localizedDescription)", category: .storage)
        }
        self.container = resolvedContainer
        self.dependencies = resolvedDependencies
    }
    
    @State private var isInitializing = true
    @State private var splashOpacity = 1.0
    
    var body: some Scene {
        WindowGroup {
            if let container, let dependencies {
                ZStack {
                    ContentView()
                        .environment(dependencies)

                    if isInitializing {
                        AnimatedSplashScreen()
                            .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                            .opacity(splashOpacity)
                    }
                }
                .task { withAnimation { isInitializing = false } }
                .modelContainer(container)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 50)).foregroundStyle(.red)
                    Text("Database Migration Error").font(.title2).bold()
                    Text("VidToScript could not open the project store. Resetting local metadata preserves media in Documents/Projects.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Reset Database & Reopen", role: .destructive) {
                        let manager = FileManager.default
                        let roots = [
                            manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                            manager.urls(for: .documentDirectory, in: .userDomainMask).first
                        ].compactMap { $0 }
                        for root in roots {
                            let store = root.appendingPathComponent("default.store")
                            try? manager.removeItem(at: store)
                            try? manager.removeItem(at: store.appendingPathExtension("wal"))
                            try? manager.removeItem(at: store.appendingPathExtension("shm"))
                        }
                        exit(0)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }
}
