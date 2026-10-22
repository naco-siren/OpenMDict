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
        saveFoldedKeyIndexes(dictionaries.compactMap(\.reader))
    }

    /// Save the folded-key index of each dictionary that has no saved copy,
    /// one at a time at utility priority (a no-op for the ones that have
    /// one), so that neither a lookup here nor the Action Extension — which
    /// opens its readers anew each time and never writes — has to build it.
    private static func saveFoldedKeyIndexes(_ readers: [MDictReader]) {
        guard !readers.isEmpty else { return }
        Task.detached(priority: .utility) {
            for reader in readers {
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
        guard #available(iOS 17.0, *) else { return }
        Task.detached(priority: .background) {
            guard !NLTagger.availableTagSchemes(for: .word, language: .german).contains(.lemma) else { return }
            _ = try? await NLTagger.requestAssets(for: .german, tagScheme: .lemma)
        }
    }
}
