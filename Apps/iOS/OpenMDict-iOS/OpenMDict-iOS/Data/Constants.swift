//
// Constants.swift
// OpenMDict-iOS
//

import UniformTypeIdentifiers

nonisolated enum AppIdentifiers {
    /// App Group identifier shared between main app and extensions.
    static let appGroupIdentifier = "group.io.github.naco-siren.openmdict"

    enum UTTypeValue {
        /// ⚠️ Must match Info.plist UTImportedTypeDeclarations
        static let mdx = "io.github.naco-siren.openmdict.mdx"
        static let mdd = "io.github.naco-siren.openmdict.mdd"
    }

    enum URLScheme {
        static let scheme = "openmdict"
    }
    
    enum Activity {
        /// Activity type for full scene state restoration
        static let sceneState = "io.github.naco-siren.OpenMDict.sceneState"

        /// Activity type for single article (drag & drop, handoff)
        static let viewArticle = "io.github.naco-siren.OpenMDict.viewArticle"

        /// Activity type for word lookup (Siri suggestions, Shortcuts)
        static let lookupWord = "io.github.naco-siren.OpenMDict.lookupWord"
    }
    
    enum ResourceType {
        static let mdx = UTType(UTTypeValue.mdx) ?? .data
        static let mdd = UTType(UTTypeValue.mdd) ?? .data
        static let css = UTType(filenameExtension: "css") ?? .plainText
        static let js = UTType.javaScript
    }
}
