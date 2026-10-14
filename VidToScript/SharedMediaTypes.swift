//
//  SharedMediaTypes.swift
//  VidToScript
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct SupportedLanguage: Identifiable, Hashable {
    let id: String
    let name: String
    let code: String
    let icon: String

    static let all: [SupportedLanguage] = [
        SupportedLanguage(id: "auto", name: "Auto Detect", code: "AUTO", icon: "globe"),
        SupportedLanguage(id: "ar", name: "Arabic (العربية)", code: "AR", icon: "character.book.closed.fill"),
        SupportedLanguage(id: "en", name: "English", code: "EN", icon: "textformat"),
        SupportedLanguage(id: "fr", name: "French", code: "FR", icon: "text.bubble"),
        SupportedLanguage(id: "de", name: "German", code: "DE", icon: "text.quote"),
        SupportedLanguage(id: "ja", name: "Japanese", code: "JA", icon: "character.book.closed"),
        SupportedLanguage(id: "zh", name: "Mandarin", code: "ZH", icon: "bubble.left.and.bubble.right.fill"),
        SupportedLanguage(id: "es", name: "Spanish", code: "ES", icon: "text.alignleft"),
        SupportedLanguage(id: "ur", name: "Urdu (اردو)", code: "UR", icon: "character.book.closed.fill")
    ].sorted {
        if $0.id == "auto" { return true }
        if $1.id == "auto" { return false }
        return $0.name < $1.name
    }
}

/// Single movie representation used by the Photos picker. Imported provider
/// files are moved when already inside the app sandbox and copied otherwise.
struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fileManager = FileManager.default
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = fileManager.temporaryDirectory
                .appendingPathComponent("imported_\(UUID().uuidString).\(ext)")
            if received.file.standardizedFileURL.path.hasPrefix(NSHomeDirectory()) {
                try fileManager.moveItem(at: received.file, to: destination)
            } else {
                try fileManager.copyItem(at: received.file, to: destination)
            }
            return Self(url: destination)
        }
    }
}
