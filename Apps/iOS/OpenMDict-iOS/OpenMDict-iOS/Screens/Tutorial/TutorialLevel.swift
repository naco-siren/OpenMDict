//
//  TutorialLevel.swift
//  OpenMDict-iOS
//
//  Tutorial level definitions for the New User Guide.
//

import UIKit
import GameController

/// A tutorial level in the New User Guide.
///
/// Enum order defines display order within each section.
nonisolated enum TutorialLevel: Int, CaseIterable, Hashable, Sendable {

    // ── Introductory: core features every new user needs ──
    case lookupBasics        // Search + clipboard + related forms + suggestions
    case bookmarks           // Standard feature
    case zoomAndLayout       // Most universally useful hands-on
    case findInPage          // In-article text search

    // ── Intermediate: dictionary & organisation customisation ──
    case importAndResources  // MDX import & resource management
    case enhanceDarkMode     // Unique feature, mainly for third-party dict styles
    case dictionaryGroups    // Group management

    // ── Advanced: power-user productivity ──
    case jumpSearch          // Cross-dict jump from article text
    case popupLookup         // Action Extension upsell ("弹窗快查")
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

    /// Whether this level uses ArticlePageView (interactive + some guides).
    var usesArticlePageView: Bool {
        switch self {
        case .zoomAndLayout, .enhanceDarkMode, .bookmarks, .jumpSearch, .findInPage:
            return true
        case .iPadProductivity:
            return true  // Shows "Open in New Window" button in header
        case .lookupBasics, .popupLookup, .dictionaryGroups, .importAndResources:
            return false
        }
    }

    /// Section for the feature list.
    var section: TutorialSection {
        switch self {
        case .lookupBasics, .bookmarks, .zoomAndLayout, .findInPage:
            return .introductory
        case .importAndResources, .enhanceDarkMode, .dictionaryGroups:
            return .intermediate
        case .jumpSearch, .popupLookup, .iPadProductivity:
            return .advanced
        }
    }

    /// Whether a hardware keyboard is connected (checked at step generation time).
    static var hasHardwareKeyboard: Bool {
        GCKeyboard.coalesced != nil
    }
}

// MARK: - Sections

nonisolated enum TutorialSection: Int, Hashable, CaseIterable, Sendable {
    case introductory
    case intermediate
    case advanced

    var title: String {
        switch self {
        case .introductory: return L10n.Tutorial.sectionIntroductory
        case .intermediate: return L10n.Tutorial.sectionIntermediate
        case .advanced:     return L10n.Tutorial.sectionAdvanced
        }
    }
}
