//
// Constants.swift
// OpenMDict-iOS
//
// ⚠️ Must match Info.plist UTImportedTypeDeclarations
//

import UniformTypeIdentifiers

nonisolated enum AppIdentifiers {
    enum UTTypeValue {
        static let mdx = "io.github.naco-siren.OpenMDict.mdx"
        static let mdd = "io.github.naco-siren.OpenMDict.mdd"
    }
    
    enum Activity {
        /// Activity type for full scene state restoration
        static let sceneState = "io.github.naco-siren.OpenMDict.sceneState"
        
        /// Activity type for single article (drag & drop, handoff)
        static let viewArticle = "io.github.naco-siren.OpenMDict.viewArticle"
    }
    
    enum ResourceType {
        static let mdx = UTType(UTTypeValue.mdx) ?? .data
        static let mdd = UTType(UTTypeValue.mdd) ?? .data
        static let css = UTType(filenameExtension: "css") ?? .plainText
        static let js = UTType.javaScript
    }
}
