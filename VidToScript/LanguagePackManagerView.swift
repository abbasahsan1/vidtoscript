//  LanguagePackManagerView.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import SwiftUI

struct LanguagePackManagerView: View {
    @State private var manager = LanguagePackManager.shared
    @AppStorage(AppSettings.selectedModelFilename) private var selectedModelFilename: String = "ggml-large-v3-turbo.bin"
    @State private var packToDelete: LanguagePack?
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationStack {
            List {
                Section(
                    header: Text("Offline Language Packs"),
                    footer: Text("Downloaded language packs are stored locally on your device for fast offline transcription.")
                ) {
                    ForEach(manager.packs) { pack in
                        LanguagePackRow(
                            pack: pack,
                            isSelected: selectedModelFilename == pack.fileName,
                            onSelect: {
                                selectedModelFilename = pack.fileName
                            },
                            onDownload: {
                                manager.download(pack: pack)
                            },
                            onDeleteRequest: {
                                packToDelete = pack
                                showDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
            .navigationTitle("Language Packs")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete Language Pack?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pack = packToDelete {
                        manager.delete(pack: pack)
                        if selectedModelFilename == pack.fileName {
                            selectedModelFilename = manager.packs.first(where: {
                                $0.status == .installed && $0.fileName != pack.fileName
                            })?.fileName ?? "ggml-base-q8_0.bin"
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let pack = packToDelete {
                    Text("Are you sure you want to delete '\(pack.displayName)'? You can re-download it at any time.")
                }
            }
        }
    }
}

struct LanguagePackRow: View {
    let pack: LanguagePack
    let isSelected: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDeleteRequest: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(pack.tierName)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                    
                    if isSelected {
                        Text("ACTIVE")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                
                Text(pack.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("\(pack.sizeInMB) MB • High Accuracy Offline Pack")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            switch pack.status {
            case .notInstalled:
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
            case .downloading(let progress):
                VStack(spacing: 4) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 60)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
            case .installed:
                HStack(spacing: 8) {
                    if !isSelected {
                        Button("Use", action: onSelect)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    
                    Button(action: onDeleteRequest) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
