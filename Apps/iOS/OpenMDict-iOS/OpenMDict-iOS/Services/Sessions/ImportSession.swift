//
//  ImportSession.swift
//  OpenMDict-iOS
//
//  Shared state for dictionary import workflow.
//  Manages MDX metadata and pending resource files (MDD/CSS/JS) that will be
//  imported together as a single transaction.
//
//  Usage:
//  - MainSplitVC creates and holds the ImportSession
//  - DictInfoVC and DictResourceEditorVC share the same instance
//  - When user selects MDX, DictInfoVC calls setMDX()
//  - DictResourceEditorVC subscribes to pending files and displays them
//  - When user adds MDD/CSS/JS, DictResourceEditorVC calls add*() methods
//  - When user taps Done, DictInfoVC reads all pending files and imports
//

import Foundation
import Combine
import OpenMDictKit

/// Represents a file pending import (not yet copied to storage)
/// Stores bookmark data to allow access after the initial security scope closes
nonisolated struct PendingFile: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let fileName: String
    let fileSize: Int64
    let bookmarkData: Data?
    
    /// Create from URL with security-scoped access
    /// Call this while the URL's security scope is active to capture bookmark
    init(url: URL, fileSize: Int64? = nil) {
        self.id = UUID()
        self.url = url
        self.fileName = url.lastPathComponent
        
        if let size = fileSize {
            self.fileSize = size
        } else {
            // Try to get file size - may fail for security-scoped URLs if not accessed
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                self.fileSize = size
            } else {
                self.fileSize = 0
            }
        }
        
        // Create bookmark for later access (after security scope closes)
        self.bookmarkData = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
    
    // Hashable: use URL for identity (not UUID) to avoid snapshot churn
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
    
    static func == (lhs: PendingFile, rhs: PendingFile) -> Bool {
        lhs.url == rhs.url
    }
}

/// Shared state for the import workflow
@MainActor
final class ImportSession: ObservableObject {
    
    // MARK: - MDX Source
    
    /// The selected MDX file (stored as PendingFile to preserve file size)
    @Published private(set) var mdxPendingFile: PendingFile?
    
    /// Metadata loaded from the MDX file
    @Published private(set) var mdxMetadata: MDictMetadata?
    
    // MARK: - Pending Resources
    
    /// MDD files to import (URLs, not yet copied)
    @Published private(set) var pendingMDDFiles: [PendingFile] = []
    
    /// CSS files to import
    @Published private(set) var pendingCSSFiles: [PendingFile] = []
    
    /// JS files to import
    @Published private(set) var pendingJSFiles: [PendingFile] = []

    /// Font files to import
    @Published private(set) var pendingFontFiles: [PendingFile] = []

    // MARK: - Computed Properties
    
    /// Dictionary ID = MDX header SHA256 (available before import)
    var dictId: String? {
        mdxMetadata?.headerSHA256
    }
    
    /// Whether an MDX has been selected
    var hasMDX: Bool {
        mdxPendingFile != nil && mdxMetadata != nil
    }
    
    /// MDX URL for import
    var mdxURL: URL? {
        mdxPendingFile?.url
    }
    
    // MARK: - MDX Operations
    
    /// Set the MDX file and its metadata
    /// Call this while the URL's security scope is active
    func setMDX(url: URL, metadata: MDictMetadata, fileSize: Int64) {
        self.mdxPendingFile = PendingFile(url: url, fileSize: fileSize)
        self.mdxMetadata = metadata
        let hasBookmark = mdxPendingFile?.bookmarkData != nil
        print("📦 ImportSession: MDX set - \(url.lastPathComponent), size=\(fileSize), bookmark=\(hasBookmark), dictId=\(metadata.headerSHA256?.prefix(8) ?? "nil")...")
    }
    
    // MARK: - MDD Operations
    
    /// Add MDD file with its size (call while security scope is active)
    func addMDD(_ url: URL, fileSize: Int64) {
        let file = PendingFile(url: url, fileSize: fileSize)
        // Check for duplicate by fileName
        guard !pendingMDDFiles.contains(where: { $0.fileName == file.fileName }) else {
            print("⚠️ ImportSession: MDD already added - \(file.fileName)")
            return
        }
        pendingMDDFiles.append(file)
        let hasBookmark = file.bookmarkData != nil
        print("📦 ImportSession: MDD added - \(file.fileName), size=\(fileSize), bookmark=\(hasBookmark)")
    }
    
    func removeMDD(at index: Int) {
        guard index >= 0 && index < pendingMDDFiles.count else { return }
        let removed = pendingMDDFiles.remove(at: index)
        print("📦 ImportSession: MDD removed - \(removed.fileName)")
    }
    
    func removeMDD(id: UUID) {
        if let index = pendingMDDFiles.firstIndex(where: { $0.id == id }) {
            removeMDD(at: index)
        }
    }
    
    // MARK: - CSS Operations
    
    /// Add CSS file with its size (call while security scope is active)
    func addCSS(_ url: URL, fileSize: Int64) {
        let file = PendingFile(url: url, fileSize: fileSize)
        guard !pendingCSSFiles.contains(where: { $0.fileName == file.fileName }) else {
            print("⚠️ ImportSession: CSS already added - \(file.fileName)")
            return
        }
        pendingCSSFiles.append(file)
        let hasBookmark = file.bookmarkData != nil
        print("📦 ImportSession: CSS added - \(file.fileName), size=\(fileSize), bookmark=\(hasBookmark)")
    }
    
    func removeCSS(at index: Int) {
        guard index >= 0 && index < pendingCSSFiles.count else { return }
        let removed = pendingCSSFiles.remove(at: index)
        print("📦 ImportSession: CSS removed - \(removed.fileName)")
    }
    
    func removeCSS(id: UUID) {
        if let index = pendingCSSFiles.firstIndex(where: { $0.id == id }) {
            removeCSS(at: index)
        }
    }
    
    // MARK: - JS Operations
    
    /// Add JS file with its size (call while security scope is active)
    func addJS(_ url: URL, fileSize: Int64) {
        let file = PendingFile(url: url, fileSize: fileSize)
        guard !pendingJSFiles.contains(where: { $0.fileName == file.fileName }) else {
            print("⚠️ ImportSession: JS already added - \(file.fileName)")
            return
        }
        pendingJSFiles.append(file)
        let hasBookmark = file.bookmarkData != nil
        print("📦 ImportSession: JS added - \(file.fileName), size=\(fileSize), bookmark=\(hasBookmark)")
    }
    
    func removeJS(at index: Int) {
        guard index >= 0 && index < pendingJSFiles.count else { return }
        let removed = pendingJSFiles.remove(at: index)
        print("📦 ImportSession: JS removed - \(removed.fileName)")
    }
    
    func removeJS(id: UUID) {
        if let index = pendingJSFiles.firstIndex(where: { $0.id == id }) {
            removeJS(at: index)
        }
    }

    // MARK: - Font Operations

    /// Add font file with its size (call while security scope is active)
    func addFont(_ url: URL, fileSize: Int64) {
        let file = PendingFile(url: url, fileSize: fileSize)
        guard !pendingFontFiles.contains(where: { $0.fileName == file.fileName }) else {
            print("⚠️ ImportSession: font already added - \(file.fileName)")
            return
        }
        pendingFontFiles.append(file)
        let hasBookmark = file.bookmarkData != nil
        print("📦 ImportSession: font added - \(file.fileName), size=\(fileSize), bookmark=\(hasBookmark)")
    }

    func removeFont(at index: Int) {
        guard index >= 0 && index < pendingFontFiles.count else { return }
        let removed = pendingFontFiles.remove(at: index)
        print("📦 ImportSession: font removed - \(removed.fileName)")
    }

    func removeFont(id: UUID) {
        if let index = pendingFontFiles.firstIndex(where: { $0.id == id }) {
            removeFont(at: index)
        }
    }

    // MARK: - Reset

    /// Clear all state (call after import completes or is cancelled)
    func reset() {
        mdxPendingFile = nil
        mdxMetadata = nil
        pendingMDDFiles = []
        pendingCSSFiles = []
        pendingJSFiles = []
        pendingFontFiles = []
        print("📦 ImportSession: reset")
    }
}
