//
//  ShareViewController.swift
//  VidToScriptShare
//
//  Created by abbas on 24/07/2026.
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers
import MobileCoreServices

class ShareViewController: UIViewController {

    /// Must match the App Group entitlement in both the app and share target.
    /// The extension intentionally writes only its hand-off key into this
    /// shared defaults domain.
    private enum SharedDefaults {
        static let appGroupIdentifier = "group.cognetex.VidToScript"
        static let pendingSharedVideoURL = "pendingSharedVideoURL"
        static let pendingSharedVideoPaths = "pendingSharedVideoPaths"
    }

    let appGroupIdentifier = SharedDefaults.appGroupIdentifier
    let sharedContainerDirectoryName = "SharedVideos"

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Host the SwiftUI View
        let hostingController = UIHostingController(rootView: ShareExtensionView())
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hostingController)
        view.addSubview(hostingController.view)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        hostingController.didMove(toParent: self)
        
        handleSharedFile()
    }
    
    private func handleSharedFile() {
        guard let extensionContext = self.extensionContext else {
            self.completeRequest()
            return
        }
        
        let attachments = extensionContext.inputItems.compactMap { ($0 as? NSExtensionItem)?.attachments }.flatMap { $0 }
        
        let videoTypeIdentifiers = [UTType.movie.identifier, UTType.video.identifier, UTType.fileURL.identifier]
        
        for attachment in attachments {
            for typeIdentifier in videoTypeIdentifiers {
                if attachment.hasItemConformingToTypeIdentifier(typeIdentifier) {
                    attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] (item, error) in
                        if let url = item as? URL {
                            self?.copyVideoToAppGroup(url: url)
                        } else {
                            self?.completeRequest()
                        }
                    }
                    return
                }
            }
        }
        
        self.completeRequest()
    }
    
    private func copyVideoToAppGroup(url: URL) {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            completeRequest()
            return
        }
        
        let sharedDir = groupURL.appendingPathComponent(sharedContainerDirectoryName)
        
        do {
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            let destURL = sharedDir.appendingPathComponent(url.lastPathComponent)
            
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            
            try FileManager.default.copyItem(at: url, to: destURL)
            
            if let defaults = UserDefaults(suiteName: appGroupIdentifier) {
                var paths = defaults.stringArray(forKey: SharedDefaults.pendingSharedVideoPaths) ?? []
                paths.append(destURL.path)
                defaults.set(paths, forKey: SharedDefaults.pendingSharedVideoPaths)
                defaults.synchronize()
            }
            
        } catch {
            print("Failed to copy shared video: \(error)")
        }
        
        // Let the user see the progress for a moment before dismissing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.completeRequest()
        }
    }
    
    private func completeRequest() {
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}

struct ShareExtensionView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            
            Text("Importing Video into VidToScript...")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
