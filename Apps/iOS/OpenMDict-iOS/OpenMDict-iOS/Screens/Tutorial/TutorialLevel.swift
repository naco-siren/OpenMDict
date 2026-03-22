//
//  TutorialLevel.swift
//  OpenMDict-iOS
//
//  Tutorial level definitions for the New User Guide.
//

import UIKit

/// A tutorial level in the New User Guide.
nonisolated enum TutorialLevel: Int, CaseIterable, Hashable, Sendable {

    // Interactive — operates on a single ArticlePageView
    case bookmarks
    case enhanceDarkMode
    case zoomAndLayout
    case findInPage
    case jumpSearch

    // Guided explanation — describes features with coaching marks
    case searchBasics
    case clipboardLookup
    case dictionaryGroups

    // MARK: - Metadata

    var symbolName: String {
        switch self {
        case .bookmarks:        return "bookmark"
        case .enhanceDarkMode:  return "moon.stars"
        case .zoomAndLayout:    return "textformat.size"
        case .findInPage:       return "doc.text.magnifyingglass"
        case .jumpSearch:       return "text.magnifyingglass"
        case .searchBasics:     return "magnifyingglass"
        case .clipboardLookup:  return "doc.on.clipboard"
        case .dictionaryGroups: return "folder.badge.plus"
        }
    }

    var title: String {
        switch self {
        case .bookmarks:        return L10n.Tutorial.bookmarksTitle
        case .enhanceDarkMode:  return L10n.Tutorial.enhanceDarkModeTitle
        case .zoomAndLayout:    return L10n.Tutorial.zoomAndLayoutTitle
        case .findInPage:       return L10n.Tutorial.findInPageTitle
        case .jumpSearch:       return L10n.Tutorial.jumpSearchTitle
        case .searchBasics:     return L10n.Tutorial.searchBasicsTitle
        case .clipboardLookup:  return L10n.Tutorial.clipboardLookupTitle
        case .dictionaryGroups: return L10n.Tutorial.dictionaryGroupsTitle
        }
    }

    var description: String {
        switch self {
        case .bookmarks:        return L10n.Tutorial.bookmarksDesc
        case .enhanceDarkMode:  return L10n.Tutorial.enhanceDarkModeDesc
        case .zoomAndLayout:    return L10n.Tutorial.zoomAndLayoutDesc
        case .findInPage:       return L10n.Tutorial.findInPageDesc
        case .jumpSearch:       return L10n.Tutorial.jumpSearchDesc
        case .searchBasics:     return L10n.Tutorial.searchBasicsDesc
        case .clipboardLookup:  return L10n.Tutorial.clipboardLookupDesc
        case .dictionaryGroups: return L10n.Tutorial.dictionaryGroupsDesc
        }
    }

    /// Whether this level is interactive (uses real ArticlePageView).
    var isInteractive: Bool {
        switch self {
        case .bookmarks, .enhanceDarkMode, .zoomAndLayout, .findInPage, .jumpSearch:
            return true
        case .searchBasics, .clipboardLookup, .dictionaryGroups:
            return false
        }
    }

    /// Section for the feature list.
    var section: TutorialSection {
        isInteractive ? .interactive : .guides
    }
}

// MARK: - Sections

nonisolated enum TutorialSection: Int, Hashable, CaseIterable, Sendable {
    case interactive
    case guides

    var title: String {
        switch self {
        case .interactive: return L10n.Tutorial.sectionInteractive
        case .guides:      return L10n.Tutorial.sectionGuides
        }
    }
}
