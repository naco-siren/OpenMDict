//
//  TutorialLevel.swift
//  OpenMDict-iOS
//
//  Tutorial level definitions for the New User Guide.
//

import UIKit

/// A tutorial level in the New User Guide.
///
/// Enum order defines display order within each section.
nonisolated enum TutorialLevel: Int, CaseIterable, Hashable, Sendable {

    // ── Hands-on Tutorials (interactive, ArticlePageView) ──
    case zoomAndLayout       // 1st: most universally useful
    case enhanceDarkMode     // 2nd: unique feature
    case bookmarks           // 3rd: standard feature
    case jumpSearch          // 4th: advanced but important
    case findInPage          // 5th: niche

    // ── Feature Guides (explanation with screenshots) ──
    case lookupBasics        // Search + clipboard + related forms + suggestions
    case popupLookup         // Action Extension upsell ("弹窗快查")
    case dictionaryGroups    // Group management
    case importAndResources  // MDX import & resource management
    case iPadProductivity    // iPad multitasking + keyboard shortcuts

    // MARK: - Metadata

    /// SF Symbol name. For `.popupLookup`, pass a trait collection to get
    /// the size-class-aware icon; the parameterless overload returns the iOS 15 fallback.
    func symbolName(traitCollection: UITraitCollection? = nil) -> String {
        switch self {
        case .zoomAndLayout:      return "textformat.size"
        case .enhanceDarkMode:    return "moon.stars"
        case .bookmarks:          return "bookmark"
        case .jumpSearch:         return "sparkle.magnifyingglass"
        case .findInPage:         return "doc.text.magnifyingglass"
        case .lookupBasics:       return "character.book.closed"
        case .popupLookup:
            if #available(iOS 18.0, *) {
                let isCompact = traitCollection?.horizontalSizeClass == .compact
                return isCompact ? "widget.small.badge.plus" : "widget.large.badge.plus"
            }
            return "square.text.square"
        case .dictionaryGroups:   return "folder.badge.person.crop"
        case .importAndResources: return "books.vertical"
        case .iPadProductivity:   return "text.and.command.macwindow"
        }
    }

    var title: String {
        switch self {
        case .zoomAndLayout:      return L10n.Tutorial.zoomAndLayoutTitle
        case .enhanceDarkMode:    return L10n.Tutorial.enhanceDarkModeTitle
        case .bookmarks:          return L10n.Tutorial.bookmarksTitle
        case .jumpSearch:         return L10n.Tutorial.jumpSearchTitle
        case .findInPage:         return L10n.Tutorial.findInPageTitle
        case .lookupBasics:       return L10n.Tutorial.lookupBasicsTitle
        case .popupLookup:        return L10n.Tutorial.popupLookupTitle
        case .dictionaryGroups:   return L10n.Tutorial.dictionaryGroupsTitle
        case .importAndResources: return L10n.Tutorial.importAndResourcesTitle
        case .iPadProductivity:   return L10n.Tutorial.iPadProductivityTitle
        }
    }

    var description: String {
        switch self {
        case .zoomAndLayout:      return L10n.Tutorial.zoomAndLayoutDesc
        case .enhanceDarkMode:    return L10n.Tutorial.enhanceDarkModeDesc
        case .bookmarks:          return L10n.Tutorial.bookmarksDesc
        case .jumpSearch:         return L10n.Tutorial.jumpSearchDesc
        case .findInPage:         return L10n.Tutorial.findInPageDesc
        case .lookupBasics:       return L10n.Tutorial.lookupBasicsDesc
        case .popupLookup:        return L10n.Tutorial.popupLookupDesc
        case .dictionaryGroups:   return L10n.Tutorial.dictionaryGroupsDesc
        case .importAndResources: return L10n.Tutorial.importAndResourcesDesc
        case .iPadProductivity:   return L10n.Tutorial.iPadProductivityDesc
        }
    }

    /// Whether this level is interactive (uses real ArticlePageView).
    var isInteractive: Bool {
        switch self {
        case .zoomAndLayout, .enhanceDarkMode, .bookmarks, .jumpSearch, .findInPage:
            return true
        case .lookupBasics, .popupLookup, .dictionaryGroups, .importAndResources, .iPadProductivity:
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
