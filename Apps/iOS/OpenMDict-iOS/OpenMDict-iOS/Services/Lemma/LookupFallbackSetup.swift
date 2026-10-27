//
//  LookupFallbackSetup.swift
//  OpenMDict-iOS
//
//  One-time background work for the lookup fallbacks
//  (`MDictReader.lookupAll`): saving each dictionary's folded-key index, and
//  asking the system for NLTagger's German lemma model. Runs after
//  dictionaries load, never on the launch path. App target only — the
//  Action Extension only reads what this leaves behind.
//

import Foundation
import NaturalLanguage
import OpenMDictKit

enum LookupFallbackSetup {

    /// Run after `dictionaries` have loaded.
    static func dictionariesDidLoad(_ dictionaries: [MDict]) {
        requestGermanLemmaModelIfNeeded(for: dictionaries)
        saveFoldedKeyIndexes(of: dictionaries)
    }

    /// Save the folded-key index of each dictionary that has no saved copy,
    /// one at a time at utility priority (a no-op for the ones that have
    /// one), so that neither a lookup here nor the Action Extension — which
    /// opens its readers anew each time and never writes — has to build it.
    ///
    /// The readers are captured now; each one is saved only if, when its
    /// turn comes, it is still the reader of a dictionary the service still
    /// has. A reader replaced by `MDict.reloadFromDisk()` (a preset update)
    /// or left behind by a deleted dictionary is skipped: the new reader's
    /// own pass saves the index for the new file, and a deleted
    /// dictionary's cache has just been removed.
    private static func saveFoldedKeyIndexes(of dictionaries: [MDict]) {
        let pairs: [(dict: MDict, reader: MDictReader)] = dictionaries.compactMap { dict in
            dict.reader.map { (dict: dict, reader: $0) }
        }
        guard !pairs.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (dict, reader) in pairs {
                let isCurrent = await MainActor.run {
                    dict.reader === reader && DictionaryService.shared.dict(id: dict.id) === dict
                }
                guard isCurrent else { continue }
                reader.saveFoldedKeyIndexIfNeeded()
            }
        }
    }

    private static var requestedGermanLemmaModel = false

    /// iOS may not have NLTagger's German lemma model until something asks
    /// for it; without it, German inflections are undone by rule alone. Ask
    /// once per launch, in the background, when a dictionary has German
    /// headwords. Errors are ignored: the rules stay in use.
    private static func requestGermanLemmaModelIfNeeded(for dictionaries: [MDict]) {
        guard !requestedGermanLemmaModel,
              dictionaries.contains(where: { $0.headwordLanguage?.uppercased() == "DE" }) else { return }
        requestedGermanLemmaModel = true
        Task.detached(priority: .background) {
            guard !NLTagger.availableTagSchemes(for: .word, language: .german).contains(.lemma) else { return }
            // The completion-handler form exists since iOS 13, so every
            // supported iOS asks; the async refinement would be no newer,
            // but this keeps the deploy target's availability explicit.
            NLTagger.requestAssets(for: .german, tagScheme: .lemma) { _, _ in }
        }
    }
}
