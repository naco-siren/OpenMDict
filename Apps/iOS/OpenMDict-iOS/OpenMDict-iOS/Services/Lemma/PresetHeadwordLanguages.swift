//
//  PresetHeadwordLanguages.swift
//  OpenMDict-iOS
//
//  The headword language of each preset dictionary, read from the bundled
//  catalog. Compiled into both the main app and the Action Extension (which
//  bundles `preset-dictionaries.json` too), so that both pass the same
//  language to the reader's lookup fallbacks — it decides which
//  inflections are undone — without a schema or manifest change.
//

import Foundation

nonisolated enum PresetHeadwordLanguages {

    /// The headword language (`direction.src`, e.g. "EN") of each preset,
    /// by MDX filename — how an installed copy is matched to its preset
    /// (`DictionaryMetadataRecord.originalFileName`). Read from the bundled
    /// catalog on first use; empty if it cannot be read.
    static let byFilename: [String: String] = {
        guard let url = Bundle.main.url(forResource: "preset-dictionaries", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return [:]
        }
        return Dictionary(decoded.dictionaries.map { ($0.filename, $0.direction.src) },
                          uniquingKeysWith: { first, _ in first })
    }()

    /// The fields of `preset-dictionaries.json` needed here.
    private struct Catalog: Decodable {
        let dictionaries: [Entry]

        struct Entry: Decodable {
            let filename: String
            let direction: Direction

            struct Direction: Decodable {
                let src: String
            }
        }
    }
}
