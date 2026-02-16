//
//  LookupWordIntent.swift
//  OpenMDict-iOS
//
//  App Intent for Siri and Shortcuts: "Look up <word> in OpenMDict"
//  Opens the main app and triggers a dictionary lookup via URL scheme.
//
//  Requires iOS 16+. On iOS 15.x this type is stripped from the binary.
//

import AppIntents
import UIKit

@available(iOS 16, *)
struct LookupWordIntent: AppIntent {

    nonisolated static let title: LocalizedStringResource = "Look Up Word"
    nonisolated static let description = IntentDescription("Look up a word in OpenMDict")
    nonisolated static let openAppWhenRun: Bool = true

    @Parameter(title: "Word", description: "The word to look up")
    var word: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        if let url = URL(string: "openmdict://lookup?word=\(encoded)") {
            await UIApplication.shared.open(url)
        }
        return .result()
    }
}
