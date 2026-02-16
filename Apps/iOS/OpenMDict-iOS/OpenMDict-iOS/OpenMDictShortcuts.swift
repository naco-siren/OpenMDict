//
//  OpenMDictShortcuts.swift
//  OpenMDict-iOS
//
//  Registers App Shortcuts for Siri phrase suggestions.
//  Users can say "Look up a word in OpenMDict" to trigger a lookup.
//  Siri will then ask for the word parameter interactively.
//

import AppIntents

@available(iOS 16, *)
struct OpenMDictShortcuts: AppShortcutsProvider {
    nonisolated static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LookupWordIntent(),
            phrases: [
                "Look up a word in \(.applicationName)",
                "Search \(.applicationName)",
            ],
            shortTitle: "Look Up Word",
            systemImageName: "character.book.closed"
        )
    }
}
