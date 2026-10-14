//  SpeakerDiarizationService.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import Accelerate
import CoreML
import AVFoundation

// MARK: - Diarization Errors
enum DiarizationError: Error, LocalizedError, Equatable {
    case audioLoadFailed(String)
    case noSpeechDetected
    case clusteringFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .audioLoadFailed(let r): return "Failed to load audio for diarization: \(r)"
        case .noSpeechDetected: return "No speech activity detected in the audio."
        case .clusteringFailed(let r): return "Speaker clustering failed: \(r)"
        case .cancelled: return "Diarization was cancelled."
        }
    }
}

// MARK: - Diarization Result
struct DiarizationResult: Sendable {
    let segments: [DiarizationSegment]
    let speakerIDs: [String]
}

// MARK: - Diarization Configuration
struct DiarizationConfig: Sendable {
    /// Cosine-distance threshold below which two clusters may merge (0..2).
    var mergeThreshold: Float = 0.35
    /// Target number of speakers to cluster (nil or 0 for auto).
    var targetSpeakerCount: Int? = nil
    /// Sliding window length in seconds.
    var windowDuration: TimeInterval = 3.0
    /// Sliding window overlap in seconds.
    var windowOverlap: TimeInterval = 1.5
    /// Maximum number of speakers to allow.
    var maxSpeakers: Int = 8
    /// Minimum speech-segment duration (seconds) to keep (filters noise < 0.8s).
    var minSegmentDuration: TimeInterval = 0.8
    /// Silence gap (seconds) that splits two speech segments.
    var silenceSplitGap: TimeInterval = 0.30

    static let `default` = DiarizationConfig()
}

// MARK: - Speaker Diarization Protocol
protocol SpeakerDiarizationServiceProtocol: Sendable {
    func diarize(
        wavURL: URL,
        duration: TimeInterval,
        config: DiarizationConfig,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> Result<DiarizationResult, DiarizationError>

    func cancel() async
}

// MARK: - Speaker Diarization Service
/// On-device CoreML Neural Speaker Embedding & Diarization Pipeline.
///
/// Pipeline:
///   1. VAD & Sliding Windowing — Energy VAD + 1.5s sliding windowing (0.75s stride),
///      filtering out short noise artifacts (< 0.8s).
///   2. Neural Speaker Embedding — 192-d CoreML embedding (PyAnnote / ECAPA-TDNN / WeSpeaker)
///      with fallback to 192-d MFCC log-mel feature extraction.
///   3. Cosine Distance Matrix — 1 - (A . B) / (||A|| ||B||).
///   4. Constrained AHC — Agglomerative Hierarchical Clustering targeting
///      `targetSpeakerCount` (e.g. 2 speakers).
actor SpeakerDiarizationService: SpeakerDiarizationServiceProtocol {

    private var isCancelled = false

    init() {}

    // MARK: - Public API
    func diarize(
        wavURL: URL,
        duration: TimeInterval,
        config: DiarizationConfig,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> Result<DiarizationResult, DiarizationError> {

        isCancelled = false

        // 1. Load mono 16 kHz PCM
        await progressHandler(0.05)
        let pcm: [Float]
        do {
            pcm = try WAVReader.readMonoFloat16kHzPCM(from: wavURL)
        } catch let error as TranscriptionError {
            return .failure(.audioLoadFailed(error.errorDescription ?? "Read error"))
        } catch {
            return .failure(.audioLoadFailed(error.localizedDescription))
        }

        guard !pcm.isEmpty else {
            return .failure(.noSpeechDetected)
        }

        guard !isCancelled else { return .failure(.cancelled) }

        // 2. VAD: Speech activity detection with minSegmentDuration filter (< 0.8s noise filter)
        await progressHandler(0.15)
        let vad = EnergyVAD()
        let speechRanges = await vad.detect(
            in: pcm,
            duration: duration,
            config: config,
            progressHandler: { p in
                await progressHandler(0.15 + 0.20 * p)
            }
        )

        guard !speechRanges.isEmpty else {
            return .failure(.noSpeechDetected)
        }

        guard !isCancelled else { return .failure(.cancelled) }

        // 3. Sliding window segment extraction (3s windows with 1.5s stride).
        await progressHandler(0.35)
        let sr = Float(AudioExtractionService.targetSampleRate)
        let windowSamples = Int(config.windowDuration * Double(sr))
        let strideSamples = Int((config.windowDuration - config.windowOverlap) * Double(sr))
        
        var segments: [(range: Range<Int>, start: TimeInterval, end: TimeInterval)] = []
        
        for r in speechRanges {
            let segSamples = r.count
            if segSamples <= windowSamples {
                let start = TimeInterval(r.lowerBound) / Double(sr)
                let end = TimeInterval(r.upperBound) / Double(sr)
                if (end - start) >= config.minSegmentDuration {
                    segments.append((range: r, start: start, end: end))
                }
            } else {
                var currentStart = r.lowerBound
                while currentStart + windowSamples <= r.upperBound {
                    let currentEnd = min(currentStart + windowSamples, r.upperBound)
                    let start = TimeInterval(currentStart) / Double(sr)
                    let end = TimeInterval(currentEnd) / Double(sr)
                    segments.append((range: currentStart..<currentEnd, start: start, end: end))
                    currentStart += strideSamples
                }
                if currentStart < r.upperBound {
                    let start = TimeInterval(currentStart) / Double(sr)
                    let end = TimeInterval(r.upperBound) / Double(sr)
                    if (end - start) >= 0.4 {
                        segments.append((range: currentStart..<r.upperBound, start: start, end: end))
                    }
                }
            }
        }

        guard !segments.isEmpty else {
            return .failure(.noSpeechDetected)
        }

        if config.targetSpeakerCount == 1 {
            await progressHandler(0.9)
            let resultSegments = segments.map {
                DiarizationSegment(startTime: $0.start, endTime: $0.end, speakerID: "Speaker 1")
            }
            
            // Merge consecutive segments for Speaker 1 (if any gaps < 0.75s)
            var merged: [DiarizationSegment] = []
            for seg in resultSegments {
                if let last = merged.last, seg.startTime - last.endTime < 0.75 {
                    merged[merged.count - 1] = DiarizationSegment(
                        id: last.id,
                        startTime: last.startTime,
                        endTime: seg.endTime,
                        speakerID: "Speaker 1"
                    )
                } else {
                    merged.append(seg)
                }
            }
            
            await progressHandler(1.0)
            return .success(DiarizationResult(segments: merged, speakerIDs: ["Speaker 1"]))
        }

        // 4. Neural embedding when available; otherwise use one consistent
        // fbank-statistics representation for the entire run.
        await progressHandler(0.45)
        let embedder = makeEmbedder()
        let dim = embedder.dimension
        var embeddings = [Float]()
        embeddings.reserveCapacity(segments.count * dim)

        let totalSegs = Double(segments.count)
        for batchStart in stride(from: 0, to: segments.count, by: 4) {
            guard !isCancelled else { return .failure(.cancelled) }
            let batchEnd = min(batchStart + 4, segments.count)
            let slices = (batchStart..<batchEnd).map { Array(pcm[segments[$0].range]) }
            let batch: [[Float]]
            if let neural = embedder as? CoreMLSpeakerEmbedder {
                do { batch = try await neural.embedBatch(slices, sampleRate: sr) }
                catch { return .failure(.clusteringFailed("Speaker batch inference failed: \(error.localizedDescription)")) }
            } else {
                var fallbackBatch: [[Float]] = []
                fallbackBatch.reserveCapacity(slices.count)
                for slice in slices { fallbackBatch.append(await embedder.embed(slice, sampleRate: sr)) }
                batch = fallbackBatch
            }
            guard batch.count == slices.count, batch.allSatisfy({ $0.count == dim }) else {
                return .failure(.clusteringFailed("Speaker embedding dimension mismatch."))
            }
            batch.forEach { embeddings.append(contentsOf: $0) }
            await progressHandler(0.45 + 0.35 * Double(batchEnd) / totalSegs)
        }

        // 5. Cosine Distance Matrix & Constrained Clustering
        await progressHandler(0.85)
        let segTimeBounds = segments.map { (start: $0.start, end: $0.end) }
        let ahc = AgglomerativeClustering(
            embeddingDimension: dim,
            mergeThreshold: config.mergeThreshold,
            maxSpeakers: config.maxSpeakers
        )
        let labels = ahc.cluster(
            segments: segTimeBounds,
            embeddings: embeddings,
            targetSpeakerCount: config.targetSpeakerCount
        )

        // 6. Map cluster labels into canonical Speaker IDs and merge adjacent segments
        await progressHandler(0.95)
        let result = buildDiarizationSegments(
            segments: segments,
            labels: labels,
            embeddings: embeddings,
            dim: dim
        )
        await progressHandler(1.0)
        return .success(result)
    }

    func cancel() async {
        isCancelled = true
    }

    // MARK: - Embedder factory
    private func makeEmbedder() -> SpeakerEmbedder {
        let neural = CoreMLSpeakerEmbedder()
        if neural.isAvailable { return neural }
        AppLogger.shared.warning("ECAPA_TDNN.mlmodelc is unavailable; using the lower-quality fbank-statistics fallback.", category: .transcription)
        return SpectralEmbedder()
    }

    // MARK: - Output builder
    private func buildDiarizationSegments(
        segments: [(range: Range<Int>, start: TimeInterval, end: TimeInterval)],
        labels: [Int],
        embeddings: [Float],
        dim: Int
    ) -> DiarizationResult {
        var firstSeen: [Int: String] = [:]
        var nextID = 1
        var diarSegments: [DiarizationSegment] = []
        diarSegments.reserveCapacity(segments.count)

        for (i, seg) in segments.enumerated() {
            let cluster = labels[i]
            let speaker: String
            if let existing = firstSeen[cluster] {
                speaker = existing
            } else {
                speaker = "Speaker \(nextID)"
                firstSeen[cluster] = speaker
                nextID += 1
            }
            diarSegments.append(DiarizationSegment(startTime: seg.start, endTime: seg.end, speakerID: speaker))
        }

        // Sliding windows overlap by design. Resolve output overlaps exactly
        // once at the midpoint before smoothing so exported turns never occupy
        // the same timeline interval.
        if diarSegments.count > 1 {
            for index in 0..<(diarSegments.count - 1) where diarSegments[index].endTime > diarSegments[index + 1].startTime {
                let midpoint = (diarSegments[index].endTime + diarSegments[index + 1].startTime) / 2
                diarSegments[index].endTime = midpoint
                diarSegments[index + 1].startTime = midpoint
            }
        }

        // Do not relabel clusters here based on adjacent cosine distance.  That
        // previously collapsed distinct speakers and overrode an explicit target
        // count.  Restrict post-processing to temporal smoothing only.

        // 1. Secondary smoothing pass for micro-segments < 1.5s. Read from
        // the original labels and write to a separate array so a correction
        // cannot cascade through an entire conversation.
        var smoothedSegments = diarSegments
        for i in 0..<diarSegments.count {
            let dur = diarSegments[i].endTime - diarSegments[i].startTime
            if dur < 1.5 {
                var dominantID: String? = nil
                if i > 0 && i < diarSegments.count - 1 {
                    let prevID = diarSegments[i - 1].speakerID
                    let nextID = diarSegments[i + 1].speakerID
                    if prevID == nextID {
                        dominantID = prevID
                    } else {
                        let prevGap = diarSegments[i].startTime - diarSegments[i - 1].endTime
                        let nextGap = diarSegments[i + 1].startTime - diarSegments[i].endTime
                        dominantID = prevGap < nextGap ? prevID : nextID
                    }
                } else if i > 0 {
                    dominantID = diarSegments[i - 1].speakerID
                } else if i < diarSegments.count - 1 {
                    dominantID = diarSegments[i + 1].speakerID
                }
                
                if let dID = dominantID {
                    smoothedSegments[i] = DiarizationSegment(
                        id: diarSegments[i].id,
                        startTime: diarSegments[i].startTime,
                        endTime: diarSegments[i].endTime,
                        speakerID: dID
                    )
                }
            }
        }
        diarSegments = smoothedSegments

        // 2. Merge consecutive segments belonging to the same speaker
        var merged: [DiarizationSegment] = []
        for seg in diarSegments {
            if let last = merged.last, last.speakerID == seg.speakerID,
               seg.startTime - last.endTime < 0.75 {
                merged[merged.count - 1] = DiarizationSegment(
                    id: last.id,
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    speakerID: last.speakerID
                )
            } else {
                merged.append(seg)
            }
        }
        
        // 3. Re-number speaker IDs sequentially
        var finalIDMapping: [String: String] = [:]
        var nextFinalID = 1
        var renumberedMerged: [DiarizationSegment] = []
        
        for seg in merged {
            let fID: String
            if let existing = finalIDMapping[seg.speakerID] {
                fID = existing
            } else {
                fID = "Speaker \(nextFinalID)"
                finalIDMapping[seg.speakerID] = fID
                nextFinalID += 1
            }
            renumberedMerged.append(DiarizationSegment(
                id: seg.id,
                startTime: seg.startTime,
                endTime: seg.endTime,
                speakerID: fID
            ))
        }

        let speakerIDs = Array(Set(renumberedMerged.map { $0.speakerID })).sorted { lhs, rhs in
            (Int(lhs.replacingOccurrences(of: "Speaker ", with: "")) ?? 0)
            < (Int(rhs.replacingOccurrences(of: "Speaker ", with: "")) ?? 0)
        }
        return DiarizationResult(segments: renumberedMerged, speakerIDs: speakerIDs)
    }
}

// MARK: - Embedding dimension
extension DiarizationConfig {
    /// The validated ECAPA-TDNN bundle returns a 192-dimensional embedding.
    nonisolated static let embeddingDimension: Int = 192
}

// MARK: - Voice Activity Detection
protocol VoiceActivityDetector: Sendable {
    func detect(
        in pcm: [Float],
        duration: TimeInterval,
        config: DiarizationConfig,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> [Range<Int>]
}

/// Energy-based VAD with minSegmentDuration noise filtering (< 0.8s).
nonisolated final class EnergyVAD: VoiceActivityDetector, @unchecked Sendable {

    func detect(
        in pcm: [Float],
        duration: TimeInterval,
        config: DiarizationConfig,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> [Range<Int>] {
        let sr = Int(AudioExtractionService.targetSampleRate)
        let frameLen = Int(Double(sr) * 0.030) // 30 ms frames
        let hop = frameLen
        guard pcm.count >= frameLen else { return [] }
        let frameCount = (pcm.count - frameLen) / hop + 1

        var energy = [Float](repeating: 0, count: frameCount)
        pcm.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for f in 0..<frameCount {
                let start = f * hop
                let p = base.advanced(by: start)
                var mean: Float = 0
                vDSP_measqv(p, 1, &mean, vDSP_Length(frameLen))
                energy[f] = sqrtf(max(mean, 0))
            }
        }

        // Use a robust noise floor rather than a fraction of the loudest frame:
        // one clap or spike should not make quiet speech disappear.
        let sortedEnergy = energy.sorted()
        let p20 = sortedEnergy[min(sortedEnergy.count - 1, Int(Double(sortedEnergy.count) * 0.20))]
        let p80 = sortedEnergy[min(sortedEnergy.count - 1, Int(Double(sortedEnergy.count) * 0.80))]
        let threshold = min(max(p20 * 2.5, 0.008), max(0.02, p80 * 0.5))

        var speech = [Bool](repeating: false, count: frameCount)
        for f in 0..<frameCount where energy[f] > threshold {
            speech[f] = true
        }

        let gapFrames = Int((config.silenceSplitGap * Double(sr)) / Double(hop)) + 1
        let minFrames = max(1, Int((config.minSegmentDuration * Double(sr)) / Double(hop)) + 1)

        var ranges: [Range<Int>] = []
        var runStart: Int? = nil
        var silence = 0

        for f in 0..<frameCount {
            if speech[f] {
                if runStart == nil { runStart = f }
                silence = 0
            } else {
                silence += 1
                if let s = runStart, silence >= gapFrames {
                    let lo = s * hop
                    let hi = f * hop
                    if (hi - lo) / hop >= minFrames {
                        ranges.append(lo..<hi)
                    }
                    runStart = nil
                    silence = 0
                }
            }
            if f % 256 == 0 {
                let p = Double(f) / Double(frameCount)
                await progressHandler(p)
            }
        }
        if let s = runStart {
            let lo = s * hop
            let hi = min(frameCount * hop, pcm.count)
            if (hi - lo) / hop >= minFrames {
                ranges.append(lo..<hi)
            }
        }
        return ranges
    }
}

// MARK: - Speaker Embedding Abstraction
protocol SpeakerEmbedder: Sendable {
    var dimension: Int { get }
    func embed(_ samples: [Float], sampleRate: Float) async -> [Float]
}

/// Log-fbank statistics fallback. A production neural path must provide a
/// declared fbank input shape and verified output dimension; raw waveforms are
/// never passed to a generic Core ML model.
nonisolated final class SpectralEmbedder: SpeakerEmbedder, @unchecked Sendable {

    private let fftSize = 512
    private let hop = 256
    private let bandCount = 24

    var dimension: Int { bandCount * 2 }

    func embed(_ samples: [Float], sampleRate: Float) async -> [Float] {
        let targetDim = dimension
        let n = fftSize
        guard samples.count >= n else {
            return Self.energyStats(samples, dimension: targetDim)
        }

        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let log2n: Int = Int(log2(Double(n)))
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
            return Self.energyStats(samples, dimension: targetDim)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let frameCount = max(1, (samples.count - n) / hop + 1)
        var bandAccum = [Float](repeating: 0, count: bandCount)
        var bandSquaredAccum = [Float](repeating: 0, count: bandCount)

        let bins = n / 2
        let binHz = sampleRate / Float(n)
        let loHz: Float = 80
        let hiHz: Float = min(7600, sampleRate / 2)
        let edges = (0...bandCount).map { idx -> Int in
            let f = loHz * powf(hiHz / loHz, Float(idx) / Float(bandCount))
            return min(bins - 1, max(0, Int(f / binHz)))
        }

        var windowed = [Float](repeating: 0, count: n)
        var realp = [Float](repeating: 0, count: bins)
        var imagp = [Float](repeating: 0, count: bins)
        var mags = [Float](repeating: 0, count: bins)

        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for f in 0..<frameCount {
                let start = f * hop
                let framePtr = base.advanced(by: start)
                vDSP_vmul(framePtr, 1, win, 1, &windowed, 1, vDSP_Length(n))
                
                realp.withUnsafeMutableBufferPointer { rBuf in
                    imagp.withUnsafeMutableBufferPointer { iBuf in
                        var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                        windowed.withUnsafeBufferPointer { winBuf in
                            winBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                            }
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                    }
                }

                for b in 0..<bandCount {
                    let lo = edges[b]
                    let hi = max(lo + 1, edges[b + 1])
                    var bandMean: Float = 0
                    mags.withUnsafeBufferPointer { buffer in
                        vDSP_meanv(buffer.baseAddress!.advanced(by: lo), 1, &bandMean, vDSP_Length(hi - lo))
                    }
                    let value = log10f(bandMean + 1e-6)
                    bandAccum[b] += value
                    bandSquaredAccum[b] += value * value
                }
            }
        }

        var features = [Float](repeating: 0, count: targetDim)
        for b in 0..<bandCount {
            let mean = bandAccum[b] / Float(frameCount)
            features[b] = mean
            features[b + bandCount] = sqrtf(max(0, bandSquaredAccum[b] / Float(frameCount) - mean * mean))
        }

        var sq: Float = 0
        vDSP_dotpr(features, 1, features, 1, &sq, vDSP_Length(targetDim))
        let norm = max(sqrtf(sq), 1e-6)
        vDSP_vsdiv(features, 1, [norm], &features, 1, vDSP_Length(targetDim))

        return features
    }

    private static func energyStats(_ s: [Float], dimension: Int) -> [Float] {
        var stats = [Float](repeating: 0, count: dimension)
        guard !s.isEmpty else { return stats }
        var mean: Float = 0
        vDSP_meanv(s, 1, &mean, vDSP_Length(s.count))
        var sq = [Float](repeating: 0, count: s.count)
        vDSP_vsq(s, 1, &sq, 1, vDSP_Length(s.count))
        var meanSq: Float = 0
        vDSP_meanv(sq, 1, &meanSq, vDSP_Length(s.count))
        let std = sqrtf(max(meanSq - mean * mean, 0))
        var zc = 0
        for i in 1..<s.count {
            if (s[i - 1] >= 0) != (s[i] >= 0) { zc += 1 }
        }
        stats[0] = abs(mean); stats[1] = std
        stats[2] = sqrtf(max(meanSq, 0)); stats[3] = Float(zc) / Float(s.count)
        stats[4] = mean; stats[5] = meanSq
        stats[6] = s.max() ?? 0; stats[7] = s.min() ?? 0
        let norm = max(sqrtf(stats.reduce(0) { $0 + $1 * $1 }), 1e-6)
        var out = [Float](repeating: 0, count: stats.count)
        vDSP_vsdiv(stats, 1, [norm], &out, 1, vDSP_Length(stats.count))
        return out
    }

}

/// Validated ECAPA-TDNN Core ML speaker embedder.
///
/// The bundled `ECAPA_TDNN.mlmodelc` has a fixed, verified contract:
/// `mel_features: Float16[1, 80, 301] -> embedding: Float16[1, 192]`.
/// It never accepts raw PCM. Its standard 16 kHz log-mel frontend is generated
/// in code, making the packaged model self-contained.
nonisolated final class CoreMLModelCache: @unchecked Sendable {
    static let shared = CoreMLModelCache()
    let model: MLModel?
    private init() {
        let url = Bundle.main.url(forResource: "ECAPA_TDNN", withExtension: "mlmodelc", subdirectory: "Models")
            ?? Bundle.main.url(forResource: "ECAPA_TDNN", withExtension: "mlmodelc")
        guard let url else { model = nil; return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: url, configuration: configuration)
    }
}

nonisolated final class CoreMLSpeakerEmbedder: SpeakerEmbedder, @unchecked Sendable {
    private let model: MLModel?
    private let filterbank: [Float]
    private let window: [Float]
    private let fftSetup: FFTSetup?

    nonisolated var dimension: Int { DiarizationConfig.embeddingDimension }
    nonisolated var isAvailable: Bool {
        model != nil
    }

    private static let inputName = "mel_features"
    private static let outputName = "embedding"
    private static let sampleRate: Float = 16_000
    private static let melBands = 80
    private static let frameSize = 400
    private static let fftSize = 512
    private static let spectrumBins = 257
    private static let hopSize = 160
    /// Diarization uses 1.5-second speech windows.  The packaged ECAPA model's
    /// compiled default is 301 frames, however, and E5RT cannot execute its
    /// data-dependent mask graph with a dynamic third dimension.  Retaining
    /// the speech window and centring it in this fixed-size input avoids both
    /// a dynamic Core ML allocation and any variable-length model invocation.
    private static let speechWindowSamples = 24_000
    private static let expectedFrames = 301
    private static let modelInputSamples = frameSize + (expectedFrames - 1) * hopSize

    nonisolated init() {
        let filters = Self.makeHTKMelFilterbank()
        let analysisWindow = Self.makeHannWindow()

        if let loaded = CoreMLModelCache.shared.model {
            do {
                let input = loaded.modelDescription.inputDescriptionsByName[Self.inputName]
                let output = loaded.modelDescription.outputDescriptionsByName[Self.outputName]
                let inputShape = input?.multiArrayConstraint?.shape.map(\.intValue) ?? []
                guard input?.type == .multiArray, output?.type == .multiArray,
                      input?.multiArrayConstraint?.dataType == .float16,
                      inputShape.count == 3, inputShape[0] == 1, inputShape[1] == Self.melBands,
                      output?.multiArrayConstraint?.shape.last?.intValue == DiarizationConfig.embeddingDimension else {
                    AppLogger.shared.error("ECAPA model contract does not match mel_features[1,80,T] -> embedding[1,192].", category: .transcription)
                    self.model = nil
                    self.filterbank = []
                    self.window = []
                    self.fftSetup = nil
                    return
                }
                self.model = loaded
                self.filterbank = filters
                self.window = analysisWindow
                self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(Self.fftSize))), FFTRadix(kFFTRadix2))
                return
            }
        } else {
            AppLogger.shared.error("ECAPA_TDNN.mlmodelc is missing from the app bundle.", category: .transcription)
        }

        self.model = nil
        self.filterbank = []
        self.window = []
        self.fftSetup = nil
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func embed(_ samples: [Float], sampleRate: Float) async -> [Float] {
        guard let model, let fftSetup, sampleRate == Self.sampleRate else {
            return []
        }

        do {
            let fixedSamples = Self.makeFixedInputSamples(from: samples)
            let mel = try makeLogMel(samples: fixedSamples, fftSetup: fftSetup)
            let input = try MLMultiArray(
                shape: [1, NSNumber(value: Self.melBands), NSNumber(value: Self.expectedFrames)],
                dataType: .float16
            )
            let inputPointer = input.dataPointer.bindMemory(to: Float16.self, capacity: mel.count)
            // Core ML's [1, 80, T] storage is band-major; makeLogMel emits the
            // same layout and mean-normalizes each fbank band over time.
            for index in mel.indices { inputPointer[index] = Float16(mel[index]) }

            let provider = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(multiArray: input)])
            let result = try await model.prediction(from: provider)
            guard let output = result.featureValue(for: Self.outputName)?.multiArrayValue,
                  output.count == DiarizationConfig.embeddingDimension,
                  output.dataType == .float16 else {
                throw DiarizationError.clusteringFailed("ECAPA returned an invalid embedding shape")
            }

            let outputPointer = output.dataPointer.bindMemory(to: Float16.self, capacity: output.count)
            var embedding = (0..<output.count).map { Float(outputPointer[$0]) }
            var squaredNorm: Float = 0
            vDSP_dotpr(embedding, 1, embedding, 1, &squaredNorm, vDSP_Length(embedding.count))
            let norm = max(sqrtf(squaredNorm), 1e-6)
            vDSP_vsdiv(embedding, 1, [norm], &embedding, 1, vDSP_Length(embedding.count))
            return embedding
        } catch {
            AppLogger.shared.warning("ECAPA prediction failed: \(error)", category: .transcription)
            return []
        }
    }

    /// Uses Core ML's batch provider so a group of fixed-shape ECAPA windows
    /// can be scheduled together on ANE/GPU. Every provider retains its
    /// multi-array until prediction completes.
    func embedBatch(_ samples: [[Float]], sampleRate: Float) async throws -> [[Float]] {
        guard let model, let fftSetup, sampleRate == Self.sampleRate else {
            throw DiarizationError.clusteringFailed("Neural embedder unavailable")
        }
        var providers: [MLFeatureProvider] = []
        providers.reserveCapacity(samples.count)
        for slice in samples {
            let mel = try makeLogMel(samples: Self.makeFixedInputSamples(from: slice), fftSetup: fftSetup)
            let input = try MLMultiArray(shape: [1, NSNumber(value: Self.melBands), NSNumber(value: Self.expectedFrames)], dataType: .float16)
            let pointer = input.dataPointer.bindMemory(to: Float16.self, capacity: mel.count)
            for index in mel.indices { pointer[index] = Float16(mel[index]) }
            providers.append(try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(multiArray: input)]))
        }
        let outputs = try model.predictions(
            from: MLArrayBatchProvider(array: providers),
            options: MLPredictionOptions()
        )
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(outputs.count)
        for index in 0..<outputs.count {
            guard let array = outputs.features(at: index).featureValue(for: Self.outputName)?.multiArrayValue,
                  array.count == DiarizationConfig.embeddingDimension,
                  array.dataType == MLMultiArrayDataType.float16 else {
                throw DiarizationError.clusteringFailed("Malformed ECAPA embedding")
            }
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            var embedding = (0..<array.count).map { Float(pointer[$0]) }
            var normSquared: Float = 0
            vDSP_dotpr(embedding, 1, embedding, 1, &normSquared, vDSP_Length(embedding.count))
            var norm = max(sqrtf(normSquared), 1e-6)
            vDSP_vsdiv(embedding, 1, &norm, &embedding, 1, vDSP_Length(embedding.count))
            embeddings.append(embedding)
        }
        return embeddings
    }

    /// Supplies ECAPA's compiled 301-frame input without introducing a large
    /// silence bias: a short final window is repeated to fill the fixed model
    /// duration rather than padded with zeros.
    private static func makeFixedInputSamples(from samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [Float](repeating: 0, count: modelInputSamples) }
        if samples.count >= modelInputSamples { return Array(samples.prefix(modelInputSamples)) }
        var result: [Float] = []
        result.reserveCapacity(modelInputSamples)
        while result.count < modelInputSamples {
            result.append(contentsOf: samples.prefix(modelInputSamples - result.count))
        }
        return result
    }

    private func makeLogMel(samples: [Float], fftSetup: FFTSetup) throws -> [Float] {
        guard samples.count == Self.modelInputSamples else {
            throw DiarizationError.clusteringFailed("ECAPA input must contain \(Self.modelInputSamples) samples")
        }

        let frameCount = Self.expectedFrames
        var mel = [Float](repeating: 0, count: Self.melBands * frameCount)
        var frame = [Float](repeating: 0, count: Self.fftSize)
        var real = [Float](repeating: 0, count: Self.fftSize / 2)
        var imaginary = [Float](repeating: 0, count: Self.fftSize / 2)
        var power = [Float](repeating: 0, count: Self.spectrumBins)

        for frameIndex in 0..<frameCount {
            frame.withUnsafeMutableBufferPointer { destination in
                for index in destination.indices { destination[index] = 0 }
                let sourceStart = frameIndex * Self.hopSize
                let available = max(0, min(Self.frameSize, samples.count - sourceStart))
                if available > 0 {
                    samples.withUnsafeBufferPointer { source in
                        vDSP_vmul(source.baseAddress!.advanced(by: sourceStart), 1, window, 1, destination.baseAddress!, 1, vDSP_Length(available))
                    }
                }
            }

            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    frame.withUnsafeBufferPointer { frameBuffer in
                        frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2(Double(Self.fftSize))), FFTDirection(FFT_FORWARD))
                    // vDSP packs DC and Nyquist into the first split-complex
                    // entry. Expand that representation to all 257 bins so the
                    // 80-mel filterbank and 512-point FFT use matching shapes.
                    power[0] = split.realp[0] * split.realp[0]
                    power[Self.fftSize / 2] = split.imagp[0] * split.imagp[0]
                    for bin in 1..<(Self.fftSize / 2) {
                        power[bin] = split.realp[bin] * split.realp[bin] + split.imagp[bin] * split.imagp[bin]
                    }
                }
            }

            for band in 0..<Self.melBands {
                var energy: Float = 0
                filterbank.withUnsafeBufferPointer { filters in
                    power.withUnsafeBufferPointer { spectrum in
                        vDSP_dotpr(filters.baseAddress!.advanced(by: band * Self.spectrumBins), 1, spectrum.baseAddress!, 1, &energy, vDSP_Length(Self.spectrumBins))
                    }
                }
                mel[band * frameCount + frameIndex] = logf(max(energy, 1e-10))
            }
        }

        // SpeechBrain's ECAPA frontend uses utterance-level mean normalization.
        for band in 0..<Self.melBands {
            let offset = band * frameCount
            var mean: Float = 0
            mel.withUnsafeBufferPointer { buffer in
                vDSP_meanv(buffer.baseAddress!.advanced(by: offset), 1, &mean, vDSP_Length(frameCount))
            }
            var negativeMean = -mean
            mel.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsadd(buffer.baseAddress!.advanced(by: offset), 1, &negativeMean, buffer.baseAddress!.advanced(by: offset), 1, vDSP_Length(frameCount))
            }
        }
        return mel
    }

    private static func makeHannWindow() -> [Float] {
        var result = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&result, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        return result
    }

    /// Standard HTK mel filterbank: 80 triangular filters over 0...Nyquist.
    /// Keeping it in code avoids a fragile sidecar-resource contract.
    private static func makeHTKMelFilterbank() -> [Float] {
        func hzToMel(_ hertz: Double) -> Double { 2595 * log10(1 + hertz / 700) }
        func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

        let lowMel = hzToMel(0)
        let highMel = hzToMel(Double(sampleRate) / 2)
        let melPoints = (0..<(melBands + 2)).map {
            lowMel + (highMel - lowMel) * Double($0) / Double(melBands + 1)
        }
        let bins = melPoints.map {
            min(spectrumBins - 1, max(0, Int(round(Double(fftSize) * melToHz($0) / Double(sampleRate)))))
        }
        var filters = [Float](repeating: 0, count: melBands * spectrumBins)
        for band in 0..<melBands {
            let left = bins[band]
            let center = max(left + 1, bins[band + 1])
            let right = max(center + 1, bins[band + 2])
            if center > left {
                for bin in left..<min(center, spectrumBins) {
                    filters[band * spectrumBins + bin] = Float(bin - left) / Float(center - left)
                }
            }
            if right > center {
                for bin in center..<min(right, spectrumBins) {
                    filters[band * spectrumBins + bin] = Float(right - bin) / Float(right - center)
                }
            }
        }
        return filters
    }
}

// MARK: - Bounded Speaker Clustering
/// Bounded centroid clustering. Unlike the former all-pairs AHC implementation,
/// this stores no N×N distance matrix and is O(N·K·D), which keeps a two-hour
/// recording within a predictable memory and CPU budget.
nonisolated final class AgglomerativeClustering: @unchecked Sendable {

    private let dim: Int
    private let mergeThreshold: Float
    private let maxSpeakers: Int

    nonisolated init(
        embeddingDimension: Int,
        mergeThreshold: Float,
        maxSpeakers: Int
    ) {
        self.dim = embeddingDimension
        self.mergeThreshold = mergeThreshold
        self.maxSpeakers = maxSpeakers
    }

    /// - Parameters:
    ///   - segments: array of (startTime, endTime) for each embedding.
    ///   - embeddings: flattened [N * dim] embeddings.
    ///   - targetSpeakerCount: explicit speaker count to constrain clustering (nil for auto).
    /// - Returns: cluster label per segment.
    func cluster(
        segments: [(start: TimeInterval, end: TimeInterval)],
        embeddings: [Float],
        targetSpeakerCount: Int? = nil
    ) -> [Int] {
        let n = segments.count
        guard n > 0 else { return [] }
        guard embeddings.count >= n * dim, dim > 0 else { return Array(repeating: 0, count: n) }
        if n == 1 { return [0] }

        let requestedCount = targetSpeakerCount ?? 0
        if requestedCount > 0 {
            return kMeans(embeddings: embeddings, count: n, clusters: min(requestedCount, n), pruneSmallClusters: false)
        }
        return thresholdCluster(embeddings: embeddings, count: n)
    }

    private func kMeans(embeddings: [Float], count: Int, clusters: Int, pruneSmallClusters: Bool) -> [Int] {
        var centroids = [[Float]]()
        centroids.reserveCapacity(clusters)
        centroids.append(Array(embeddings[0..<dim]))
        while centroids.count < clusters {
            var distances = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let vector = Array(embeddings[(index * dim)..<((index + 1) * dim)])
                let closest = centroids.map { cosineDistance(vector, $0) }.min() ?? 0
                distances[index] = closest * closest
            }
            // Deterministic farthest-point K-Means++ seed: repeatable runs
            // make speaker labels stable across retries.
            let chosen = distances.indices.max { distances[$0] < distances[$1] } ?? 0
            centroids.append(Array(embeddings[(chosen * dim)..<((chosen + 1) * dim)]))
        }
        var labels = [Int](repeating: 0, count: count)
        for _ in 0..<20 {
            var changed = false
            var sums = Array(repeating: [Float](repeating: 0, count: dim), count: clusters)
            var sizes = [Int](repeating: 0, count: clusters)
            for index in 0..<count {
                let vector = Array(embeddings[(index * dim)..<((index + 1) * dim)])
                let nearest = centroids.indices.min { cosineDistance(vector, centroids[$0]) < cosineDistance(vector, centroids[$1]) } ?? 0
                changed = changed || labels[index] != nearest
                labels[index] = nearest
                sizes[nearest] += 1
                vDSP_vadd(sums[nearest], 1, vector, 1, &sums[nearest], 1, vDSP_Length(dim))
            }
            for cluster in 0..<clusters where sizes[cluster] > 0 {
                var divisor = Float(sizes[cluster])
                vDSP_vsdiv(sums[cluster], 1, &divisor, &centroids[cluster], 1, vDSP_Length(dim))
            }
            if !changed { break }
        }

        guard pruneSmallClusters else { return labels }
        // Reassign clusters too small to credibly represent a speaker. A
        // cluster must account for at least 5% of windows (and two windows).
        let minimumSize = max(2, Int(Double(count) * 0.05))
        let sizes = (0..<clusters).map { label in labels.filter { $0 == label }.count }
        let valid = (0..<clusters).filter { sizes[$0] >= minimumSize }
        guard !valid.isEmpty else { return labels }
        for index in 0..<count where !valid.contains(labels[index]) {
            let vector = Array(embeddings[(index * dim)..<((index + 1) * dim)])
            labels[index] = valid.min {
                cosineDistance(vector, centroids[$0]) < cosineDistance(vector, centroids[$1])
            } ?? valid[0]
        }
        return labels
    }

    private func thresholdCluster(embeddings: [Float], count: Int) -> [Int] {
        var centroids: [[Float]] = []
        var sizes: [Int] = []
        var labels = [Int](repeating: 0, count: count)
        for index in 0..<count {
            let vector = Array(embeddings[(index * dim)..<((index + 1) * dim)])
            let nearest = centroids.indices.min { cosineDistance(vector, centroids[$0]) < cosineDistance(vector, centroids[$1]) }
            let label: Int
            if let nearest, cosineDistance(vector, centroids[nearest]) < mergeThreshold || centroids.count >= maxSpeakers {
                label = nearest ?? 0
            } else {
                centroids.append(vector)
                sizes.append(0)
                label = centroids.count - 1
            }
            labels[index] = label
            sizes[label] += 1
            let weight = 1 / Float(sizes[label])
            for component in 0..<dim {
                centroids[label][component] += weight * (vector[component] - centroids[label][component])
            }
        }
        // Online assignments can split a voice before its centroids converge.
        // Merge those sustained clusters before deciding which clusters are tiny.
        if centroids.count > 1 {
            var parent = Array(centroids.indices)
            func find(_ index: Int) -> Int {
                var root = index
                while parent[root] != root { root = parent[root] }
                return root
            }
            for i in centroids.indices where sizes[i] > 0 {
                for j in (i + 1)..<centroids.count where sizes[j] > 0 {
                    if cosineDistance(centroids[i], centroids[j]) < mergeThreshold * 1.15 {
                        let left = find(i), right = find(j)
                        if left != right { parent[right] = left }
                    }
                }
            }
            for index in labels.indices { labels[index] = find(labels[index]) }

            // Pruning and nearest-centroid reassignment must use the merged
            // population and weighted centroid, rather than pre-merge sizes.
            var mergedSizes = [Int](repeating: 0, count: centroids.count)
            var mergedSums = Array(repeating: [Float](repeating: 0, count: dim), count: centroids.count)
            for cluster in centroids.indices where sizes[cluster] > 0 {
                let root = find(cluster)
                mergedSizes[root] += sizes[cluster]
                for component in 0..<dim {
                    mergedSums[root][component] += centroids[cluster][component] * Float(sizes[cluster])
                }
            }
            for root in centroids.indices where mergedSizes[root] > 0 {
                for component in 0..<dim {
                    centroids[root][component] = mergedSums[root][component] / Float(mergedSizes[root])
                }
            }
            sizes = mergedSizes
        }
        // Auto mode only: reject tiny accidental clusters created by short,
        // noisy windows and assign them to the nearest sustained centroid.
        let minimumSize = max(2, Int(Double(count) * 0.05))
        let valid = centroids.indices.filter { sizes[$0] >= minimumSize }
        if !valid.isEmpty {
            for index in 0..<count where !valid.contains(labels[index]) {
                let vector = Array(embeddings[(index * dim)..<((index + 1) * dim)])
                labels[index] = valid.min { cosineDistance(vector, centroids[$0]) < cosineDistance(vector, centroids[$1]) } ?? valid[0]
            }
        }
        return labels
    }

    private func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0, lhsNorm: Float = 0, rhsNorm: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, vDSP_Length(dim))
        vDSP_dotpr(lhs, 1, lhs, 1, &lhsNorm, vDSP_Length(dim))
        vDSP_dotpr(rhs, 1, rhs, 1, &rhsNorm, vDSP_Length(dim))
        return max(0, 1 - dot / max(sqrtf(lhsNorm * rhsNorm), 1e-6))
    }
}
