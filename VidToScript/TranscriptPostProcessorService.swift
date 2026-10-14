//
//  TranscriptPostProcessorService.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One conservative, shared clean-mode policy for the editor, summaries, and
/// every exporter. Words such as “so”, “like”, “actually”, “تو”, and “مطلب”
/// are meaningful in ordinary English/Urdu speech and are intentionally not
/// removed.
enum TranscriptTextCleaner {
    private static let fillerPattern = #"(?i)\b(?:um+|uh+|er+|you know|yani)\b[\s,]*|(?:یعنی|مطلب|تو نا|سمجھیں|دیکھیں)[\s،]*"#
    private static let regex = try! NSRegularExpression(pattern: fillerPattern)

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SummaryResult: Equatable {
    let executiveSummary: [String]
    let actionItems: [String]
}

actor SummaryCache {
    static let shared = SummaryCache()
    private var values: [Int: SummaryResult] = [:]
    func get(_ key: Int) -> SummaryResult? { values[key] }
    func set(_ key: Int, result: SummaryResult) { values[key] = result }
}

@Observable
final class TranscriptPostProcessorService {
    
    // MARK: - Cleaning Utilities
    private func cleanBulletPoint(_ text: String) -> String {
        var str = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Strip leading hyphens, asterisks, and bullets
        while let first = str.first, (first == "-" || first == "*" || first == "•" || first.isWhitespace) {
            str.removeFirst()
            str = str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // 2. Strip prefixes
        let prefixes = [
            "Mentioned key specification or detail:",
            "Mentioned key specification:",
            "Mentioned detail:",
            "Key spec:"
        ]
        for prefix in prefixes {
            if str.lowercased().hasPrefix(prefix.lowercased()) {
                str.removeFirst(prefix.count)
                str = str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // 3. Ensure capitalization
        if let first = str.first, first.isLowercase {
            str = first.uppercased() + str.dropFirst()
        }
        
        return str
    }

    /// Cleans verbatim filler words and corrects punctuation from segments without modifying timestamps.
    func cleanVerbatim(segments: inout [TranscriptSegment]) {
        for i in 0..<segments.count {
            var text = TranscriptTextCleaner.clean(segments[i].text)
            
            // Ensure capitalization of the first letter if it's lowercase
            if let first = text.first, first.isLowercase {
                text = first.uppercased() + text.dropFirst()
            }
            
            segments[i].text = text
        }
    }
    
    /// Generates an extractive summary and action items locally without a network call.
    func generateSummary(from segments: [TranscriptSegment]) -> SummaryResult {
        guard !segments.isEmpty else {
            return SummaryResult(executiveSummary: ["No transcript segments available to summarize."], actionItems: [])
        }
        
        let allText = segments.map { $0.text }.joined(separator: " ")
        
        // Primary sentence tokenization via punctuation marks
        var sentences = allText.components(separatedBy: CharacterSet(charactersIn: ".!?\n۔"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 5 }
        
        // Fallback: If punctuation tokenization yielded no sentences or only 1 monolithic text, split by segment texts
        if sentences.count <= 1 {
            sentences = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        
        if sentences.isEmpty {
            return SummaryResult(executiveSummary: ["No summary available."], actionItems: [])
        }
        
        // 1. Exclude conversational fill and closing remarks
        let closingRemarks = ["that's all", "thanks for watching", "see you next time", "bye", "subscribe", "like and subscribe", "anyway"]
        sentences = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return !closingRemarks.contains(where: { lower.contains($0) })
        }
        
        // Compute word frequencies for fallback scoring
        var wordCounts: [String: Int] = [:]
        let words = allText.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 2 }
            
        for word in words {
            wordCounts[word, default: 0] += 1
        }
        
        // Score sentences for fallback
        var sentenceScores: [(index: Int, sentence: String, score: Double)] = []
        for (i, sentence) in sentences.enumerated() {
            let sentenceWords = sentence.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            
            var score = 0.0
            for word in sentenceWords {
                score += Double(wordCounts[word] ?? 0)
            }
            let normalizedScore = sentenceWords.isEmpty ? 0 : score / Double(sentenceWords.count)
            sentenceScores.append((i, sentence, normalizedScore))
        }
        
        // Executive Summary: Synthesize key facts (like numbers, dimensions, models) instead of verbatim extraction
        let specSentences = sentences.filter { sentence in
            // Concrete measurements/version-like identifiers. Do not treat every
            // capitalized sentence opener as a specification.
            let pattern = "\\b[0-9]+(?:\\.[0-9]+)?(?:[a-zA-Z]+|%)\\b|\\b[fF][0-9.]+\\b|\\b[A-Z]{2,}[A-Z0-9-]*\\b"
            return sentence.range(of: pattern, options: .regularExpression) != nil
        }
        
        var execSummary: [String] = []
        if !specSentences.isEmpty {
            execSummary = specSentences.prefix(3).map { sentence in
                let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanBulletPoint(clean)
            }
        } else {
            // Fallback to top scored sentences
            let topCount = min(3, sentenceScores.count)
            execSummary = sentenceScores.sorted { $0.score > $1.score }
                .prefix(topCount)
                .sorted { $0.index < $1.index }
                .map { cleanBulletPoint($0.sentence.hasSuffix(".") || $0.sentence.hasSuffix("۔") ? $0.sentence : $0.sentence + ".") }
        }
            
        // Action Items Extraction (English & Urdu keywords)
        // Strict filtering: Require strong action verbs
        let actionPatterns = [
            #"\b(?:need to|will do|should|must|action item|make sure to|to do|have to|going to|please|assign|follow up)\b"#,
            #"(?:ضروری ہے|کرنا ہے|کریں گے|کرنا ہوگا|تکمیل کریں|فالو اپ)"#
        ]
        var actions: [String] = []
        for sentence in sentences {
            let isAction = actionPatterns.contains { pattern in
                sentence.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            if isAction {
                let formatted = sentence.hasSuffix(".") || sentence.hasSuffix("۔") ? sentence : sentence + "."
                if !actions.contains(formatted) {
                    actions.append(formatted)
                }
            }
        }
        
        let topActions = Array(actions.prefix(3)).map { cleanBulletPoint($0) }
        
        return SummaryResult(
            executiveSummary: execSummary,
            actionItems: topActions
        )
    }
    
    /// Generates an AI summary using on-device FoundationModels if available, otherwise falls back to rule-based.
    func generateSummaryAsync(from segments: [TranscriptSegment]) async -> SummaryResult {
        guard !segments.isEmpty else {
            return SummaryResult(executiveSummary: ["No transcript segments available to summarize."], actionItems: [])
        }
        
        let allText = segments.map { $0.text }.joined(separator: " ")
        let cacheKey = allText.hashValue
        if let cached = await SummaryCache.shared.get(cacheKey) { return cached }
        
        #if canImport(FoundationModels)
        if SystemLanguageModel.default.isAvailable && SystemLanguageModel.default.supportsLocale(Locale.current) {
            let session = LanguageModelSession()
            let boundedTranscript = allText.count > 3_500 ? String(allText.prefix(3_500)) + "..." : allText
            let prompt = """
            Analyze this video transcript and generate two distinct sections:
            
            TRANSCRIPT:
            \(boundedTranscript)
            
            INSTRUCTIONS:
            1. Provide 2-3 concise executive summary bullets highlighting key specifications or main takeaways. Do NOT repeat conversational filler word-for-word.
            2. Extract true action items or actionable tasks, if any exist. Do NOT include closing remarks (e.g. "that's all I'm going to say").
            """
            
            do {
                let response = try await session.respond(to: prompt)
                let result = parseLLMResponse(response.content)
                await SummaryCache.shared.set(cacheKey, result: result)
                return result
            } catch {
                // Fallthrough to rule-based
            }
        }
        #endif
        
        let result = generateSummary(from: segments)
        await SummaryCache.shared.set(cacheKey, result: result)
        return result
    }
    
    private func parseLLMResponse(_ text: String) -> SummaryResult {
        var execSummary: [String] = []
        var actionItems: [String] = []
        
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var isActionItemsSection = false
        
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("action item") || lower.contains("actionable task") || lower.hasPrefix("action:") {
                isActionItemsSection = true
                continue
            }
            if lower.contains("summary") || lower.contains("takeaways") || lower.hasPrefix("executive:") {
                isActionItemsSection = false
                continue
            }
            
            if line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") || line.count > 10 {
                let cleaned = cleanBulletPoint(line)
                if !cleaned.isEmpty {
                    if isActionItemsSection {
                        actionItems.append(cleaned)
                    } else {
                        execSummary.append(cleaned)
                    }
                }
            }
        }
        
        if execSummary.isEmpty {
            execSummary.append("Summary could not be parsed.")
        }
        
        return SummaryResult(executiveSummary: execSummary, actionItems: actionItems)
    }
}
