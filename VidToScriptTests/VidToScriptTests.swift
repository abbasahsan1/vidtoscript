import XCTest
@testable import VidToScript

final class VidToScriptTests: XCTestCase {
    func testTranscriptTextCleanerRemovesEnglishAndUrduFillers() {
        let text = "Um, this is yani a test مطلب sentence with uh, fillers."
        let cleaned = TranscriptTextCleaner.clean(text)
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("um"))
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("yani"))
        XCTAssertFalse(cleaned.contains("مطلب"))
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("uh"))
        XCTAssertTrue(cleaned.contains("test"))
        XCTAssertTrue(cleaned.contains("sentence"))
    }

    func testAgglomerativeClusteringPrunesSpuriousClusters() {
        let clusterer = AgglomerativeClustering(embeddingDimension: 2, mergeThreshold: 0.35, maxSpeakers: 4)
        var embeddings = [Float](repeating: 0, count: 200)
        for index in 0..<97 { embeddings[index * 2] = 1 }
        for index in 97..<100 { embeddings[index * 2 + 1] = 1 }
        let segments = (0..<100).map { (start: Double($0), end: Double($0) + 1) }
        XCTAssertEqual(Set(clusterer.cluster(segments: segments, embeddings: embeddings, targetSpeakerCount: 2)).count, 1)
    }

    func testWAVHeaderPlaceholderValidity() {
        let header = AudioExtractionService.wavHeaderPlaceholder()
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(String(data: header[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: header[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: header[36..<40], encoding: .ascii), "data")
    }
    func testSingleSpeakerTranscriptRemainsBoundedWithoutLosingWords() {
        let words = (0..<1200).map { WordTiming(word: "word", startTime: Double($0), endTime: Double($0) + 0.4) }
        let raw = [RawASRSegment(startTime: 0, endTime: 1200, text: "", words: words)]
        for turns in [[], [DiarizationSegment(startTime: 0, endTime: 1200, speakerID: "Speaker 1")]] {
            let result = TranscribeService.attributeSpeakers(rawSegments: raw, diarization: turns)
            XCTAssertGreaterThan(result.count, 100)
            XCTAssertTrue(result.allSatisfy { $0.endTime - $0.startTime <= 8 })
            XCTAssertEqual(result.flatMap(\.words), words)
        }
    }

    func testSpeakerPauseAndSentenceBoundaries() {
        for punctuation in [".", "?", "!", "۔", "؟"] {
            let words = [
                WordTiming(word: "hello" + punctuation, startTime: 0, endTime: 0.4),
                WordTiming(word: "next", startTime: 0.5, endTime: 0.9),
                WordTiming(word: "pause", startTime: 1.6, endTime: 2.0),
                WordTiming(word: "speaker", startTime: 2.1, endTime: 2.5)
            ]
            let result = TranscribeService.attributeSpeakers(
                rawSegments: [RawASRSegment(startTime: 0, endTime: 2.5, text: "", words: words)],
                diarization: [DiarizationSegment(startTime: 0, endTime: 2, speakerID: "Speaker 1"),
                              DiarizationSegment(startTime: 2.1, endTime: 3, speakerID: "Speaker 2")])
            XCTAssertEqual(result.count, 4)
            XCTAssertEqual(result.last?.speakerID, "Speaker 2")
            XCTAssertEqual(result.flatMap(\.words), words)
        }
    }

    func testSilenceHallucinationsAreFilteredWithOneSecondTolerance() {
        let raw = [
            RawASRSegment(startTime: 0, endTime: 1, text: "hallucination", words: []),
            RawASRSegment(startTime: 9, endTime: 9.5, text: "near speech", words: []),
            RawASRSegment(startTime: 10, endTime: 11, text: "speech", words: [])
        ]
        let result = TranscribeService.attributeSpeakers(rawSegments: raw,
            diarization: [DiarizationSegment(startTime: 10, endTime: 12, speakerID: "Speaker 2")])
        XCTAssertEqual(result.flatMap(\.words).map(\.word), ["near speech", "speech"])
        XCTAssertTrue(result.allSatisfy { $0.speakerID == "Speaker 2" })
    }

    func testDetectionUsesFourBoundedSpeechWindowsInsteadOfIntro() {
        let sr = Int(AudioExtractionService.targetSampleRate)
        let turns: [DiarizationSegment] = (0..<6).map { index in
            let start = Double(40 + index * 40)
            return DiarizationSegment(startTime: start, endTime: start + 35, speakerID: "Speaker 1")
        }
        let ranges = TranscribeService.languageDetectionRanges(sampleCount: 300 * sr, diarization: turns)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertTrue(ranges.allSatisfy { $0.lowerBound >= 40 * sr && $0.count <= 30 * sr })
        XCTAssertEqual(TranscribeService.languageDetectionRanges(sampleCount: sr, diarization: []), [0..<sr])
        XCTAssertTrue(TranscribeService.languageDetectionRanges(sampleCount: 0, diarization: []).isEmpty)
    }

    func testLanguageScoresAreConstrainedAndRespectScriptPreference() {
        let scores: [String: Float] = ["ru": 4, "hi": 2, "ur": 1, "en": 0.8]
        XCTAssertEqual(TranscribeService.resolvedLanguage(probabilities: scores, preferUrdu: true), "ur")
        XCTAssertEqual(TranscribeService.resolvedLanguage(probabilities: scores, preferUrdu: false), "hi")
        for language in ["en", "ar", "es", "fr", "de", "ja", "zh"] {
            XCTAssertEqual(TranscribeService.resolvedLanguage(probabilities: [language: 3, "hi": 1], preferUrdu: true), language)
        }
        XCTAssertTrue(TranscribeService.initialPrompt(for: "en", fallback: nil)?.hasPrefix("This is an English") == true)
        XCTAssertNil(TranscribeService.initialPrompt(for: "es", fallback: nil))
    }

    @MainActor
    func testDetectedLanguageSurvivesProjectSnapshotAndPersistenceReload() {
        let persisted = PersistedProject(title: "Auto", targetLanguage: "auto", detectedLanguage: "es")
        let runtime = VideoProject(from: persisted)
        XCTAssertEqual(runtime.detectedLanguage, "es")
        XCTAssertEqual(ProjectSnapshot(runtime).detectedLanguage, "es")
        XCTAssertNil(VideoProject(from: PersistedProject(title: "Legacy")).detectedLanguage)
    }

    func testCJKAttributionDoesNotInsertSpaces() {
        for (language, tokens, expected) in [("zh", ["你", "好", "。"], "你好。"),
                                              ("ja", ["こん", "にちは", "。"], "こんにちは。"),
                                              ("en", ["hello", "world"], "hello world")] {
            let words = tokens.enumerated().map { index, token in
                WordTiming(word: token, startTime: Double(index) * 0.3, endTime: Double(index) * 0.3 + 0.2)
            }
            let result = TranscribeService.attributeSpeakers(
                rawSegments: [RawASRSegment(startTime: 0, endTime: 1, text: expected, words: words)],
                diarization: [], languageCode: language)
            XCTAssertEqual(result.map(\.text), [expected])
            XCTAssertEqual(result.flatMap(\.words), words)
        }
    }

    func testAutoClusteringMergesConvergedSustainedClusters() {
        let clusterer = AgglomerativeClustering(embeddingDimension: 2, mergeThreshold: 0.35, maxSpeakers: 4)
        func vector(_ degrees: Float) -> [Float] {
            let radians = degrees * .pi / 180
            return [cos(radians), sin(radians)]
        }
        // Initially separate centroids, then one voice drifts towards the other.
        let vectors = [vector(0), vector(60)]
            + Array(repeating: vector(20), count: 49) + Array(repeating: vector(60), count: 49)
        let segments = vectors.indices.map { (start: Double($0), end: Double($0) + 1) }
        let embeddings = vectors.flatMap { $0 }
        XCTAssertEqual(Set(clusterer.cluster(segments: segments, embeddings: embeddings)).count, 1)
        XCTAssertEqual(Set(clusterer.cluster(segments: segments, embeddings: embeddings, targetSpeakerCount: 2)).count, 2)
        let distinct = Array(repeating: vector(0), count: 50) + Array(repeating: vector(120), count: 50)
        XCTAssertEqual(Set(clusterer.cluster(segments: segments, embeddings: distinct.flatMap { $0 })).count, 2)
    }

    func testUrduCharactersSurviveEveryBPEByteBoundary() {
        let text = "پہاڑ ڈبہ ٹماٹر"
        let bytes = Array(text.utf8)
        for split in 1..<bytes.count {
            let tokens = [ASRTokenBytes(bytes: Array(bytes[..<split]), startTime: 0, endTime: 0),
                          ASRTokenBytes(bytes: Array(bytes[split...]), startTime: 0, endTime: 0)]
            let words = TranscribeService.wordTimings(from: tokens, segmentStart: 4, segmentEnd: 19)
            XCTAssertEqual(words.map(\.word).joined(separator: " "), text)
            XCTAssertFalse(words.contains { $0.word.contains("\u{FFFD}") })
            XCTAssertEqual(words.first?.startTime, 4)
            XCTAssertEqual(words.last?.endTime, 19)
        }
    }

    func testDegenerateTokenTimingsUseSegmentDurationAndByteWeights() {
        let tokens = [ASRTokenBytes(bytes: Array(" a".utf8), startTime: 0, endTime: 0),
                      ASRTokenBytes(bytes: Array(" bbb".utf8), startTime: -1, endTime: -1)]
        let words = TranscribeService.wordTimings(from: tokens, segmentStart: 10, segmentEnd: 26)
        XCTAssertEqual(words.map(\.word), ["a", "bbb"])
        XCTAssertEqual(words[0].startTime, 10)
        XCTAssertEqual(words[0].endTime, 14)
        XCTAssertEqual(words[1].startTime, 14)
        XCTAssertEqual(words[1].endTime, 26)
        let segments = TranscribeService.attributeSpeakers(
            rawSegments: [RawASRSegment(startTime: 10, endTime: 26, text: "a bbb", words: words)], diarization: [])
        XCTAssertEqual(segments.last?.endTime, 26)
    }

    func testValidWordTimingsAreAnchoredAndPreservePauses() {
        let tokens = [ASRTokenBytes(bytes: Array(" one".utf8), startTime: 11, endTime: 14),
                      ASRTokenBytes(bytes: Array(" two".utf8), startTime: 16, endTime: 19)]
        let words = TranscribeService.wordTimings(from: tokens, segmentStart: 10, segmentEnd: 20)
        XCTAssertEqual(words.first?.startTime, 10)
        XCTAssertEqual(words.last?.endTime, 20)
        XCTAssertGreaterThan(words[1].startTime - words[0].endTime, 0.6)
        XCTAssertTrue(words.allSatisfy { $0.startTime >= 10 && $0.endTime <= 20 && $0.endTime >= $0.startTime })
        let zeroDuration = TranscribeService.wordTimings(from: tokens, segmentStart: 10, segmentEnd: 10)
        XCTAssertTrue(zeroDuration.allSatisfy { $0.startTime == 10 && $0.endTime == 10 })
    }

    func testMultipleWordsInOneTokenDoNotProduceZeroLengthTimings() {
        let words = TranscribeService.wordTimings(
            from: [ASRTokenBytes(bytes: Array(" a bbb".utf8), startTime: 10, endTime: 26)],
            segmentStart: 10, segmentEnd: 26)
        XCTAssertEqual(words[0].endTime, 14)
        XCTAssertEqual(words[1].startTime, 14)
        XCTAssertEqual(words[1].endTime, 26)
    }

    func testCJKWordTimingsSplitCompleteCharactersAcrossBPEBoundaries() {
        for (language, text) in [("zh", "你好世界。"), ("ja", "こんにちは世界。") ] {
            let bytes = Array(text.utf8)
            for split in 1..<bytes.count {
                let tokens = [ASRTokenBytes(bytes: Array(bytes[..<split]), startTime: 0, endTime: 0),
                              ASRTokenBytes(bytes: Array(bytes[split...]), startTime: 0, endTime: 0)]
                let words = TranscribeService.wordTimings(from: tokens, segmentStart: 10, segmentEnd: 30,
                                                         languageCode: language)
                XCTAssertEqual(words.map(\.word), text.map { String($0) })
                XCTAssertEqual(words.first?.startTime, 10)
                XCTAssertEqual(words.last?.endTime, 30)
                XCTAssertTrue(words.allSatisfy { $0.endTime > $0.startTime })
                let segments = TranscribeService.attributeSpeakers(
                    rawSegments: [RawASRSegment(startTime: 10, endTime: 30, text: text, words: words)],
                    diarization: [], languageCode: language)
                XCTAssertGreaterThan(segments.count, 1)
                XCTAssertEqual(segments.map(\.text).joined(), text)
            }
        }
    }

}
