//
// Constants.swift
// OpenMDict-iOS
//

import UniformTypeIdentifiers

nonisolated enum AppIdentifiers {
    /// App Group identifier shared between main app and extensions.
    static let appGroupIdentifier = "group.io.github.naco-siren.openmdict"

    /// CloudKit container identifier for iCloud sync.
    static let cloudKitContainerID = "iCloud.io.github.naco-siren.OpenMDict-iOS"

    /// BGTaskScheduler identifier for background article-embedding
    /// indexing (M15). MUST match the Info.plist
    /// `BGTaskSchedulerPermittedIdentifiers` entry exactly, or the system
    /// rejects task registration / submission at runtime.
    static let articleIndexBGTaskID = "io.github.naco-siren.openmdict.articleindex"

    enum UTTypeValue {
        /// ⚠️ Must match Info.plist UTImportedTypeDeclarations
        static let mdx = "io.github.naco-siren.openmdict.mdx"
        static let mdd = "io.github.naco-siren.openmdict.mdd"
    }

    enum URLScheme {
        /// Deep-link scheme for inter-process navigation (Action Extension →
        /// main app, Shortcuts, etc.): `openmdict://lookup?word=…`.
        static let scheme = "openmdict"
    }

    /// Custom WKWebView URL scheme for serving in-dictionary resources
    /// (CSS/JS/images/audio/fonts) through the MDict scheme handlers:
    /// `mdict://<dictId>/<path>`.
    enum ResourceScheme {
        static let scheme = "mdict"
    }

    /// Subdirectory names under each dictionary's storage folder
    /// (`AppGroup/Library/Dictionaries/<dictId>/<subdir>/`).
    enum ResourceDirectory {
        static let mdd = "mdd"
        static let css = "css"
        static let js = "js"
        static let fonts = "fonts"
        /// All resource subdirs, created at import / CloudKit download.
        static let all = [mdd, css, js, fonts]
    }

    /// Resource file extensions (lowercased, no leading dot).
    enum ResourceExtension {
        static let css = "css"
        static let js = "js"
        /// Font formats WebKit can render.
        static let fonts: Set<String> = ["ttf", "otf", "woff", "woff2"]
        /// Extensions whose loose storage-dir copy OVERRIDES the MDD-embedded
        /// one (GoldenDict/Eudic patch-package convention). Images/audio stay
        /// MDD-first, so they're intentionally excluded.
        static let looseOverridable: Set<String> = fonts.union([css, js])
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
        static let css = UTType(filenameExtension: ResourceExtension.css) ?? .plainText
        static let js = UTType.javaScript
        /// UTTypes for the font document picker — derived strictly from
        /// `ResourceExtension.fonts` so ONLY .ttf/.otf/.woff/.woff2 are
        /// selectable. (The broad `.font` umbrella is intentionally NOT used:
        /// it also matches .ttc/.dfont, which the scheme handler doesn't serve.)
        static let fonts: [UTType] = ResourceExtension.fonts.compactMap { UTType(filenameExtension: $0) }
    }
}
