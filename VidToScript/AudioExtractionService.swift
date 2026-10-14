//  AudioExtractionService.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import AVFoundation

// MARK: - Audio Extraction Protocol
/// Protocol defining the interface for audio extraction operations.
/// Implementations isolate the primary audio track from a video container and
/// transcode it to a 16 kHz, 16-bit, mono linear-PCM WAV file.
protocol AudioExtractionServiceProtocol: Sendable {
    /// Extract audio from a video file.
    /// - Parameters:
    ///   - videoURL: URL of the source video file.
    ///   - projectID: Unique identifier for the project (used to name the temp WAV).
    ///   - progressHandler: Closure called with progress updates (0.0 to 1.0).
    /// - Returns: Result containing audio extraction details or error.
    func extractAudio(
        from videoURL: URL,
        projectID: UUID,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> Result<AudioExtractionResult, AudioExtractionError>

    /// Cancel any ongoing extraction.
    func cancelExtraction() async

    /// Validate if a video file can be processed.
    /// - Parameter videoURL: URL of the video file.
    /// - Returns: Validation result.
    func validateVideo(_ videoURL: URL) async -> VideoValidationResult
}

// MARK: - Audio Extraction Error
enum AudioExtractionError: Error, LocalizedError, Equatable {
    case invalidVideoFile
    case unsupportedVideoFormat(String)
    case audioTrackNotFound
    case extractionFailed(String)
    case resamplingFailed(String)
    case fileWriteFailed(String)
    case cancelled
    case insufficientStorage
    case invalidOutputFormat
    case videoTooLong(duration: TimeInterval, maxDuration: TimeInterval)
    case processingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidVideoFile:
            return "The selected file is not a valid video."
        case .unsupportedVideoFormat(let format):
            return "Video format '\(format)' is not supported."
        case .audioTrackNotFound:
            return "No audio track found in the video file."
        case .extractionFailed(let reason):
            return "Audio extraction failed: \(reason)"
        case .resamplingFailed(let reason):
            return "Audio resampling failed: \(reason)"
        case .fileWriteFailed(let reason):
            return "Failed to write audio file: \(reason)"
        case .cancelled:
            return "Audio extraction was cancelled."
        case .insufficientStorage:
            return "Not enough storage space available."
        case .invalidOutputFormat:
            return "Invalid output audio format."
        case .videoTooLong(let duration, let max):
            return "Video duration (\(Int(duration / 60)) min) exceeds maximum (\(Int(max / 60)) min)."
        case .processingError(let message):
            return "Processing error: \(message)"
        }
    }
}

// MARK: - Video Validation Result
struct VideoValidationResult: Sendable {
    let isValid: Bool
    let duration: TimeInterval?
    let fileSize: Int64?
    let videoCodec: String?
    let audioCodec: String?
    let error: AudioExtractionError?

    nonisolated static func valid(duration: TimeInterval, fileSize: Int64, videoCodec: String, audioCodec: String) -> VideoValidationResult {
        VideoValidationResult(isValid: true, duration: duration, fileSize: fileSize,
                              videoCodec: videoCodec, audioCodec: audioCodec, error: nil)
    }

    nonisolated static func invalid(error: AudioExtractionError) -> VideoValidationResult {
        VideoValidationResult(isValid: false, duration: nil, fileSize: nil,
                              videoCodec: nil, audioCodec: nil, error: error)
    }
}

// MARK: - Audio Extraction Service Implementation
/// Extracts and transcodes audio from a video container into a canonical
/// 16 kHz / 16-bit / mono PCM WAV file using `AVAssetReader`.
///
/// The WAV is written **streamingly** into `FileManager.default.temporaryDirectory`
/// (44-byte RIFF header written first, PCM appended in chunks, then the chunk
/// sizes are patched in place). This keeps peak RAM low regardless of duration:
/// only one decoded sample buffer is held in memory at a time. All video frame
/// buffers are invalidated and the asset reader is released as soon as the
/// extraction completes.
actor AudioExtractionService: AudioExtractionServiceProtocol {

    // MARK: - Properties
    private var currentAssetReader: AVAssetReader?
    private var isCancelled: Bool = false
    private let fileManager = FileManager.default

    // MARK: - Constants (canonical on-device ASR format)
    /// 16 kHz sample rate — required by the Whisper mel feature extractor.
    nonisolated static let targetSampleRate: Double = 16000.0
    nonisolated static let targetBitDepth: Int = 16
    nonisolated static let targetChannelCount: Int = 1
    private let maxVideoDuration: TimeInterval = 7200 // 2 hours
    /// Containers supported for the primary audio track isolation.
    private let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "wav", "m4a", "aac", "mp3"]

    // MARK: - Initialization
    init() {}

    // MARK: - Public Methods
    func extractAudio(
        from videoURL: URL,
        projectID: UUID,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async -> Result<AudioExtractionResult, AudioExtractionError> {

        // Reset cancellation state for this run.
        isCancelled = false

        // Validate input.
        let validation = await validateVideo(videoURL)
        guard validation.isValid else {
            return .failure(validation.error ?? .invalidVideoFile)
        }

        guard !isCancelled else { return .failure(.cancelled) }

        await progressHandler(0.05)

        do {
            let asset = AVURLAsset(url: videoURL)

            // Isolate the primary audio track.
            guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                return .failure(.audioTrackNotFound)
            }

            await progressHandler(0.15)

            guard !isCancelled else { return .failure(.cancelled) }

            // Keep the derived audio with its project. `/tmp` is purgeable and must
            // never be persisted as part of a project record.
            let outputURL = try makeProjectWAVURL(for: projectID)

            // Remove any stale file at that path.
            if fileManager.fileExists(atPath: outputURL.path) {
                try? fileManager.removeItem(at: outputURL)
            }

            let result = try await extractAndResampleAudio(
                from: asset,
                audioTrack: audioTrack,
                outputURL: outputURL,
                progressHandler: progressHandler
            )

            return .success(result)
        } catch let error as AudioExtractionError {
            return .failure(error)
        } catch {
            return .failure(.extractionFailed(error.localizedDescription))
        }
    }

    nonisolated func cancelExtraction() async {
        await setCancelled(true)
        await cancelReader()
    }

    private func setCancelled(_ value: Bool) {
        isCancelled = value
    }

    private func cancelReader() {
        currentAssetReader?.cancelReading()
    }

    func validateVideo(_ videoURL: URL) async -> VideoValidationResult {
        guard fileManager.fileExists(atPath: videoURL.path) else {
            return VideoValidationResult.invalid(error: .invalidVideoFile)
        }

        let fileSize: Int64
        do {
            let attributes = try fileManager.attributesOfItem(atPath: videoURL.path)
            fileSize = attributes[.size] as? Int64 ?? 0
        } catch {
            return VideoValidationResult.invalid(error: .invalidVideoFile)
        }

        let fileExtension = videoURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            return VideoValidationResult.invalid(error: .unsupportedVideoFormat(fileExtension))
        }

        let asset = AVURLAsset(url: videoURL)

        let duration: TimeInterval
        do {
            let cmDuration = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmDuration)
        } catch {
            return VideoValidationResult.invalid(error: .invalidVideoFile)
        }

        guard duration > 0 else {
            return VideoValidationResult.invalid(error: .invalidVideoFile)
        }

        guard duration <= maxVideoDuration else {
            return VideoValidationResult.invalid(error: .videoTooLong(duration: duration, maxDuration: maxVideoDuration))
        }

        let audioTrack: AVAssetTrack?
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            audioTrack = audioTracks.first
        } catch {
            audioTrack = nil
        }

        guard let audioTrack else {
            return VideoValidationResult.invalid(error: .audioTrackNotFound)
        }
        let descriptions = (try? await audioTrack.load(.formatDescriptions)) ?? []
        let audioCodec: String
        if let description = descriptions.first {
            let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            audioCodec = basic?.mFormatID == kAudioFormatLinearPCM ? "pcm" : "compressed"
        } else {
            audioCodec = "unknown"
        }

        return VideoValidationResult.valid(duration: duration, fileSize: fileSize,
                                           videoCodec: fileExtension, audioCodec: audioCodec)
    }

    // MARK: - Private Methods

    private func makeProjectWAVURL(for projectID: UUID) throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AudioExtractionError.fileWriteFailed("Cannot access the Documents directory")
        }
        let directory = documentsURL
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory.appendingPathComponent("audio.wav")
    }

    private func extractAndResampleAudio(
        from asset: AVAsset,
        audioTrack: AVAssetTrack,
        outputURL: URL,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async throws -> AudioExtractionResult {

        // Create the asset reader.
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioExtractionError.extractionFailed("Failed to create asset reader: \(error.localizedDescription)")
        }
        self.currentAssetReader = reader

        guard !isCancelled else { throw AudioExtractionError.cancelled }

        // Decode directly to the canonical PCM format (AVFoundation performs the
        // resampling / downmix to mono / 16-bit for us).
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: Self.targetChannelCount,
            AVLinearPCMBitDepthKey: Self.targetBitDepth,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        // Avoid spurious copies of the decoded PCM — we read the raw block buffer.
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            self.currentAssetReader = nil
            throw AudioExtractionError.extractionFailed("Cannot add track output to reader")
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            let error = reader.error ?? NSError(domain: ErrorDomain.audio, code: -1)
            self.currentAssetReader = nil
            throw AudioExtractionError.extractionFailed("Failed to start reading: \(error.localizedDescription)")
        }

        await progressHandler(0.20)

        // Stream PCM into the WAV file, patching the header sizes at the end.
        let totalDataBytes = try await streamPCM(
            from: trackOutput,
            to: outputURL,
            progressHandler: progressHandler
        )

        guard !isCancelled else {
            self.currentAssetReader = nil
            throw AudioExtractionError.cancelled
        }

        // Release the reader (and any retained decoder buffers) immediately.
        reader.cancelReading()
        self.currentAssetReader = nil

        await progressHandler(0.95)

        let fileSize = try await getFileSize(at: outputURL)

        let duration = calculateDuration(dataSize: totalDataBytes)

        await progressHandler(1.0)

        return AudioExtractionResult(
            audioURL: outputURL,
            duration: duration,
            sampleRate: Self.targetSampleRate,
            channelCount: Self.targetChannelCount,
            fileSize: fileSize,
            format: .wav
        )
    }

    /// Streams decoded PCM sample buffers into a WAV file on disk.
    /// Writes the 44-byte RIFF/WAVE/fmt/data header first (with zeroed sizes),
    /// appends each chunk's raw PCM bytes, then patches the RIFF and data chunk
    /// sizes in place. Only one sample buffer is alive at any moment.
    private func streamPCM(
        from trackOutput: AVAssetReaderTrackOutput,
        to outputURL: URL,
        progressHandler: @Sendable @escaping (Double) async -> Void
    ) async throws -> Int {

        guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: nil) else {
            throw AudioExtractionError.fileWriteFailed("Cannot create output file")
        }

        let fileHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? fileHandle.close() }

        // Write placeholder header (sizes patched later).
        try fileHandle.write(contentsOf: Self.wavHeaderPlaceholder())

        var totalDataBytes: Int = 0
        var packetCount: Int = 0
        let progressSpan: Double = 0.70 // 0.20 -> 0.90
        let durationSeconds = try await estimatedDurationForProgress() ?? 0

        while readerIsRunning(trackOutput) {
            guard !isCancelled else { throw AudioExtractionError.cancelled }

            let sampleBuffer = trackOutput.copyNextSampleBuffer()
            guard let sampleBuffer = sampleBuffer else { break }

            // Keep autoreleased bridging objects bounded per chunk.
            let written: Int = try autoreleasepool {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                    return 0
                }
                var lengthAtOffset: Int = 0
                var totalLength: Int = 0
                var dataPointer: UnsafeMutablePointer<Int8>?

                let status = CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: &lengthAtOffset,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer
                )

                guard status == noErr, totalLength > 0 else {
                    return 0
                }

                // A CMBlockBuffer may be non-contiguous.  `dataPointer` only
                // covers `lengthAtOffset`, so copying `totalLength` from it is
                // unsafe.  CMBlockBufferCopyDataBytes handles both layouts.
                var chunk = Data(count: totalLength)
                let copyStatus = chunk.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                               dataLength: totalLength,
                                               destination: bytes.baseAddress!)
                }
                guard copyStatus == noErr else {
                    throw AudioExtractionError.extractionFailed("Could not read decoded audio buffer")
                }
                try fileHandle.write(contentsOf: chunk)
                return totalLength
            }

            totalDataBytes += written
            packetCount += 1

            if packetCount % 8 == 0 {
                let fraction: Double
                if durationSeconds > 0 {
                    fraction = min(Double(totalDataBytes) / Double(max(1, Self.bytesPerSecond() * Int(durationSeconds))), 1.0)
                } else {
                    fraction = min(Double(packetCount) / 10000.0, 1.0)
                }
                await progressHandler(0.20 + progressSpan * fraction)
            }
        }

        // `copyNextSampleBuffer()` returning nil is also how AVFoundation
        // reports a decode failure.  Distinguish it from a clean EOF.
        if let reader = currentAssetReader, reader.status == .failed {
            throw AudioExtractionError.extractionFailed(reader.error?.localizedDescription ?? "Audio reader failed")
        }

        // Patch RIFF chunk size (36 + dataSize) and data chunk size (dataSize).
        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: UInt32(36 + totalDataBytes).littleEndianBytes)
        try fileHandle.seek(toOffset: 40)
        try fileHandle.write(contentsOf: UInt32(totalDataBytes).littleEndianBytes)

        return totalDataBytes
    }

    /// `AVAssetReaderTrackOutput.copyNextSampleBuffer()` returns `nil` when the
    /// reader has exhausted its data OR encountered an error. We surface reader
    /// errors here so a failed decode does not look like a clean EOF.
    private func readerIsRunning(_ trackOutput: AVAssetReaderTrackOutput) -> Bool {
        guard let reader = currentAssetReader else { return false }
        return reader.status == .reading
    }

    private func estimatedDurationForProgress() async throws -> TimeInterval? {
        guard let reader = currentAssetReader else { return nil }
        let duration = try? await reader.asset.load(.duration)
        return duration.map { CMTimeGetSeconds($0) }
    }

    private func getFileSize(at url: URL) async throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    private func calculateDuration(dataSize: Int) -> TimeInterval {
        let bytesPerSecond = Int(Self.targetSampleRate) * Self.targetChannelCount * (Self.targetBitDepth / 8)
        guard bytesPerSecond > 0 else { return 0 }
        return TimeInterval(dataSize) / TimeInterval(bytesPerSecond)
    }

    // MARK: - WAV Header Helpers

    nonisolated static func bytesPerSecond() -> Int {
        Int(targetSampleRate) * targetChannelCount * (targetBitDepth / 8)
    }

    /// Builds the 44-byte canonical WAV header with zeroed chunk sizes. The
    /// RIFF and data chunk sizes are patched in place once the PCM length is known.
    nonisolated static func wavHeaderPlaceholder() -> Data {
        var header = Data(count: 44)

        // "RIFF"
        header[0] = 0x52; header[1] = 0x49; header[2] = 0x46; header[3] = 0x46
        // chunk size placeholder (offset 4) -> patched later
        // "WAVE"
        header[8] = 0x57; header[9] = 0x41; header[10] = 0x56; header[11] = 0x45
        // "fmt "
        header[12] = 0x66; header[13] = 0x6d; header[14] = 0x74; header[15] = 0x20
        // subchunk1 size = 16
        header[16] = 16
        // audio format = 1 (PCM)
        header[20] = 1
        // num channels = 1
        header[22] = 1
        // sample rate = 16000 (little-endian)
        let sampleRate = UInt32(targetSampleRate)
        header[24] = UInt8(sampleRate & 0xFF)
        header[25] = UInt8((sampleRate >> 8) & 0xFF)
        header[26] = UInt8((sampleRate >> 16) & 0xFF)
        header[27] = UInt8((sampleRate >> 24) & 0xFF)
        // byte rate = sampleRate * channels * bits/8
        let byteRate = UInt32(bytesPerSecond())
        header[28] = UInt8(byteRate & 0xFF)
        header[29] = UInt8((byteRate >> 8) & 0xFF)
        header[30] = UInt8((byteRate >> 16) & 0xFF)
        header[31] = UInt8((byteRate >> 24) & 0xFF)
        // block align = channels * bits/8 = 2
        header[32] = 2
        // bits per sample = 16
        header[34] = 16
        // "data"
        header[36] = 0x64; header[37] = 0x61; header[38] = 0x74; header[39] = 0x61
        // data size placeholder (offset 40) -> patched later

        return header
    }
}

// MARK: - Little-Endian Helpers
private extension UInt32 {
    nonisolated var littleEndianBytes: Data {
        var value = self.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
