//  TimelineEditorView.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import SwiftUI
import AVKit
import NaturalLanguage

private func contentLayoutDirection(for text: String) -> LayoutDirection {
    guard let scalar = text.unicodeScalars.first(where: {
        !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
    }) else { return .leftToRight }
    return (0x0590...0x08FF).contains(scalar.value) ? .rightToLeft : .leftToRight
}

struct TimelineEditorView: View {
    @Environment(DependencyContainer.self) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var project: VideoProject
    
    enum TabSelection {
        case transcript, summary
    }
    
    @State private var selectedTab: TabSelection = .transcript
    @State private var isVerbatimMode: Bool = true
    @State private var showExportSheet = false
    @State private var showSpeakerRenameSheet = false
    @State private var showTitleRenameSheet = false
    @State private var newProjectTitle: String = ""
    @State private var speakerToRename: String?
    @State private var newSpeakerName: String = ""
    @State private var selectedSegments = Set<UUID>()
    @State private var exportedFile: ExportedFile?
    @State private var mergeErrorMessage: String?
    @State private var showMergeErrorAlert = false
    
    // AVPlayer & Real-Time Sync State
    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0.0
    @State private var activeSegmentID: UUID?
    @State private var playerObserverToken: Any?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var isScrubbing = false
    
    // Exporter service
    private let exporter = TranscriptExporterService()
    private let postProcessor = TranscriptPostProcessorService()
    @State private var summaryResult: SummaryResult?
    @State private var summaryTask: Task<Void, Never>?
    @State private var autosaveTask: Task<Void, Never>?
    
    var body: some View {
        VStack(spacing: 0) {
            // Video / Audio Playback Controls Card
            playbackControlBar
            
            // View Mode Picker
            Picker("View Mode", selection: $selectedTab) {
                Text("Transcript").tag(TabSelection.transcript)
                Text("Summary & Action Items").tag(TabSelection.summary)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            if selectedTab == .transcript {
                transcriptTab
            } else {
                summaryTab
            }
        }
        .navigationTitle(project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .alert("Merge Failed", isPresented: $showMergeErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mergeErrorMessage ?? "Selected segments could not be merged.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: {
                    newProjectTitle = project.displayTitle
                    showTitleRenameSheet = true
                }) {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Rename Project")
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let language = project.detectedLanguage {
                        let name = SupportedLanguage.all.first { $0.id == language }?.name ?? language.uppercased()
                        Text("Transcript language: \(name)")
                    }
                    Menu {
                        ForEach(SupportedLanguage.all.filter { $0.id != "auto" }) { language in
                            Button(action: { rerunWithLanguage(language.id) }) {
                                Label(language.name, systemImage: language.icon)
                            }
                        }
                    } label: {
                        Label("Re-run in Language...", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Toggle(isOn: $isVerbatimMode) {
                        Label("Verbatim Mode", systemImage: "text.quote")
                    }
                    
                    Button(action: { showExportSheet = true }) {
                        Label("Export Transcript", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            
            if selectedSegments.count > 1 && selectedTab == .transcript {
                ToolbarItem(placement: .bottomBar) {
                    Button("Merge Selected (\(selectedSegments.count))") {
                        mergeSelectedSegments()
                    }
                }
            }
        }
        .onAppear {
            isVerbatimMode = project.isVerbatim
            updateActiveSegment(at: currentTime)
            setupPlayer()
        }
        .onDisappear {
            autosaveTask?.cancel()
            summaryTask?.cancel()
            removePlayerObserver()
            player?.pause()
            syncProject()
        }
        .onChange(of: isVerbatimMode) { _, newValue in
            project.isVerbatim = newValue
            syncProject()
        }
        .onChange(of: project.segments) { _, _ in
            scheduleAutosave()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                autosaveTask?.cancel()
                syncProject()
            }
        }
        .sheet(isPresented: $showTitleRenameSheet) {
            NavigationStack {
                Form {
                    Section("Project Title") {
                        TextField("Title", text: $newProjectTitle)
                    }
                }
                .navigationTitle("Rename Project")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTitleRenameSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let trimmed = newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                project.title = trimmed
                                syncProject()
                            }
                            showTitleRenameSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.height(200)])
        }
        .sheet(isPresented: $showSpeakerRenameSheet) {
            NavigationStack {
                Form {
                    TextField("Speaker Name", text: $newSpeakerName)
                }
                .navigationTitle("Rename Speaker")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSpeakerRenameSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            renameSpeaker()
                            showSpeakerRenameSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.height(200)])
        }
        // Export Action Sheet / Dialog
        .confirmationDialog("Export Transcript", isPresented: $showExportSheet, titleVisibility: .visible) {
            Button("Export as Subtitles (.srt)") {
                exportProject(as: .srt)
            }
            Button("Export as WebVTT (.vtt)") {
                exportProject(as: .vtt)
            }
            Button("Export Plain Text (.txt)") {
                exportProject(as: .txt)
            }
            Button("Export Markdown (.md)") {
                exportProject(as: .md)
            }
            Button("Export PDF Document (.pdf)") {
                exportProject(as: .pdf)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Select an export format for '\(project.title)':")
        }
        .sheet(item: Binding<ExportedFileWrapper?>(
            get: { exportedFile.map { ExportedFileWrapper(file: $0) } },
            set: { wrapper in
                if wrapper == nil, let file = exportedFile {
                    try? FileManager.default.removeItem(at: file.url)
                }
                exportedFile = wrapper?.file
            }
        )) { wrapper in
            ShareSheet(activityItems: [wrapper.file.url])
        }
    }
    
    // MARK: - Playback Control Bar
    private var playbackControlBar: some View {
        HStack(spacing: 16) {
            Button(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            
            VStack(spacing: 4) {
                Slider(
                    value: $currentTime,
                    in: 0...max(project.duration, 1.0)
                ) { editing in
                    isScrubbing = editing
                    if !editing {
                        seekToTime(currentTime)
                    }
                }
                .tint(.blue)
                
                HStack {
                    Text(formatTime(currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatTime(project.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    // MARK: - Transcript Tab
    var transcriptTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach($project.segments) { $segment in
                        let isActive = activeSegmentID == segment.id
                        
                        SegmentCardView(
                            segment: $segment,
                            isSelected: selectedSegments.contains(segment.id),
                            isActive: isActive,
                            isPlaying: isPlaying,
                            // Only the active card receives the live playback
                            // clock, so dormant cards skip word-highlight work.
                            currentTime: isActive ? currentTime : 0,
                            isVerbatimMode: isVerbatimMode,
                            onSpeakerTap: {
                                speakerToRename = segment.speakerID
                                newSpeakerName = segment.speakerID
                                showSpeakerRenameSheet = true
                            },
                            onSelect: {
                                toggleSelection(for: segment.id)
                            },
                            onSplit: {
                                splitSegment(segment)
                            },
                            onTapTime: {
                                seekToTime(segment.startTime)
                            }
                        )
                        .id(segment.id)
                    }
                }
                .padding()
            }
            .onChange(of: currentTime) { _, newTime in
                let previousID = activeSegmentID
                updateActiveSegment(at: newTime)
                if isPlaying, previousID != activeSegmentID, let activeID = activeSegmentID {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(activeID, anchor: .center)
                    }
                }
            }
        }
    }
    
    // MARK: - Summary Tab
    var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let summaryResult {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Executive Summary")
                            .font(.title2)
                            .bold()
                        
                        ForEach(summaryResult.executiveSummary, id: \.self) { point in
                            HStack(alignment: .top) {
                                Text("•")
                                Text(point)
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Key Action Items")
                            .font(.title2)
                            .bold()
                        
                        ForEach(summaryResult.actionItems, id: \.self) { action in
                            HStack(alignment: .top) {
                                Image(systemName: "checkmark.square")
                                    .foregroundStyle(.green)
                                Text(action)
                            }
                        }
                        
                        if summaryResult.actionItems.isEmpty {
                            Text("No specific action items detected.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if project.segments.isEmpty {
                    ContentUnavailableView(
                        "No Summary Available",
                        systemImage: "text.clipboard",
                        description: Text("Transcribe a video with segments to generate an executive summary.")
                    )
                    .padding(.top, 40)
                } else {
                    ProgressView("Generating Summary...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding()
        }
        .onAppear {
            computeSummary()
        }
        .onChange(of: project.segments) { _, _ in
            computeSummary()
        }
    }
    
    // MARK: - Player Integration
    private func setupPlayer() {
        guard let mediaURL = project.videoFileURL ?? project.audioFileURL else { return }
        removePlayerObserver()
        let newPlayer = AVPlayer(url: mediaURL)
        self.player = newPlayer
        configurePlaybackAudioSession()
        
        let interval = CMTime(value: 1, timescale: 10) // 100ms interval for smooth word highlighting
        playerObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if !self.isScrubbing { self.currentTime = time.seconds }
        }
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: newPlayer.currentItem, queue: .main
        ) { _ in
            self.isPlaying = false
            self.currentTime = 0
            self.player?.seek(to: .zero)
        }
    }

    /// Audio-session activation can synchronously consult audio hardware.  Do
    /// that work away from SwiftUI's main-actor rendering path so presenting a
    /// transcript never hitches while the route is being configured.
    private func configurePlaybackAudioSession() {
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                AppLogger.shared.warning("Unable to activate playback audio session: \(error.localizedDescription)", category: .audio)
            }
        }
    }
    
    private func removePlayerObserver() {
        if let token = playerObserverToken {
            player?.removeTimeObserver(token)
            playerObserverToken = nil
        }
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
    }
    
    private func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if let item = player.currentItem,
               item.currentTime() >= item.duration {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }
    
    private func seekToTime(_ time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        self.currentTime = time
    }

    private func updateActiveSegment(at time: TimeInterval) {
        activeSegmentID = project.segments.first(where: {
            time >= $0.startTime && time < $0.endTime
        })?.id
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let mins = (Int(time) % 3600) / 60
        let secs = Int(time.truncatingRemainder(dividingBy: 60))
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, mins, secs)
            : String(format: "%02d:%02d", mins, secs)
    }
    
    private func computeSummary() {
        summaryTask?.cancel()
        let segmentSnapshot = project.segments
        summaryTask = Task {
            var cleanedSegments = project.segments
            postProcessor.cleanVerbatim(segments: &cleanedSegments)
            let result = await postProcessor.generateSummaryAsync(from: cleanedSegments)
            guard !Task.isCancelled, segmentSnapshot == project.segments else { return }
            await MainActor.run {
                self.summaryResult = result
            }
        }
    }
    
    private func rerunWithLanguage(_ languageID: String) {
        player?.pause()
        isPlaying = false
        autosaveTask?.cancel()
        project.targetLanguage = languageID
        project.detectedLanguage = nil
        project.status = .importing
        project.progress = 0
        project.errorMessage = nil
        ProjectProgressStore.shared.statuses[project.id] = .importing
        ProjectProgressStore.shared.progresses[project.id] = 0
        syncProject()
    }

    private func syncProject() {
        Task {
            let snapshot = await MainActor.run { ProjectSnapshot(project) }
            try? await dependencies.projectRepository.syncRuntimeProject(snapshot)
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let snapshot = await MainActor.run { ProjectSnapshot(project) }
            try? await dependencies.projectRepository.syncRuntimeProject(snapshot)
        }
    }
    
    // MARK: - Actions
    private func toggleSelection(for id: UUID) {
        if selectedSegments.contains(id) {
            selectedSegments.remove(id)
        } else {
            selectedSegments.insert(id)
        }
    }
    
    private func renameSpeaker() {
        guard let oldName = speakerToRename, !newSpeakerName.isEmpty else { return }
        for i in project.segments.indices {
            if project.segments[i].speakerID == oldName {
                project.segments[i].speakerID = newSpeakerName
            }
        }
        syncProject()
    }
    
    private func splitSegment(_ segment: TranscriptSegment) {
        guard let index = project.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        let currentSegment = project.segments[index]
        
        var midTime = currentSegment.startTime + (currentSegment.duration / 2)
        
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = currentSegment.text
        let tokenRanges = tokenizer.tokens(for: currentSegment.text.startIndex..<currentSegment.text.endIndex)
        guard tokenRanges.count >= 2 else { return }
        let midpoint = tokenRanges[tokenRanges.count / 2].lowerBound
        let firstHalfText = String(currentSegment.text[..<midpoint]).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondHalfText = String(currentSegment.text[midpoint...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let timingSplit = currentSegment.words.count >= 2 ? currentSegment.words.count / 2 : nil
        if let timingSplit {
            midTime = currentSegment.words[timingSplit].startTime
        }
        let firstWords = timingSplit.map { Array(currentSegment.words[..<$0]) } ?? []
        let secondWords = timingSplit.map { Array(currentSegment.words[$0...]) } ?? []
        
        project.segments[index].text = firstHalfText
        project.segments[index].endTime = midTime
        project.segments[index].words = firstWords
        
        let newSegment = TranscriptSegment(
            id: UUID(),
            startTime: midTime,
            endTime: currentSegment.endTime,
            speakerID: currentSegment.speakerID,
            text: secondHalfText,
            isVerbatim: currentSegment.isVerbatim,
            words: secondWords
        )
        
        project.segments.insert(newSegment, at: index + 1)
        syncProject()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func mergeSelectedSegments() {
        let selectedIDs = selectedSegments
        let segmentsToMerge = project.segments.filter { selectedIDs.contains($0.id) }
            .sorted { $0.startTime < $1.startTime }
        
        guard segmentsToMerge.count > 1, let first = segmentsToMerge.first, let last = segmentsToMerge.last else {
            selectedSegments.removeAll()
            return
        }
        
        guard segmentsToMerge.allSatisfy({ $0.speakerID == first.speakerID }) else {
            mergeErrorMessage = "Cannot merge segments from different speakers."
            showMergeErrorAlert = true
            return
        }
        guard zip(segmentsToMerge, segmentsToMerge.dropFirst()).allSatisfy({ $1.startTime <= $0.endTime + 0.5 }) else {
            mergeErrorMessage = "Cannot merge segments that are not adjacent."
            showMergeErrorAlert = true
            return
        }
        let mergedText = segmentsToMerge.map { $0.text }.joined(separator: " ")
        
        var mergedSegment = first
        mergedSegment.endTime = last.endTime
        mergedSegment.text = mergedText
        mergedSegment.words = segmentsToMerge.flatMap(\.words)
        
        project.segments.removeAll { selectedIDs.contains($0.id) }
        project.segments.append(mergedSegment)
        project.segments.sort { $0.startTime < $1.startTime }
        
        selectedSegments.removeAll()
        syncProject()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func exportProject(as format: ExportFormat) {
        let projectSnapshot = project
        let verbatim = isVerbatimMode
        let exportService = exporter
        Task.detached(priority: .userInitiated) {
            do {
                let url = try exportService.export(project: projectSnapshot, to: format, isVerbatim: verbatim)
                await MainActor.run { self.exportedFile = ExportedFile(url: url) }
            } catch {
                AppLogger.shared.error("Export failed: \(error.localizedDescription)", category: .transcription)
            }
        }
    }
}

// MARK: - Segment Card View with Real-time Word Highlighting
struct SegmentCardView: View, Equatable {
    @Binding var segment: TranscriptSegment
    let isSelected: Bool
    let isActive: Bool
    let isPlaying: Bool
    let currentTime: Double
    let isVerbatimMode: Bool
    
    let onSpeakerTap: () -> Void
    let onSelect: () -> Void
    let onSplit: () -> Void
    let onTapTime: () -> Void

    static func == (lhs: SegmentCardView, rhs: SegmentCardView) -> Bool {
        lhs.segment == rhs.segment &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isActive == rhs.isActive &&
        lhs.isPlaying == rhs.isPlaying &&
        (!lhs.isActive || abs(lhs.currentTime - rhs.currentTime) < 0.08) &&
        lhs.isVerbatimMode == rhs.isVerbatimMode
    }
    
    var body: some View {
        let displayedText = isVerbatimMode ? segment.text : filterFillers(segment.text)
        let direction = contentLayoutDirection(for: displayedText)
        VStack(alignment: direction == .rightToLeft ? .trailing : .leading, spacing: 8) {
            HStack {
                Button(action: onSpeakerTap) {
                    Text(segment.speakerID)
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(action: onTapTime) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle")
                            .font(.caption2)
                        Text("\(formatTime(segment.startTime)) - \(formatTime(segment.endTime))")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(isActive ? .blue : .secondary)
                }
                .buttonStyle(.plain)
            }
            
            if isVerbatimMode && !isPlaying {
                TextField("Transcript", text: $segment.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
            } else {
                // Highlight active words in real-time
                highlightedWordsView(displayedText, direction: direction)
                    .font(.body)
            }
        }
        .padding(14)
        .background(
            isActive
                ? Color.blue.opacity(0.08)
                : (isSelected ? Color.blue.opacity(0.05) : Color(.secondarySystemBackground))
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Color.blue : (isSelected ? Color.blue.opacity(0.5) : Color.clear), lineWidth: isActive ? 2 : 1)
        )
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button(action: onSplit) {
                Label("Split at Midpoint", systemImage: "scissors")
            }
            Button(action: onSelect) {
                Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
            }
        }
        .environment(\.layoutDirection, direction)
    }
    
    // Renders words with real-time active word highlight pill during playback
    @ViewBuilder
    private func highlightedWordsView(_ text: String, direction: LayoutDirection) -> some View {
        let displayedWords = words(in: text)
        let activeWordIndex = resolveActiveWordIndex(for: displayedWords)

        FlowLayout(spacing: 4, layoutDirection: direction) {
            ForEach(Array(displayedWords.enumerated()), id: \.offset) { index, word in
                let isWordActive = (index == activeWordIndex)
                Text(word)
                    .foregroundStyle(isWordActive ? Color.blue : Color.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(isWordActive ? Color.blue.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private func resolveActiveWordIndex(for displayedWords: [String]) -> Int? {
        guard isPlaying, isActive, !displayedWords.isEmpty,
              currentTime >= segment.startTime, currentTime <= segment.endTime else { return nil }
        if isVerbatimMode, segment.words.count == displayedWords.count {
            return segment.words.firstIndex { currentTime >= $0.startTime && currentTime < $0.endTime }
        }
        // Clean mode may remove or retokenize words; interpolate across the
        // anchored segment instead of indexing into the original word array.
        let duration = max(0.05, segment.endTime - segment.startTime)
        let progress = min(max((currentTime - segment.startTime) / duration, 0), 0.999)
        return Int(progress * Double(displayedWords.count))
    }

    private func words(in text: String) -> [String] {
        if isVerbatimMode, !segment.words.isEmpty { return segment.words.map(\.word) }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let tokens = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        return tokens.isEmpty ? text.split(separator: " ").map(String.init) : tokens.map { String(text[$0]) }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func filterFillers(_ text: String) -> String {
        TranscriptTextCleaner.clean(text)
    }
}

// MARK: - Flow Layout for Word Highlighting Wrap
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var layoutDirection: LayoutDirection = .leftToRight
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing, layoutDirection: layoutDirection)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing, layoutDirection: layoutDirection)
        for (index, subview) in subviews.enumerated() {
            let point = result.points[index]
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var points: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat, layoutDirection: LayoutDirection) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                let x = layoutDirection == .rightToLeft ? maxWidth - currentX - size.width : currentX
                points.append(CGPoint(x: x, y: currentY))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
            size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}

// MARK: - Export Wrapper & Share Sheet
struct ExportedFileWrapper: Identifiable {
    let id = UUID()
    let file: ExportedFile
}

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
