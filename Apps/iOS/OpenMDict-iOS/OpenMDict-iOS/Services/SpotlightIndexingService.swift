//
//  SpotlightIndexingService.swift
//  OpenMDict-iOS
//
//  Indexes dictionary names into CoreSpotlight for system-wide search.
//  Users can find their dictionaries from Spotlight and jump into the app.
//

@preconcurrency import CoreSpotlight
import Foundation
import OpenMDictKit

final class SpotlightIndexingService {
    static let shared = SpotlightIndexingService()

    private let index = CSSearchableIndex.default()
    private let domainId = "com.openmdict.dictionaries"

    private init() {}

    // MARK: - Index All

    /// Index all currently loaded dictionaries. Safe to call repeatedly (idempotent via uniqueIdentifier).
    func indexAllDictionaries() {
        let dictionaries = DictionaryService.shared.allDictionaries
        guard !dictionaries.isEmpty else { return }

        let items = dictionaries.map { searchableItem(for: $0) }

        index.indexSearchableItems(items) { error in
            if let error {
                print("⚠️ Spotlight: failed to index all dictionaries: \(error)")
            } else {
                print("🔦 Spotlight: indexed \(items.count) dictionaries")
            }
        }
    }

    // MARK: - Index / Deindex Single

    /// Index a single dictionary (call after import completes and metadata is loaded).
    func indexDictionary(_ dict: MDict) {
        let item = searchableItem(for: dict)

        index.indexSearchableItems([item]) { error in
            if let error {
                print("⚠️ Spotlight: failed to index \(dict.id.prefix(8)): \(error)")
            }
        }
    }

    /// Remove a dictionary from the index (call before or after delete).
    func deindexDictionary(id: String) {
        let identifier = "dict:\(id)"
        index.deleteSearchableItems(withIdentifiers: [identifier]) { error in
            if let error {
                print("⚠️ Spotlight: failed to deindex \(id.prefix(8)): \(error)")
            }
        }
    }

    // MARK: - Parse Continuation

    /// Parse a dictionary ID from a Spotlight continuation NSUserActivity.
    /// Returns nil if the activity is not a Spotlight action or not a dict item.
    static func parseDictionaryId(from activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType,
              let uniqueId = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              uniqueId.hasPrefix("dict:") else {
            return nil
        }
        return String(uniqueId.dropFirst(5))
    }

    // MARK: - Helpers

    private func searchableItem(for dict: MDict) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .content)
        attrs.title = dict.preferredTitle

        // Build a rich content description from available metadata
        var descParts: [String] = []
        if let count = dict.metadata?.entryCount, count > 0 {
            descParts.append(Self.formatEntryCount(count))
        }
        if let author = dict.extractedAuthor, !author.isEmpty {
            descParts.append(author)
        }
        if let importDate = DictionaryService.shared.importedDate(dict.id) {
            descParts.append(Self.formatImportDate(importDate))
        }
        if descParts.isEmpty {
            descParts.append(dict.originalFileName)
        }
        attrs.contentDescription = descParts.joined(separator: " · ")

        // Keywords: title variants + filename + cleaned description excerpt
        var keywords = [dict.preferredTitle, dict.originalFileName]
        if let metaTitle = dict.metadata?.title, metaTitle != dict.preferredTitle {
            keywords.append(metaTitle)
        }
        if let displayName = dict.userDisplayName, !displayName.isEmpty, displayName != dict.preferredTitle {
            keywords.append(displayName)
        }
        attrs.keywords = keywords

        // Ranking hint: dictionaries with more lookups rank higher (0.0–1.0 scale)
        let lookups = LookupCountService.shared.lookupCount(contextDictId: dict.id, contextGroupId: nil)
        // Sigmoid-like curve: 50 lookups → ~0.5, 200 lookups → ~0.9
        attrs.rankingHint = NSNumber(value: Double(lookups) / (Double(lookups) + 50.0))

        return CSSearchableItem(
            uniqueIdentifier: "dict:\(dict.id)",
            domainIdentifier: domainId,
            attributeSet: attrs
        )
    }

    // MARK: - Formatting

    private static func formatEntryCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM entries", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK entries", Double(count) / 1_000.0)
        }
        return "\(count) entries"
    }

    /// Format import date: "Imported on Feb 15" (same year) or "Imported on Feb 15, 2024" (different year).
    private static func formatImportDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let isSameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        formatter.dateFormat = isSameYear ? "MMM d" : "MMM d, yyyy"
        return "Imported on \(formatter.string(from: date))"
    }
}
