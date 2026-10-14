//  TranscribeService.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import Accelerate
import UIKit

/// Thread-safe cancellation state shared with whisper.cpp callbacks.  This is
/// deliberately independent of actor isolation because `whisper_full` blocks
/// the actor while inference is running.
nonisolated private final class WhisperCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func reset() { lock.lock(); value = false; lock.unlock() }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Lifetime-owned exclusively by whisper's `progress_callback_user_data`.
/// Keeping this type at file scope ensures the callback below is a genuinely
/// non-capturing C-function-pointer closure.
nonisolated private final class WhisperProgressContext: @unchecked Sendable {
    let handler: @Sendable (Double) async -> Void
    let cancellationFlag: WhisperCancellationFlag

    init(
        handler: @escaping @Sendable (Double) async -> Void,
        cancellationFlag: WhisperCancellationFlag
    ) {
        self.handler = handler
        self.cancellationFlag = cancellationFlag
    }
}

// MARK: - Transcription Errors
enum TranscriptionError: Error, LocalizedError, Equatable {
    case modelNotFound
    case modelNotInstalled(String)
    case modelLoadFailed(String)
    case wavReadFailed(String)
    case wavInvalidFormat(String)
    case inferenceFailed(String)
    case cancelled
    case noAudio

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "No Whisper model file was found in the app bundle."
        case .modelNotInstalled(let fileName):
            return "The selected language pack (\(fileName)) is not installed. Download it from Settings before transcribing."
        case .modelLoadFailed(let reason):
            return "Failed to load the Whisper model: \(reason)"
        case .wavReadFailed(let reason):
            return "Failed to read audio file: \(reason)"
        case .wavInvalidFormat(let reason):
            return "Unsupported audio format: \(reason)"
        case .inferenceFailed(let reason):
            return "Transcription inference failed: \(reason)"
        case .cancelled:
            return "Transcription was cancelled."
        case .noAudio:
            return "No audio samples were available to transcribe."
        }
    }
}

// MARK: - Transcription Result
/// Output of the ASR step: timestamped text segments already attributed to
/// speakers using the diarization map.
struct TranscriptionResult: Sendable {
    let segments: [TranscriptSegment]
    let detectedLanguage: String
    let totalDuration: TimeInterval
}

// MARK: - Transcription Configuration
struct TranscriptionConfig: Sendable {
    /// ISO-639-1 language code ("en", "es", ...). Use "auto" for auto detection.
    var language: String = "ur"
    /// Language-appropriate initial prompt for vocabulary biasing & domain vocabulary.
    var initialPrompt: String? = nil
    /// Translate to English (ignored if language is already English).
    var translate: Bool = false
    /// Number of decoding threads. 0 => use all available cores.
    var threadCount: Int = 0
    /// Force English model behaviour when using a multilingual model.
    var forceEnglish: Bool = false
    /// Optional specific model URL to use for transcription. If nil, resolves from selectedModelFilename or best available model.
    var modelURL: URL? = nil

    static let `default` = TranscriptionConfig()
}

// MARK: - Transcription Service Protocol
protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(
        wavURL: URL,
        diarization: [DiarizationSegment],
        config: TranscriptionConfig,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> Result<TranscriptionResult, TranscriptionError>

    func cancel() async
}

// MARK: - Transcribe Service (whisper.cpp bridge)
/// On-device Automatic Speech Recognition backed by **whisper.cpp** (compiled as
/// a static `whisper.xcframework`, exposed through the Objective-C bridging header).
///
/// Memory contract:
/// - The Whisper context (`whisper_context*`) is created, used, and freed
///   (`whisper_free`) within a single `transcribe(...)` call. No model state
///   outlives the call.
/// - The PCM float buffer is dropped as soon as inference completes.
///
/// Pipeline position (sequential — never concurrent with diarization):
/// `AudioExtraction -> Diarization -> [TranscribeService] -> done`.
actor TranscribeService: TranscriptionServiceProtocol {

    private var isCancelled = false
    nonisolated private let cancellationFlag = WhisperCancellationFlag()

    // MARK: - Init
    init() {}

    // MARK: - Public API
    func transcribe(
        wavURL: URL,
        diarization: [DiarizationSegment],
        config: TranscriptionConfig,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> Result<TranscriptionResult, TranscriptionError> {

        isCancelled = false
        cancellationFlag.reset()

        // 1. Load PCM from the 16 kHz WAV produced by AudioExtractionService.
        await progressHandler(0.02)
        let samples: [Float]
        do {
            samples = try WAVReader.readMonoFloat16kHzPCM(from: wavURL)
        } catch let error as TranscriptionError {
            return .failure(error)
        } catch {
            return .failure(.wavReadFailed(error.localizedDescription))
        }

        guard samples.count > 32 else {
            return .failure(.noAudio)
        }
        await progressHandler(0.08)

        guard !isCancelled else { return .failure(.cancelled) }

        // 2. Locate the ggml model (honors explicit URL, user selection, or best fallback).
        let modelURL: URL
        if let explicit = config.modelURL {
            modelURL = explicit
        } else if let selected = UserDefaults.standard.string(forKey: AppSettings.selectedModelFilename), !selected.isEmpty {
            guard let resolved = Self.locateBundledModel(preferredModelFilename: selected),
                  resolved.lastPathComponent == selected else {
                return .failure(.modelNotInstalled(selected))
            }
            modelURL = resolved
        } else if let resolved = Self.locateBundledModel() {
            modelURL = resolved
        } else {
            return .failure(.modelNotFound)
        }

        await progressHandler(0.10)

        // 3. Run inference. All whisper.cpp state is created and freed here.
        let outcome = await runWhisperInference(
            modelURL: modelURL,
            samples: samples,
            diarization: diarization,
            config: config,
            progressHandler: progressHandler
        )

        switch outcome {
        case .failure(let err):
            return .failure(err)
        case .success(let pair):
            let rawSegments = pair.rawSegments
            let language = pair.language
            await progressHandler(0.97)

            // 4. Attribute each ASR segment to the dominant diarization speaker.
            let attributed = Self.attributeSpeakers(
                rawSegments: rawSegments,
                diarization: diarization,
                languageCode: language
            )

            await progressHandler(1.0)

            let duration = rawSegments.last.map { $0.endTime } ?? 0
            return .success(TranscriptionResult(
                segments: attributed,
                detectedLanguage: language,
                totalDuration: duration
            ))
        }
    }

    nonisolated func cancel() async {
        cancellationFlag.cancel()
        await setCancelled(true)
    }

    private func setCancelled(_ value: Bool) {
        isCancelled = value
    }

    // MARK: - Whisper Inference
    /// Creates a `whisper_context`, runs `whisper_full`, harvests timestamped
    /// segments, then **immediately** calls `whisper_free` so the model tensors
    /// and activations are returned to the OS before this method returns.
    private func runWhisperInference(
        modelURL: URL,
        samples: [Float],
        diarization: [DiarizationSegment],
        config: TranscriptionConfig,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> Result<(rawSegments: [RawASRSegment], language: String), TranscriptionError> {

        guard !isCancelled else { return .failure(.cancelled) }

        // Vendor/whisper.xcframework is built with GGML_METAL and the embedded
        // Metal library. Avoid starting GPU work while backgrounded: iOS may
        // revoke a Metal command queue during inference.
        var contextParams = whisper_context_default_params()
        let isBackgrounded = await MainActor.run {
            UIApplication.shared.applicationState == .background
        }
        contextParams.use_gpu = !isBackgrounded
        // Token timestamps need the cross-attention weights omitted by flash attention.
        contextParams.flash_attn = false

        let modelPath = modelURL.path
        let ctx: OpaquePointer? = modelPath.withCString { pathPtr in
            whisper_init_from_file_with_params(pathPtr, contextParams)
        }

        guard let context = ctx else {
            return .failure(.modelLoadFailed("whisper_init_from_file_with_params returned NULL"))
        }

        // Guarantee release no matter how we exit below.
        defer {
            whisper_free(context)
        }

        guard !isCancelled else { return .failure(.cancelled) }

        // Greedy decoding avoids the large CPU and latency cost of beam search
        // on-device. Deterministic temperature also prevents fallback loops.
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.temperature_inc = 0.2
        params.temperature = 0.0
        params.entropy_thold = 2.4

        params.translate = config.translate
        params.no_timestamps = false   // we want segment timestamps
        params.no_context = true       // avoid repetition loops across low-entropy audio
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.token_timestamps = true
        params.vad = false             // diarization is handled separately
        params.suppress_regex = nil
        params.prompt_tokens = nil
        params.grammar_rules = nil
        params.offset_ms = 0
        params.duration_ms = 0         // process whole file

        // activeProcessorCount includes efficiency cores. Limiting native work
        // to four performance cores keeps the UI and thermal budget responsive.
        let performanceBudget = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        let cores = min(performanceBudget, max(1, config.threadCount > 0 ? config.threadCount : performanceBudget))
        params.n_threads = Int32(cores)

        // Bridge real-time progress from whisper.cpp. The callback reads all
        // state through `user_data`, which is required for a C function pointer.
        let cancelFlag = cancellationFlag
        let progressContext = WhisperProgressContext(handler: { fraction in
            await progressHandler(0.18 + 0.76 * min(max(fraction, 0), 1))
        }, cancellationFlag: cancelFlag)
        let retainedProgressContext = Unmanaged.passRetained(progressContext)
        params.progress_callback_user_data = retainedProgressContext.toOpaque()
        params.progress_callback = { (ctx, state, progress, user_data) in
            guard let user_data = user_data else { return }
            let progressContext = Unmanaged<WhisperProgressContext>.fromOpaque(user_data).takeUnretainedValue()
            Task.detached {
                guard !progressContext.cancellationFlag.isCancelled else { return }
                await progressContext.handler(Double(progress) / 100.0)
            }
        }
        // whisper_full may invoke this from arbitrary worker threads. Keep a
        // retained flag alive for the complete C call, then release it below.
        let retainedAbortFlag = Unmanaged.passRetained(cancelFlag)
        params.abort_callback_user_data = retainedAbortFlag.toOpaque()
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<WhisperCancellationFlag>.fromOpaque(userData)
                .takeUnretainedValue().isCancelled
        }
        defer {
            retainedProgressContext.release()
            retainedAbortFlag.release()
        }
        let requestedLanguage = config.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let languageCode: String
        if requestedLanguage == "auto" || requestedLanguage.isEmpty {
            languageCode = await resolveAutoLanguage(context: context, samples: samples,
                                                     diarization: diarization, threads: Int32(cores),
                                                     progressHandler: progressHandler)
        } else {
            languageCode = requestedLanguage
        }
        await progressHandler(0.18)
        guard !cancellationFlag.isCancelled else { return .failure(.cancelled) }
        let effectivePrompt = Self.initialPrompt(for: languageCode, fallback: config.initialPrompt)
        let promptPointer = effectivePrompt.flatMap { $0.isEmpty ? nil : strdup($0) }
        defer { if let promptPointer { free(promptPointer) } }
        params.initial_prompt = promptPointer.map { UnsafePointer<CChar>($0) }
        params.no_speech_thold = 0.6
        params.logprob_thold = -1.0
        var status: Int32 = -1

        final class InferenceBox: @unchecked Sendable {
            let context: OpaquePointer
            let samples: [Float]
            let parameters: whisper_full_params
            let cancellationFlag: WhisperCancellationFlag
            init(context: OpaquePointer, samples: [Float], parameters: whisper_full_params, cancellationFlag: WhisperCancellationFlag) {
                self.context = context
                self.samples = samples
                self.parameters = parameters
                self.cancellationFlag = cancellationFlag
            }
        }
        let inference = InferenceBox(context: context, samples: samples, parameters: params, cancellationFlag: cancelFlag)
        // Whisper reports once per audio window. Interpolate below completion
        // between callbacks; actual completion is emitted only after inference.
        let estimatedDecodeSeconds = max(4.0, Double(samples.count) / AudioExtractionService.targetSampleRate * 0.35)
        let tickerTask = Task.detached {
            let clock = ContinuousClock()
            let started = clock.now
            while !Task.isCancelled && !cancelFlag.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
                guard !Task.isCancelled && !cancelFlag.isCancelled else { break }
                let elapsed = started.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let estimate = min(0.90, 0.18 + 0.72 * (1 - exp(-seconds / estimatedDecodeSeconds)))
                await progressHandler(estimate)
            }
        }
        defer { tickerTask.cancel() }
        let runInference: () async throws -> Int32 = {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !inference.cancellationFlag.isCancelled else {
                        continuation.resume(throwing: TranscriptionError.cancelled)
                        return
                    }
                    var localParameters = inference.parameters
                    let invoke: () -> Int32 = {
                        inference.samples.withUnsafeBufferPointer { buffer in
                            whisper_full(inference.context, localParameters, buffer.baseAddress, Int32(buffer.count))
                        }
                    }
                    let result = languageCode.withCString { language in
                        localParameters.language = language
                        return invoke()
                    }
                    continuation.resume(returning: result)
                }
            }
        }

        do {
            status = try await runInference()
        } catch {
            return .failure(.cancelled)
        }

        tickerTask.cancel()
        await tickerTask.value
        if cancellationFlag.isCancelled || isCancelled { return .failure(.cancelled) }
        await progressHandler(0.95)

        guard status == 0 else {
            if cancellationFlag.isCancelled { return .failure(.cancelled) }
            return .failure(.inferenceFailed("whisper_full returned status \(status)"))
        }

        // Harvest complete segments. Accumulate raw UTF-8 bytes first: a BPE
        // token can end halfway through a multibyte Urdu/Arabic character, so
        // decoding each token with `String(cString:)` corrupts transcript text.
        let nSegments = whisper_full_n_segments(context)
        let eotToken = whisper_token_eot(context)
        var raw: [RawASRSegment] = []
        raw.reserveCapacity(Int(nSegments))

        for i in 0..<nSegments {
            guard !isCancelled && !cancellationFlag.isCancelled else { return .failure(.cancelled) }
            let segmentStart = max(0, TimeInterval(whisper_full_get_segment_t0(context, i)) / 100.0)
            let segmentEnd = max(segmentStart, TimeInterval(whisper_full_get_segment_t1(context, i)) / 100.0)
            let tokenCount = whisper_full_n_tokens(context, i)
            guard tokenCount > 0 else {
                let textPtr = whisper_full_get_segment_text(context, i)
                let text = textPtr.map { String(cString: $0) } ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                raw.append(RawASRSegment(startTime: segmentStart, endTime: segmentEnd, text: trimmed, words: []))
                continue
            }

            var segmentBytes: [UInt8] = []
            var tokenByteSpans: [ASRTokenBytes] = []

            for tokenIndex in 0..<tokenCount {
                let tokenID = whisper_full_get_token_id(context, i, tokenIndex)
                // Special and timestamp tokens are never transcript content.
                guard tokenID < eotToken,
                      let cString = whisper_full_get_token_text(context, i, tokenIndex) else { continue }

                let length = strlen(cString)
                guard length > 0 else { continue }
                let bytes = Array(UnsafeBufferPointer(
                    start: UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self),
                    count: length
                ))
                segmentBytes.append(contentsOf: bytes)

                let start = TimeInterval(whisper_full_get_token_t0(context, i, tokenIndex)) / 100.0
                let end = TimeInterval(whisper_full_get_token_t1(context, i, tokenIndex)) / 100.0
                tokenByteSpans.append(ASRTokenBytes(bytes: bytes, startTime: start, endTime: end))
            }

            let text = String(decoding: segmentBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let words = Self.wordTimings(from: tokenByteSpans, segmentStart: segmentStart, segmentEnd: segmentEnd, languageCode: languageCode)
            raw.append(RawASRSegment(startTime: segmentStart, endTime: segmentEnd, text: text, words: words))
        }

        // Report the resolved decoding language, including the Urdu script preference.
        let detectedLanguage = languageCode
        if languageCode == "ur" || languageCode == "ar" {
            let transcript = raw.map(\.text).joined()
            let arabic = transcript.unicodeScalars.filter { (0x0600...0x06FF).contains($0.value) }.count
            let latin = transcript.unicodeScalars.filter { (0x0041...0x007A).contains($0.value) }.count
            if !transcript.isEmpty, latin > arabic * 2 {
                AppLogger.shared.warning("Script mismatch: mostly Latin output for Arabic-script transcription.", category: .transcription)
            }
        }

        return .success((raw, detectedLanguage))
    }

    /// Constrain detection to the languages supported in the picker, plus Hindi
    /// for resolving the user's Urdu/Hindi script preference. No prompt is used here.
    private func resolveAutoLanguage(
        context: OpaquePointer, samples: [Float],
        diarization: [DiarizationSegment], threads: Int32,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> String {
        let ranges = Self.languageDetectionRanges(sampleCount: samples.count, diarization: diarization)
        let maxID = Int(whisper_lang_max_id())
        var accumulated: [String: Float] = [:]
        for (index, range) in ranges.enumerated() {
            await progressHandler(0.10 + 0.08 * Double(index) / Double(max(1, ranges.count)))
            guard !cancellationFlag.isCancelled else { break }
            let rc = samples.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return whisper_pcm_to_mel(context, base.advanced(by: range.lowerBound), Int32(range.count), threads)
            }
            guard rc == 0 else { continue }
            var probabilities = [Float](repeating: 0, count: maxID + 1)
            let detected = probabilities.withUnsafeMutableBufferPointer {
                whisper_lang_auto_detect(context, 0, threads, $0.baseAddress)
            }
            guard detected >= 0 else { continue }
            for id in 0...maxID {
                guard let name = whisper_lang_str(Int32(id)) else { continue }
                let code = String(cString: name)
                accumulated[code, default: 0] += probabilities[id]
            }
        }
        let preferUrdu = UserDefaults.standard.object(forKey: AppSettings.preferUrduOverHindi) as? Bool ?? true
        return Self.resolvedLanguage(probabilities: accumulated, preferUrdu: preferUrdu)
    }

    /// Decode at ASCII whitespace boundaries, or complete UTF-8 characters
    /// for Chinese/Japanese. Characters may span BPE tokens. Missing timestamps are
    /// distributed by byte length across the real ASR segment, not invented.
    nonisolated static func wordTimings(
        from tokens: [ASRTokenBytes], segmentStart: TimeInterval, segmentEnd: TimeInterval,
        languageCode: String = "en"
    ) -> [WordTiming] {
        guard segmentStart.isFinite, segmentEnd.isFinite, segmentEnd >= segmentStart else { return [] }
        let isCJK = languageCode == "zh" || languageCode == "ja"
        var rawWords: [(text: String, start: Double, end: Double, weight: Double)] = []
        var bytes: [UInt8] = []
        var wordStart: Double?
        var wordEnd = segmentStart
        var cursor = segmentStart
        var validCount = 0
        func flushWord() {
            guard !bytes.isEmpty else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            rawWords.append((text, wordStart ?? segmentStart, wordEnd, Double(bytes.count)))
            bytes.removeAll(keepingCapacity: true)
            wordStart = nil
        }
        for token in tokens {
            let valid = token.startTime.isFinite && token.endTime.isFinite
                && token.startTime >= segmentStart && token.endTime > token.startTime
                && token.endTime <= segmentEnd + 0.2
            let start = valid ? min(segmentEnd, max(cursor, token.startTime)) : cursor
            let end = valid ? min(segmentEnd, max(start, token.endTime)) : start
            if valid && end > start { validCount += 1 }
            cursor = end
            for byte in token.bytes {
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    flushWord()
                } else {
                    if wordStart == nil { wordStart = start }
                    wordEnd = end
                    bytes.append(byte)
                    if isCJK, String(bytes: bytes, encoding: .utf8) != nil {
                        flushWord()
                    }
                }
            }
        }
        flushWord()
        guard let first = rawWords.first, let last = rawWords.last else { return [] }
        let duration = segmentEnd - segmentStart
        let rawSpan = last.end - first.start
        let orderedWordSpans = rawWords.allSatisfy { $0.end > $0.start }
            && zip(rawWords, rawWords.dropFirst()).allSatisfy { $0.0.end <= $0.1.start }
        let useTokenTimings = orderedWordSpans && rawSpan > 0 && rawSpan >= duration * 0.60
            && validCount * 2 >= tokens.count
        let totalWeight = rawWords.reduce(0) { $0 + $1.weight }
        cursor = segmentStart
        return rawWords.enumerated().map { index, word in
            let start: Double
            let end: Double
            if useTokenTimings {
                let scale = duration / rawSpan
                start = index == 0 ? segmentStart : min(segmentEnd, max(cursor, segmentStart + (word.start - first.start) * scale))
                end = index == rawWords.count - 1 ? segmentEnd
                    : min(segmentEnd, max(start, segmentStart + (word.end - first.start) * scale))
            } else {
                start = cursor
                end = index == rawWords.count - 1 ? segmentEnd : min(segmentEnd, cursor + duration * word.weight / totalWeight)
            }
            cursor = end
            return WordTiming(word: word.text, startTime: start, endTime: end)
        }
    }

    nonisolated static func languageDetectionRanges(sampleCount: Int, diarization: [DiarizationSegment]) -> [Range<Int>] {
        let sr = Int(AudioExtractionService.targetSampleRate)
        let windows = diarization.filter { $0.duration >= 2 }.sorted { $0.duration > $1.duration }
            .compactMap { turn -> Range<Int>? in
                let lo = max(0, min(sampleCount, Int(turn.startTime * Double(sr))))
                let end = max(lo, min(sampleCount, Int(turn.endTime * Double(sr))))
                let hi = min(end, lo + 30 * sr)
                return hi - lo >= 2 * sr ? lo..<hi : nil
            }
        // Remove overlapping windows so one speech region cannot dominate the vote.
        var ranges: [Range<Int>] = []
        for window in windows where !ranges.contains(where: { $0.overlaps(window) }) {
            ranges.append(window)
            if ranges.count == 4 { break }
        }
        return ranges.isEmpty && sampleCount > 0 ? [0..<min(sampleCount, 30 * sr)] : ranges
    }

    nonisolated static func resolvedLanguage(probabilities: [String: Float], preferUrdu: Bool) -> String {
        let allowed = ["ur", "hi", "en", "ar", "es", "fr", "de", "ja", "zh"]
        let best = allowed.filter { (probabilities[$0] ?? 0) > 0 }
            .max { (probabilities[$0] ?? 0) < (probabilities[$1] ?? 0) }
        guard let best else { return preferUrdu ? "ur" : "hi" }
        return (best == "hi" || best == "ur") ? (preferUrdu ? "ur" : "hi") : best
    }

    nonisolated static func initialPrompt(for language: String, fallback: String?) -> String? {
        switch language {
        case "ur": return "یہ ایک اردو گفتگو ہے جس میں English words جیسے meeting, office, project, client, schedule استعمال ہوتے ہیں۔"
        case "en": return "This is an English conversation. It may contain technical terms, clear punctuation, and proper nouns."
        default: return fallback
        }
    }

    // MARK: - Speaker Attribution
    /// Attributes timed words to speakers and bounds cues by pauses, sentences, and duration.
    /// Out-of-speech text is discarded to prevent silence hallucinations.
    nonisolated static func attributeSpeakers(
        rawSegments: [RawASRSegment],
        diarization: [DiarizationSegment],
        languageCode: String = "en"
    ) -> [TranscriptSegment] {

        let sortedDiarization = diarization.sorted { $0.startTime < $1.startTime }
        func speaker(at time: TimeInterval) -> String {
            var low = 0
            var high = sortedDiarization.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let turn = sortedDiarization[mid]
                if time < turn.startTime {
                    high = mid - 1
                } else if time > turn.endTime {
                    low = mid + 1
                } else {
                    return turn.speakerID
                }
            }
            // A silence gap gets the temporally nearest real turn, not a
            // hard-coded Speaker 1 assignment.
            return sortedDiarization.min {
                abs(time - ($0.startTime + $0.endTime) / 2) < abs(time - ($1.startTime + $1.endTime) / 2)
            }?.speakerID ?? "Speaker 1"
        }

        var timedWords: [(WordTiming, String)] = []
        for segment in rawSegments {
            let hasSpeechOverlap = sortedDiarization.isEmpty || sortedDiarization.contains {
                segment.startTime <= $0.endTime + 1.0 && segment.endTime >= $0.startTime - 1.0
            }
            guard hasSpeechOverlap else { continue }
            if segment.words.isEmpty {
                let fallback = WordTiming(word: segment.text, startTime: segment.startTime, endTime: segment.endTime)
                timedWords.append((fallback, speaker(at: (segment.startTime + segment.endTime) / 2)))
            } else {
                for word in segment.words {
                    timedWords.append((word, speaker(at: (word.startTime + word.endTime) / 2)))
                }
            }
        }
        let separator = (languageCode == "zh" || languageCode == "ja") ? "" : " "
        let sentenceEndings: Set<Character> = [".", "!", "?", "۔", "؟", "。", "！", "？", "\n"]
        var result: [TranscriptSegment] = []
        var group: [WordTiming] = []
        var activeSpeaker: String?
        func flush() {
            guard let activeSpeaker, let first = group.first, let last = group.last else { return }
            result.append(TranscriptSegment(startTime: first.startTime, endTime: last.endTime,
                                            speakerID: activeSpeaker, text: group.map(\.word).joined(separator: separator), words: group))
            group.removeAll()
        }
        for (word, speakerID) in timedWords {
            if let currentSpeaker = activeSpeaker {
                let speakerChanged = currentSpeaker != speakerID
                let pauseGap = group.last.map { word.startTime - $0.endTime > 0.6 } ?? false
                let durationExceeded = group.first.map { word.endTime - $0.startTime > 8.0 } ?? false
                let endedSentence = group.last?.word.trimmingCharacters(in: .whitespacesAndNewlines).last
                    .map { sentenceEndings.contains($0) } ?? false
                if speakerChanged || pauseGap || durationExceeded || endedSentence { flush() }
            }
            activeSpeaker = speakerID
            group.append(word)
        }
        flush()
        return result
    }

    // MARK: - Model Discovery
    /// Searches the shared App Group directory and app bundle for a Whisper model.
    /// Honors user selection in UserDefaults or preferredModelFilename, falling back
    /// to the best downloaded high-accuracy model or bundled model.
    nonisolated static func locateBundledModel(preferredModelFilename: String? = nil) -> URL? {
        let appGroupIdentifier = AppSettings.appGroupID
        let selected = preferredModelFilename ?? UserDefaults.standard.string(forKey: AppSettings.selectedModelFilename)

        let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        let modelsDir = appGroupURL?.appendingPathComponent("Models")

        // 1. If user explicitly selected a model, check App Group directory first, then bundle
        if let selected = selected, !selected.isEmpty {
            if let modelsDir {
                let candidate = modelsDir.appendingPathComponent(selected)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    AppLogger.shared.info("Using user-selected model from App Group: \(selected)", category: .transcription)
                    return candidate
                }
            }
            let baseName = selected.replacingOccurrences(of: ".bin", with: "")
            if let bundleURL = Bundle.main.url(forResource: baseName, withExtension: "bin") {
                AppLogger.shared.info("Using user-selected model from App Bundle: \(bundleURL.lastPathComponent)", category: .transcription)
                return bundleURL
            }
            AppLogger.shared.warning("User-selected model '\(selected)' not found locally. Searching for best available model...", category: .transcription)
        }
        
        // 2. Check shared App Group directory for any downloaded high-accuracy models in priority order
        let preferredFileNames = [
            "ggml-large-v3-turbo-q8_0.bin",
            "ggml-large-v3-turbo.bin",
            "ggml-small-q8_0.bin",
            "ggml-small.bin",
            "ggml-base-q8_0.bin",
            "ggml-base.bin",
            "ggml-tiny-q8_0.bin",
            "ggml-tiny.bin"
        ]
        
        if let modelsDir {
            for fileName in preferredFileNames {
                let modelURL = modelsDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: modelURL.path) {
                    AppLogger.shared.info("Using downloaded high-quality model: \(fileName)", category: .transcription)
                    return modelURL
                }
            }
        }
        
        // 3. Fallback to App Bundle resources
        let bundleNames = [
            "ggml-large-v3-turbo-q8_0",
            "ggml-large-v3-turbo",
            "ggml-small-q8_0",
            "ggml-small",
            "ggml-base-q8_0",
            "ggml-base",
            "ggml-tiny-q8_0",
            "ggml-tiny"
        ]
        for name in bundleNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "bin") {
                AppLogger.shared.info("Using bundled model: \(url.lastPathComponent)", category: .transcription)
                return url
            }
        }
        
        if let urls = Bundle.main.urls(forResourcesWithExtension: "bin", subdirectory: nil),
           let match = urls.first(where: { $0.lastPathComponent.hasPrefix("ggml-") }) {
            AppLogger.shared.info("Using generic bundled model match: \(match.lastPathComponent)", category: .transcription)
            return match
        }
        return nil
    }
}

/// Raw BPE bytes and their unmodified Whisper timestamps.
nonisolated struct ASRTokenBytes: Sendable {
    let bytes: [UInt8]
    let startTime: TimeInterval
    let endTime: TimeInterval
}

// MARK: - Raw ASR Segment (internal)
struct RawASRSegment: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let words: [WordTiming]
}

// MARK: - WAV Reader
/// Minimal, allocation-conscious WAV reader for the canonical 16 kHz / 16-bit /
/// mono PCM files produced by `AudioExtractionService`. Validates the container
/// and parses the `fmt ` and `data` chunks (skipping any extra chunks).
enum WAVReader {

    enum ReadError: Error, LocalizedError {
        case unreadable(String)
        case invalidHeader
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let r): return "Could not read audio data: \(r)"
            case .invalidHeader: return "Invalid or corrupt WAV header."
            case .unsupportedFormat(let r): return "Unsupported WAV format: \(r)"
            }
        }
    }

    /// Reads the WAV and returns normalized mono Float32 samples in [-1, 1].
    /// Enforces 16-bit PCM at 16 kHz mono (the format the ASR engine expects).
    nonisolated static func readMonoFloat16kHzPCM(from url: URL) throws -> [Float] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw TranscriptionError.wavReadFailed(error.localizedDescription)
        }

        guard data.count >= 44 else {
            throw TranscriptionError.wavInvalidFormat("file too small (\(data.count) bytes)")
        }

        // Validate RIFF/WAVE magic.
        let riff = data[0..<4]
        let wave = data[8..<12]
        guard riff == Data([0x52, 0x49, 0x46, 0x46]),
              wave == Data([0x57, 0x41, 0x56, 0x45]) else {
            throw TranscriptionError.wavInvalidFormat("not a RIFF/WAVE file")
        }

        // Walk chunks beginning at offset 12.
        var offset = 12
        var audioFormat: UInt16 = 0
        var channels: UInt16 = 0
        var sampleRate: UInt32 = 0
        var bitsPerSample: UInt16 = 0
        var dataStart: Int = 0
        var dataSize: Int = 0

        while offset + 8 <= data.count {
            let chunkID = data[offset..<offset + 4]
            let chunkSize = readUInt32LE(data, at: offset + 4)
            let body = offset + 8

            if chunkID == Data([0x66, 0x6d, 0x74, 0x20]) /* "fmt " */ {
                guard body + 16 <= data.count else {
                    throw TranscriptionError.wavInvalidFormat("truncated fmt chunk")
                }
                audioFormat   = readUInt16LE(data, at: body + 0)
                channels      = readUInt16LE(data, at: body + 2)
                sampleRate    = readUInt32LE(data, at: body + 4)
                bitsPerSample = readUInt16LE(data, at: body + 14)
            } else if chunkID == Data([0x64, 0x61, 0x74, 0x61]) /* "data" */ {
                dataStart = body
                dataSize = Int(chunkSize)
                // Clamp to the bytes actually present.
                if dataStart + dataSize > data.count {
                    dataSize = data.count - dataStart
                }
                break
            }

            // Chunks are word-aligned (even sizes); advance by chunkSize + 8, padded.
            let padded = Int(chunkSize) + ((Int(chunkSize) & 1) == 1 ? 1 : 0)
            offset = body + padded
        }

        guard audioFormat == 1 else {
            throw TranscriptionError.wavInvalidFormat("audio format \(audioFormat) is not PCM")
        }
        guard bitsPerSample == 16 else {
            throw TranscriptionError.wavInvalidFormat("bit depth \(bitsPerSample) != 16")
        }
        guard channels == 1 else {
            throw TranscriptionError.wavInvalidFormat("channel count \(channels) != mono")
        }
        guard sampleRate == UInt32(AudioExtractionService.targetSampleRate) else {
            throw TranscriptionError.wavInvalidFormat("sample rate \(sampleRate) != 16000")
        }
        guard dataSize > 0, dataStart + dataSize <= data.count else {
            throw TranscriptionError.wavInvalidFormat("no PCM data")
        }

        // Decode Int16 LE -> Float32
        let frameCount = dataSize / 2
        var samples = [Float](repeating: 0, count: frameCount)
        
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.advanced(by: dataStart) else { return }
            let int16 = base.assumingMemoryBound(to: Int16.self)
            vDSP_vflt16(int16, 1, &samples, 1, vDSP_Length(frameCount))
            var scale: Float = 32768
            vDSP_vsdiv(samples, 1, &scale, &samples, 1, vDSP_Length(frameCount))
        }
        
        // 1. Gentle Normalization (protect headroom; gently boost very quiet speech without amplifying noise floor)
        var maxMagnitude: Float = 0
        vDSP_maxmgv(samples, 1, &maxMagnitude, vDSP_Length(frameCount))
        if maxMagnitude > 0.05 && maxMagnitude < 0.5 {
            // Target ~0.7 peak with at most 2.5x gain to prevent blowing up room noise
            let gain = min(0.7 / maxMagnitude, 2.5)
            vDSP_vsmul(samples, 1, [gain], &samples, 1, vDSP_Length(frameCount))
        } else if maxMagnitude > 1.0 {
            // Clamp clipping signals into [-1.0, 1.0]
            var minVal: Float = -1.0
            var maxVal: Float = 1.0
            vDSP_vclip(samples, 1, &minVal, &maxVal, &samples, 1, vDSP_Length(frameCount))
        }
        
        // Note: The crude RMS silence noise-gate was removed. Zeroing out 1s+ blocks below 0.015 RMS
        // prematurely cuts quiet consonants, whispers, and natural speech pauses, introducing
        // acoustic clicks. Whisper's internal transformer handles natural ambient acoustic context.
        
        return samples
    }

    nonisolated private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[offset + i]) << (8 * i)
        }
        return value
    }

    nonisolated private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        for i in 0..<2 {
            value |= UInt16(data[offset + i]) << (8 * i)
        }
        return value
    }
}
