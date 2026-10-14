//  TranscriptExporterService.swift
//  VidToScript
//
//  Created by AI Assistant
//  Copyright © 2026 VidToScript. All rights reserved.
//

import Foundation
import UIKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import NaturalLanguage

/// Formats available for export.
enum ExportFormat: String, CaseIterable, Identifiable {
    case srt = "SubRip (.srt)"
    case vtt = "WebVTT (.vtt)"
    case txt = "Plain Text (.txt)"
    case md = "Markdown (.md)"
    case pdf = "PDF Document (.pdf)"
    
    var id: String { rawValue }
    
    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .txt: return "txt"
        case .md: return "md"
        case .pdf: return "pdf"
        }
    }
    
    var mimeType: String {
        switch self {
        case .srt: return "application/x-subrip"
        case .vtt: return "text/vtt"
        case .txt: return "text/plain"
        case .md: return "text/markdown"
        case .pdf: return "application/pdf"
        }
    }
}

/// A wrapper for exported file URLs that conforms to Transferable for SwiftUI's share sheet.
struct ExportedFile: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { exportedFile in
            SentTransferredFile(exportedFile.url)
        }
    }
}

@Observable
final class TranscriptExporterService {
    
    /// Exports the project to the specified format and returns the URL to the temporary file.
    func export(project: VideoProject, to format: ExportFormat, isVerbatim: Bool = true) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let safeTitle = project.title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let fileName = "\(safeTitle)_Transcript.\(format.fileExtension)"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        switch format {
        case .srt:
            let content = generateSRT(from: project.segments, isVerbatim: isVerbatim)
            try writeUTF8withBOM(content, to: fileURL)
            
        case .vtt:
            let content = generateVTT(from: project.segments, isVerbatim: isVerbatim)
            try writeUTF8withBOM(content, to: fileURL)
            
        case .txt:
            let content = generateTXT(from: project.segments, isVerbatim: isVerbatim)
            try writeUTF8withBOM(content, to: fileURL)
            
        case .md:
            let content = generateMD(from: project.segments, isVerbatim: isVerbatim)
            try writeUTF8withBOM(content, to: fileURL)
            
        case .pdf:
            try generatePDF(from: project, to: fileURL, isVerbatim: isVerbatim)
        }
        
        return fileURL
    }
    
    // MARK: - File Writing
    
    /// Writes a string to a URL as UTF-8 with a Byte Order Mark (BOM)
    private func writeUTF8withBOM(_ content: String, to url: URL) throws {
        var data = Data()
        // UTF-8 BOM
        data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        if let stringData = content.data(using: .utf8) {
            data.append(stringData)
        }
        try data.write(to: url, options: .atomic)
    }
    
    // MARK: - Generators
    
    private func generateSRT(from segments: [TranscriptSegment], isVerbatim: Bool) -> String {
        var result = ""
        var index = 1
        for segment in subtitleCues(from: segments, isVerbatim: isVerbatim) {
            result += "\(index)\n"
            result += "\(formatTimeSRT(segment.startTime)) --> \(formatTimeSRT(segment.endTime))\n"
            result += "\(segment.text)\n\n"
            index += 1
        }
        return result
    }
    
    private func generateVTT(from segments: [TranscriptSegment], isVerbatim: Bool) -> String {
        var result = "WEBVTT\n\n"
        var index = 1
        for segment in subtitleCues(from: segments, isVerbatim: isVerbatim) {
            result += "\(index)\n"
            result += "\(formatTimeVTT(segment.startTime)) --> \(formatTimeVTT(segment.endTime))\n"
            result += "<v \(escapeVTTVoice(segment.speakerID))>\(segment.text)\n\n"
            index += 1
        }
        return result
    }
    
    private func generateTXT(from segments: [TranscriptSegment], isVerbatim: Bool) -> String {
        var result = ""
        var currentSpeaker = ""
        
        for segment in segments {
            if segment.speakerID != currentSpeaker {
                if !result.isEmpty { result += "\n\n" }
                result += "\(segment.speakerID):\n"
                currentSpeaker = segment.speakerID
            } else {
                result += " "
            }
            let text = isVerbatim ? segment.text : filterFillers(segment.text)
            result += text
        }
        return result
    }
    
    private func generateMD(from segments: [TranscriptSegment], isVerbatim: Bool) -> String {
        var result = "# Transcript\n\n"
        var currentSpeaker = ""
        
        for segment in segments {
            if segment.speakerID != currentSpeaker {
                result += "\n## \(segment.speakerID)\n"
                currentSpeaker = segment.speakerID
            }
            let text = isVerbatim ? segment.text : filterFillers(segment.text)
            result += "**[\(formatTimeShort(segment.startTime))]** \(text)\n\n"
        }
        return result
    }
    
    private func generatePDF(from project: VideoProject, to url: URL, isVerbatim: Bool) throws {
        let pdfMetaData = [
            kCGPDFContextCreator: "VidToScript",
            kCGPDFContextAuthor: "VidToScript User",
            kCGPDFContextTitle: project.title
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]
        
        let pageWidth = 8.5 * 72.0
        let pageHeight = 11 * 72.0
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        
        let data = renderer.pdfData { context in
            context.beginPage()
            
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 24)
            ]
            let speakerAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 14),
                .foregroundColor: UIColor.systemBlue
            ]
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .natural
            paragraphStyle.baseWritingDirection = .natural
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .paragraphStyle: paragraphStyle
            ]
            let timeAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: UIColor.gray
            ]
            
            var cursorY: CGFloat = 40
            let margin: CGFloat = 40
            let contentWidth = pageWidth - (margin * 2)
            
            // Draw Title
            let titleString = NSAttributedString(string: project.title, attributes: titleAttributes)
            let titleHeight = titleString.boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                                       options: .usesLineFragmentOrigin, context: nil).height
            let titleRect = CGRect(x: margin, y: cursorY, width: contentWidth, height: titleHeight)
            titleString.draw(in: titleRect)
            cursorY += titleHeight + 20
            
            for segment in project.segments {
                let text = isVerbatim ? segment.text : filterFillers(segment.text)
                for (chunkIndex, chunk) in pdfChunks(text) .enumerated() {
                    let textStr = NSAttributedString(string: chunk, attributes: textAttributes)
                    let textHeight = textStr.boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                                          options: .usesLineFragmentOrigin, context: nil).height
                    let headerHeight: CGFloat = chunkIndex == 0 ? 20 : 0
                    if cursorY + headerHeight + textHeight + 15 > pageHeight - margin {
                        context.beginPage()
                        cursorY = margin
                    }
                    if chunkIndex == 0 {
                        let timeStr = formatTimeShort(segment.startTime)
                        let headerStr = NSMutableAttributedString(string: "\(segment.speakerID)  ", attributes: speakerAttributes)
                        headerStr.append(NSAttributedString(string: timeStr, attributes: timeAttributes))
                        headerStr.draw(in: CGRect(x: margin, y: cursorY, width: contentWidth, height: headerHeight))
                        cursorY += headerHeight
                    }
                    textStr.draw(in: CGRect(x: margin, y: cursorY, width: contentWidth, height: textHeight))
                    cursorY += textHeight + 15
                }
            }
        }
        
        try data.write(to: url)
    }
    
    // MARK: - Formatting Helpers

    /// Keeps subtitle cues short without rebuilding text from tokens (which
    /// would lose punctuation and alter CJK text).
    private func subtitleCues(from segments: [TranscriptSegment], isVerbatim: Bool) -> [TranscriptSegment] {
        segments.flatMap { (segment: TranscriptSegment) -> [TranscriptSegment] in
            let text = (isVerbatim ? segment.text : filterFillers(segment.text))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.endTime > segment.startTime else { return [] }
            guard segment.duration > 6 else {
                return [TranscriptSegment(startTime: segment.startTime, endTime: segment.endTime,
                                          speakerID: segment.speakerID, text: text, words: segment.words)]
            }
            let cueCount = max(1, Int(ceil(segment.duration / 4)))
            let charactersPerCue = max(1, text.count / cueCount)
            var cues: [TranscriptSegment] = []
            var start = text.startIndex
            var time = segment.startTime
            let timePerCharacter = segment.duration / Double(max(1, text.count))
            for index in 0..<cueCount where start < text.endIndex {
                let isLast = index == cueCount - 1
                var end = text.index(start, offsetBy: charactersPerCue, limitedBy: text.endIndex) ?? text.endIndex
                if !isLast, end < text.endIndex,
                   let boundary = text[start...end].lastIndex(where: { $0.isWhitespace || $0.isPunctuation }) {
                    end = text.index(after: boundary)
                } else if isLast { end = text.endIndex }
                let cueText = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                let endTime = isLast ? segment.endTime : min(segment.endTime, time + Double(cueText.count) * timePerCharacter)
                if !cueText.isEmpty { cues.append(TranscriptSegment(startTime: time, endTime: endTime, speakerID: segment.speakerID, text: cueText, words: [])) }
                start = end
                time = endTime
            }
            return cues
        }
    }

    private func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map(String.init)
    }

    /// Bounds a single draw operation so a very long segment is paginated
    /// instead of being rendered beyond the current PDF page.
    private func pdfChunks(_ text: String, maximumCharacters: Int = 900) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let proposedEnd = text.index(start, offsetBy: maximumCharacters, limitedBy: text.endIndex) ?? text.endIndex
            let end = text[start..<proposedEnd].lastIndex(of: " ").map { text.index(after: $0) } ?? proposedEnd
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    private func escapeVTTVoice(_ name: String) -> String {
        name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    
    private func formatTimeSRT(_ time: TimeInterval) -> String {
        let totalMilliseconds = max(0, Int((time * 1000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
    
    private func formatTimeVTT(_ time: TimeInterval) -> String {
        let totalMilliseconds = max(0, Int((time * 1000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }
    
    private func formatTimeShort(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func filterFillers(_ text: String) -> String {
        TranscriptTextCleaner.clean(text)
    }
}
