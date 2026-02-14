//
//  SpotlightIndexingService.swift
//  OpenMDict-iOS
//
//  Indexes dictionary names into CoreSpotlight for system-wide search.
//  Users can find their dictionaries from Spotlight and jump into the app.
//

import CoreSpotlight
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
        attrs.contentDescription = dict.originalFileName
        attrs.keywords = [dict.preferredTitle, dict.originalFileName]

        return CSSearchableItem(
            uniqueIdentifier: "dict:\(dict.id)",
            domainIdentifier: domainId,
            attributeSet: attrs
        )
    }
}
