//
//  L10n.swift
//  OpenMDict-iOS
//
//  Centralized localization namespace. All user-facing strings pass through
//  here so they can be translated via Localizable.xcstrings.
//
//  Pattern: NSLocalizedString(key, value: english, comment:)
//  The `value:` parameter ensures English is always the fallback.
//

import Foundation

nonisolated enum L10n {

    // MARK: - Common Buttons & Labels

    static var cancel: String {
        NSLocalizedString("common.cancel", value: "Cancel", comment: "Button: cancel an action")
    }
    static var delete: String {
        NSLocalizedString("common.delete", value: "Delete", comment: "Button: delete something")
    }
    static var ok: String {
        NSLocalizedString("common.ok", value: "OK", comment: "Button: acknowledge")
    }
    static var save: String {
        NSLocalizedString("common.save", value: "Save", comment: "Button: save changes")
    }
    static var discard: String {
        NSLocalizedString("common.discard", value: "Discard", comment: "Button: discard changes")
    }
    static var importAction: String {
        NSLocalizedString("common.import", value: "Import", comment: "Button: import something")
    }
    static var keepEditing: String {
        NSLocalizedString("common.keepEditing", value: "Keep Editing", comment: "Button: continue editing instead of discarding")
    }
    static var error: String {
        NSLocalizedString("common.error", value: "Error", comment: "Alert title for generic errors")
    }
    static var loading: String {
        NSLocalizedString("common.loading", value: "Loading\u{2026}", comment: "Generic loading indicator text")
    }
    static var done: String {
        NSLocalizedString("common.done", value: "Done", comment: "Button: finished")
    }
    static var unknownError: String {
        NSLocalizedString("common.unknownError", value: "Unknown error", comment: "Generic fallback error message")
    }

    // MARK: - Common Alerts

    static var discardChangesTitle: String {
        NSLocalizedString("common.discardChanges.title", value: "Discard Changes?", comment: "Alert title: discard unsaved changes")
    }
    static var discardChangesMessage: String {
        NSLocalizedString("common.discardChanges.message", value: "You have unsaved changes. Are you sure you want to discard them?", comment: "Alert body: discard unsaved changes")
    }

    // MARK: - Welcome Screen

    enum Welcome {
        static var title: String {
            NSLocalizedString("welcome.title", value: "Welcome to OpenMDict", comment: "Welcome screen main title")
        }
        static var getStarted: String {
            NSLocalizedString("welcome.getStarted", value: "Get Started", comment: "Welcome screen CTA button")
        }
        static var footer: String {
            NSLocalizedString("welcome.footer", value: "OpenMDict is an MDict (MDX) format dictionary reader. For richer content, you can import your own .mdx files \u{2014} refer to the thriving MDict ecosystem and its communities for resources and format specifications.", comment: "Welcome screen footer paragraph")
        }

        // Feature cards
        static var layoutsTitle: String {
            NSLocalizedString("welcome.feature.layouts.title", value: "Three Article Layouts on iPadOS", comment: "Feature card title")
        }
        static var layoutsBody: String {
            NSLocalizedString("welcome.feature.layouts.body", value: "View multiple definitions from different dictionaries in Columns, Grid or List, all at once.", comment: "Feature card body")
        }
        static var multiWindowTitle: String {
            NSLocalizedString("welcome.feature.multiWindow.title", value: "Multi-Window on iPadOS", comment: "Feature card title")
        }
        static var multiWindowBody: String {
            NSLocalizedString("welcome.feature.multiWindow.body", value: "Enjoy desktop-class productivity on iPadOS with multi-window and full keyboard support.", comment: "Feature card body")
        }
        static var noLimitsTitle: String {
            NSLocalizedString("welcome.feature.noLimits.title", value: "No Limits, Free Forever", comment: "Feature card title")
        }
        static var noLimitsBody: String {
            NSLocalizedString("welcome.feature.noLimits.body", value: "Import unlimited dictionaries and create unlimited groups, without any subscriptions or paid memberships.", comment: "Feature card body")
        }
        static var presetsTitle: String {
            NSLocalizedString("welcome.feature.presets.title", value: "Preset Dictionaries Included", comment: "Feature card title")
        }
        static var presetsBody: String {
            NSLocalizedString("welcome.feature.presets.body", value: "Pick your starter pack from our curated selection of open-source dictionaries, ready to use with minimum setup.", comment: "Feature card body")
        }
    }

    // MARK: - Preset Dictionary Picker

    enum Picker {
        static var titleFirstInstall: String {
            NSLocalizedString("picker.title.firstInstall", value: "Choose Dictionaries", comment: "Picker title on first install")
        }
        static var titleManagement: String {
            NSLocalizedString("picker.title.management", value: "Add Preset Dictionaries", comment: "Picker title when adding more presets")
        }
        static var subtitleFirstInstall: String {
            NSLocalizedString("picker.subtitle.firstInstall", value: "Select dictionaries to install. You can change this later.", comment: "Picker subtitle on first install")
        }
        static var subtitleManagement: String {
            NSLocalizedString("picker.subtitle.management", value: "Select dictionaries to add to your library.", comment: "Picker subtitle when adding more presets")
        }
        static var selectAll: String {
            NSLocalizedString("picker.selectAll", value: "Select All", comment: "Button to select all dictionaries")
        }
        static var deselectAll: String {
            NSLocalizedString("picker.deselectAll", value: "Deselect All", comment: "Button to deselect all dictionaries")
        }
        static var continueButton: String {
            NSLocalizedString("picker.continue", value: "Continue", comment: "Button to continue to next step")
        }
        static var confirmSelection: String {
            NSLocalizedString("picker.confirmSelection", value: "Confirm Selection", comment: "Button to confirm selection (no count)")
        }
    }

    // MARK: - Import Progress

    enum Progress {
        static var title: String {
            NSLocalizedString("progress.title", value: "Setting Up Dictionaries", comment: "Import progress screen title")
        }
        static var importing: String {
            NSLocalizedString("progress.importing", value: "Importing\u{2026}", comment: "Import in progress button text")
        }
        static func downloading(percent: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("progress.downloading", value: "Downloading\u{2026} %d%%", comment: "Download progress with percentage"),
                percent
            )
        }
        static func downloadingBytes(completedMB: Double, totalMB: Double) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("progress.downloadingBytes", value: "Downloaded %.1f MB / %.1f MB", comment: "Download progress with megabyte counts; %.1f = completed MB, %.1f = total MB"),
                completedMB, totalMB
            )
        }
    }

    // MARK: - Sidebar

    enum Sidebar {
        static var importDictionary: String {
            NSLocalizedString("sidebar.importDictionary", value: "Import Dictionary", comment: "Sidebar management action")
        }
        static var addNewGroup: String {
            NSLocalizedString("sidebar.addNewGroup", value: "Add New Group", comment: "Sidebar management action")
        }
        static var presetDictionaries: String {
            NSLocalizedString("sidebar.presetDictionaries", value: "Preset Dictionaries", comment: "Sidebar management action")
        }
        static var appSettings: String {
            NSLocalizedString("sidebar.appSettings", value: "App Settings", comment: "Sidebar management action")
        }
        static var myGroups: String {
            NSLocalizedString("sidebar.myGroups", value: "My Groups", comment: "Sidebar section header")
        }
        static var management: String {
            NSLocalizedString("sidebar.management", value: "Management", comment: "Sidebar section header")
        }
        static var dictionaries: String {
            NSLocalizedString("sidebar.dictionaries", value: "Dictionaries", comment: "Back button title for sidebar")
        }
        static var editInfo: String {
            NSLocalizedString("sidebar.editInfo", value: "Edit Info", comment: "Context menu action")
        }
        static var viewInfo: String {
            NSLocalizedString("sidebar.viewInfo", value: "View Info", comment: "Context menu action")
        }
        static var moveUp: String {
            NSLocalizedString("sidebar.moveUp", value: "Move Up", comment: "Context menu action")
        }
        static var moveDown: String {
            NSLocalizedString("sidebar.moveDown", value: "Move Down", comment: "Context menu action")
        }
        static var deleteGroup: String {
            NSLocalizedString("sidebar.deleteGroup", value: "Delete Group", comment: "Context menu action and alert title")
        }
        static var dictionaryNotLoaded: String {
            NSLocalizedString("sidebar.dictionaryNotLoaded", value: "Dictionary not loaded", comment: "Status text for unloaded dictionary")
        }
        static var bookmarks: String {
            NSLocalizedString("sidebar.bookmarks", value: "My Bookmarks", comment: "Sidebar management action: bookmarks")
        }
        static var lookupHistory: String {
            NSLocalizedString("sidebar.lookupHistory", value: "My Lookup History", comment: "Sidebar management action: lookup history")
        }
    }

    // MARK: - Word List & Search

    enum WordList {
        static var searchPlaceholder: String {
            NSLocalizedString("wordList.searchPlaceholder", value: "Search words\u{2026}", comment: "Search bar placeholder")
        }
        static var typeToSearch: String {
            NSLocalizedString("wordList.typeToSearch", value: "Type to search", comment: "Empty state when no query entered")
        }
        static var selectDictionaryOrGroup: String {
            NSLocalizedString("wordList.selectDictionaryOrGroup", value: "Select a dictionary or group", comment: "Empty state when no dictionary selected")
        }
        static func noResults(query: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("wordList.noResults", value: "No results for \u{2018}%@\u{2019}", comment: "Empty state when search finds nothing; %@ is the query"),
                query
            )
        }
        static var wordSearch: String {
            NSLocalizedString("wordList.wordSearch", value: "Word Search", comment: "Back button title")
        }
    }

    // MARK: - Articles & Article Renderer

    enum Articles {
        static var selectWord: String {
            NSLocalizedString("articles.selectWord", value: "Select a word to view", comment: "Empty state for article area")
        }
        static var open: String {
            NSLocalizedString("articles.open", value: "Open", comment: "Context menu: open article")
        }
        static var openInNewWindow: String {
            NSLocalizedString("articles.openInNewWindow", value: "Open in New Window", comment: "Context menu: open in new window")
        }
        static var bookmark: String {
            NSLocalizedString("articles.bookmark", value: "Bookmark", comment: "Context menu: bookmark article")
        }
        static var findInPage: String {
            NSLocalizedString("articles.findInPage", value: "Find in Page", comment: "Context menu: find text in article")
        }
        static var removeBookmark: String {
            NSLocalizedString("articles.removeBookmark", value: "Remove Bookmark", comment: "Context menu: remove bookmark from article")
        }
        static var close: String {
            NSLocalizedString("articles.close", value: "Close", comment: "Context menu: close article")
        }

        // HTML renderer strings
        static func loadingWord(_ word: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("articles.loadingWord", value: "Loading \u{201C}%@\u{201D}\u{2026}", comment: "Loading state for article; %@ is the word"),
                word
            )
        }
        static func notFoundTitle(_ word: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("articles.notFound.title", value: "\u{201C}%@\u{201D} not found", comment: "Article not found title; %@ is the word"),
                word
            )
        }
        static func notFoundSubtitle(dictName: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("articles.notFound.subtitle", value: "in %@", comment: "Article not found subtitle; %@ is the dictionary name"),
                dictName
            )
        }
        static func lookupCount(_ count: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("articles.lookupCount", value: "You have looked this word up %d times", comment: "Lookup count shown in article header; %d is the number of lookups"),
                count
            )
        }
    }

    // MARK: - Dictionary Info

    enum DictInfo {
        static var importDictionary: String {
            NSLocalizedString("dictInfo.importDictionary", value: "Import Dictionary", comment: "Screen title for dict import")
        }
        static var selectMdxFile: String {
            NSLocalizedString("dictInfo.selectMdxFile", value: "Select MDX File", comment: "Button to pick an MDX file")
        }
        static var emptyState: String {
            NSLocalizedString("dictInfo.emptyState", value: "Select an MDX file to import\na new dictionary", comment: "Empty state for import screen")
        }
        static var alreadyImportedTitle: String {
            NSLocalizedString("dictInfo.alreadyImported.title", value: "Dictionary Already Imported", comment: "Warning title when dict is already imported")
        }
        static var alreadyImportedSubtitle: String {
            NSLocalizedString("dictInfo.alreadyImported.subtitle", value: "Tap to view the existing dictionary", comment: "Warning subtitle when dict is already imported")
        }
        static var manageResources: String {
            NSLocalizedString("dictInfo.manageResources", value: "Manage Resources", comment: "Button to manage dict resources")
        }
        static var customName: String {
            NSLocalizedString("dictInfo.customName", value: "Custom Name", comment: "Section header")
        }
        static var basicInfo: String {
            NSLocalizedString("dictInfo.basicInfo", value: "Basic Info", comment: "Section header")
        }
        static var technicalDetails: String {
            NSLocalizedString("dictInfo.technicalDetails", value: "Technical Details", comment: "Section header")
        }
        static var descriptionHeader: String {
            NSLocalizedString("dictInfo.description", value: "Description", comment: "Section header for dictionary description")
        }
        static var noCustomName: String {
            NSLocalizedString("dictInfo.noCustomName", value: "No custom name", comment: "Placeholder when no custom name set")
        }
        static var noDescription: String {
            NSLocalizedString("dictInfo.noDescription", value: "No description", comment: "Placeholder when no description available")
        }
        static var deleteDictionary: String {
            NSLocalizedString("dictInfo.deleteDictionary", value: "Delete Dictionary", comment: "Destructive action button")
        }

        // Metadata labels
        static var metaTitle: String {
            NSLocalizedString("dictInfo.meta.title", value: "Title", comment: "Metadata label")
        }
        static var metaEntries: String {
            NSLocalizedString("dictInfo.meta.entries", value: "Entries", comment: "Metadata label")
        }
        static var metaDateCreated: String {
            NSLocalizedString("dictInfo.meta.dateCreated", value: "Date Created", comment: "Metadata label")
        }
        static var metaDateImported: String {
            NSLocalizedString("dictInfo.meta.dateImported", value: "Date Imported", comment: "Metadata label")
        }
        static var metaEngineVersion: String {
            NSLocalizedString("dictInfo.meta.engineVersion", value: "Engine Version", comment: "Metadata label")
        }
        static var metaFormat: String {
            NSLocalizedString("dictInfo.meta.format", value: "Format", comment: "Metadata label")
        }
        static var metaEncoding: String {
            NSLocalizedString("dictInfo.meta.encoding", value: "Encoding", comment: "Metadata label")
        }
        static var metaEncrypted: String {
            NSLocalizedString("dictInfo.meta.encrypted", value: "Encrypted", comment: "Metadata label")
        }
        static var metaCaseSensitive: String {
            NSLocalizedString("dictInfo.meta.caseSensitive", value: "Case Sensitive", comment: "Metadata label")
        }

        // Alerts
        static var importQuestion: String {
            NSLocalizedString("dictInfo.importQuestion", value: "Import Dictionary?", comment: "Alert title to confirm import")
        }
        static func importMessage(filename: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("dictInfo.importMessage", value: "Import \u{201C}%@\u{201D} to your library?", comment: "Alert body for import confirmation; %@ is the filename"),
                filename
            )
        }
        static var saveChangesTitle: String {
            NSLocalizedString("dictInfo.saveChanges.title", value: "Save Changes?", comment: "Alert title to confirm save")
        }
        static var saveChangesMessage: String {
            NSLocalizedString("dictInfo.saveChanges.message", value: "Save your changes to this dictionary?", comment: "Alert body for save confirmation")
        }
        static func deleteMessage(name: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("dictInfo.deleteMessage", value: "Are you sure you want to delete \u{201C}%@\u{201D}? This action cannot be undone.", comment: "Alert body for delete confirmation; %@ is the dict name"),
                name
            )
        }
        static var importFailed: String {
            NSLocalizedString("dictInfo.importFailed", value: "Import Failed", comment: "Alert title when import fails")
        }
        static var deleteFailed: String {
            NSLocalizedString("dictInfo.deleteFailed", value: "Delete Failed", comment: "Alert title when delete fails")
        }
        static var lookupCount: String {
            NSLocalizedString("dictInfo.lookupCount", value: "Lookups", comment: "Metadata label: number of lookups for this dictionary")
        }
    }

    // MARK: - Group Info

    enum GroupInfo {
        static var groupName: String {
            NSLocalizedString("groupInfo.groupName", value: "Group Name", comment: "Section header for group name (default group)")
        }
        static var customName: String {
            NSLocalizedString("groupInfo.customName", value: "Custom Name", comment: "Section header for group name (user group)")
        }
        static var containedItems: String {
            NSLocalizedString("groupInfo.containedItems", value: "Contained Items", comment: "Section header for items in group")
        }
        static var groupInfoHeader: String {
            NSLocalizedString("groupInfo.groupInfo", value: "Group Info", comment: "Section header for metadata")
        }
        static var created: String {
            NSLocalizedString("groupInfo.created", value: "Created", comment: "Date label")
        }
        static var modified: String {
            NSLocalizedString("groupInfo.modified", value: "Modified", comment: "Date label")
        }
        static var newGroup: String {
            NSLocalizedString("groupInfo.newGroup", value: "New Group", comment: "Screen title for creating a group")
        }
        static var deleteGroup: String {
            NSLocalizedString("groupInfo.deleteGroup", value: "Delete Group", comment: "Destructive action button and alert title")
        }
        static var discardNewGroupTitle: String {
            NSLocalizedString("groupInfo.discardNewGroup.title", value: "Discard New Group?", comment: "Alert title when discarding new group")
        }
        static var discardNewGroupMessage: String {
            NSLocalizedString("groupInfo.discardNewGroup.message", value: "The new group will not be saved.", comment: "Alert body when discarding new group")
        }
        static func deleteGroupMessage(name: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("groupInfo.deleteGroupMessage", value: "Delete \u{201C}%@\u{201D}? Dictionaries in this group will not be removed.", comment: "Alert body for group delete; %@ is the group name"),
                name
            )
        }
        static var tapToAddDictionaries: String {
            NSLocalizedString("groupInfo.tapToAdd", value: "Tap to add dictionaries", comment: "Placeholder for empty group")
        }
        static var addAtLeastOne: String {
            NSLocalizedString("groupInfo.addAtLeastOne", value: "Add at least one dictionary", comment: "Warning when trying to save empty group")
        }
        static var reorderDictionaries: String {
            NSLocalizedString("groupInfo.reorderDictionaries", value: "Reorder Dictionaries", comment: "Button to reorder dictionaries")
        }
        static var untitledGroup: String {
            NSLocalizedString("groupInfo.untitledGroup", value: "Untitled Group", comment: "Placeholder name for unnamed group")
        }
        static var nameCannotBeEmpty: String {
            NSLocalizedString("groupInfo.nameCannotBeEmpty", value: "Custom name cannot be empty", comment: "Validation error header")
        }
        static var nameAlreadyTaken: String {
            NSLocalizedString("groupInfo.nameAlreadyTaken", value: "This name is already taken", comment: "Validation error header")
        }
        static var group: String {
            NSLocalizedString("groupInfo.group", value: "Group", comment: "Fallback navigation title for group screen")
        }
        static var allDictionaries: String {
            NSLocalizedString("groupInfo.allDictionaries", value: "All Dictionaries", comment: "Navigation title for default group")
        }
        static var lookupCount: String {
            NSLocalizedString("groupInfo.lookupCount", value: "Lookups", comment: "Metadata label: total lookups for this group")
        }
    }

    // MARK: - Resource Editor

    enum ResourceEditor {
        static var noSelection: String {
            NSLocalizedString("resourceEditor.noSelection", value: "No Dictionary Selected", comment: "Empty state title")
        }
        static var noSelectionSubtitle: String {
            NSLocalizedString("resourceEditor.noSelectionSubtitle", value: "Select a dictionary to manage its resources", comment: "Empty state subtitle")
        }
        static var resources: String {
            NSLocalizedString("resourceEditor.resources", value: "Resources", comment: "Navigation title")
        }
        static var sectionMdx: String {
            NSLocalizedString("resourceEditor.section.mdx", value: "DICTIONARY FILE (MDX)", comment: "Section header")
        }
        static var sectionMdd: String {
            NSLocalizedString("resourceEditor.section.mdd", value: "RESOURCE FILES (MDD)", comment: "Section header")
        }
        static var sectionCss: String {
            NSLocalizedString("resourceEditor.section.css", value: "CUSTOM STYLES (CSS)", comment: "Section header")
        }
        static var sectionJs: String {
            NSLocalizedString("resourceEditor.section.js", value: "CUSTOM SCRIPTS (JS)", comment: "Section header")
        }
        static var deleteResourceTitle: String {
            NSLocalizedString("resourceEditor.deleteResource.title", value: "Delete Resource?", comment: "Alert title for resource deletion")
        }
        static func deleteResourceMessage(filename: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("resourceEditor.deleteResource.message", value: "Are you sure you want to delete %@? This action cannot be undone.", comment: "Alert body for resource deletion; %@ is the filename"),
                filename
            )
        }
        static var addingResource: String {
            NSLocalizedString("resourceEditor.addingResource", value: "Adding resource\u{2026}", comment: "Loading modal text while adding a resource")
        }
        static func addFile(ext: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("resourceEditor.addFile", value: "Add %@ File", comment: "Button to add a resource file; %@ is the extension (e.g. MDD, CSS)"),
                ext
            )
        }
        static func noFiles(type: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("resourceEditor.noFiles", value: "No %@", comment: "Placeholder when no resources of a type; %@ is the type name"),
                type
            )
        }
    }

    // MARK: - Dictionary Editor (Group)

    enum DictEditor {
        static var noSelection: String {
            NSLocalizedString("dictEditor.noSelection", value: "No Group Selected", comment: "Empty state title")
        }
        static var noSelectionSubtitle: String {
            NSLocalizedString("dictEditor.noSelectionSubtitle", value: "Select a group to manage its dictionaries", comment: "Empty state subtitle")
        }
        static var dictionaries: String {
            NSLocalizedString("dictEditor.dictionaries", value: "Dictionaries", comment: "Navigation title")
        }
        static var inThisGroup: String {
            NSLocalizedString("dictEditor.inThisGroup", value: "IN THIS GROUP", comment: "Section header")
        }
        static var available: String {
            NSLocalizedString("dictEditor.available", value: "AVAILABLE DICTIONARIES", comment: "Section header")
        }
        static var noDictionariesInGroup: String {
            NSLocalizedString("dictEditor.noDictionariesInGroup", value: "No dictionaries in this group", comment: "Placeholder for empty group section")
        }
        static var allAdded: String {
            NSLocalizedString("dictEditor.allAdded", value: "All dictionaries added", comment: "Placeholder when all dicts are in group")
        }
        static var noDictionaries: String {
            NSLocalizedString("dictEditor.noDictionaries", value: "No dictionaries", comment: "Placeholder for reorder mode with empty list")
        }
        static var sectionDictionaries: String {
            NSLocalizedString("dictEditor.sectionDictionaries", value: "DICTIONARIES", comment: "Section header in reorder mode")
        }
    }

    // MARK: - Lookup History

    enum History {
        static var clearAll: String {
            NSLocalizedString("history.clearAll", value: "Clear All", comment: "Button to clear all lookup history")
        }
        static var clearAllConfirmTitle: String {
            NSLocalizedString("history.clearAllConfirm.title", value: "Clear Lookup History?", comment: "Alert title to confirm clearing all history")
        }
        static var clearAllConfirmMessage: String {
            NSLocalizedString("history.clearAllConfirm.message", value: "This cannot be undone.", comment: "Alert body to confirm clearing all history")
        }
        static var emptyState: String {
            NSLocalizedString("history.emptyState", value: "No lookup history", comment: "Empty state when no lookup history exists")
        }
    }

    // MARK: - Lookup History (Centralized List)

    enum LookupHistory {
        static var title: String {
            NSLocalizedString("lookupHistory.title", value: "My Lookup History", comment: "Navigation title for centralized lookup history list")
        }
        static var empty: String {
            NSLocalizedString("lookupHistory.empty", value: "No lookup history", comment: "Empty state title for lookup history")
        }
        static var emptySubtitle: String {
            NSLocalizedString("lookupHistory.emptySubtitle", value: "Words you look up will appear here", comment: "Empty state subtitle for lookup history")
        }
        static var clearAllConfirmTitle: String {
            NSLocalizedString("lookupHistory.clearAllConfirmTitle", value: "Clear All Lookup History?", comment: "Alert title for clearing all lookup history")
        }
        static var clearAllConfirmMessage: String {
            NSLocalizedString("lookupHistory.clearAllConfirmMessage", value: "All lookup history will be removed. This cannot be undone.", comment: "Alert body for clearing all lookup history")
        }
    }

    // MARK: - Bookmark Sort Modes

    enum BookmarkSort {
        static var byBookmarkDate: String {
            NSLocalizedString("bookmarkSort.byBookmarkDate", value: "Bookmark Date", comment: "Bookmark sort mode: by date bookmarked")
        }
        static var byLastLookup: String {
            NSLocalizedString("bookmarkSort.byLastLookup", value: "Recent Lookup Date", comment: "Bookmark sort mode: by last lookup date")
        }
        static var byLookupCount: String {
            NSLocalizedString("bookmarkSort.byLookupCount", value: "Lookup Times", comment: "Bookmark sort mode: by total lookup count")
        }
        static var ascending: String {
            NSLocalizedString("bookmarkSort.ascending", value: "Ascending", comment: "Sort order: ascending (oldest/lowest first)")
        }
        static var descending: String {
            NSLocalizedString("bookmarkSort.descending", value: "Descending", comment: "Sort order: descending (newest/highest first)")
        }
    }

    // MARK: - Bookmarks

    enum Bookmarks {
        static var title: String {
            NSLocalizedString("bookmarks.title", value: "My Bookmarks", comment: "Navigation title for bookmarks list")
        }
        static var empty: String {
            NSLocalizedString("bookmarks.empty", value: "No bookmarks yet", comment: "Empty state title for bookmarks")
        }
        static var emptySubtitle: String {
            NSLocalizedString("bookmarks.emptySubtitle", value: "Tap the bookmark icon on any article to save it here", comment: "Empty state subtitle for bookmarks")
        }
        static var removeBookmark: String {
            NSLocalizedString("bookmarks.removeBookmark", value: "Remove Bookmark", comment: "Swipe action to remove a bookmark")
        }
        static func removeBookmarkMessage(word: String, dictName: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("bookmarks.removeBookmarkMessage",
                                  value: "\u{201C}%@\u{201D}\nfrom %@\nwill be removed from your bookmarks.",
                                  comment: "Alert body confirming bookmark removal; first %@ is the word, second %@ is the dictionary name"),
                word, dictName
            )
        }
        static var clearAll: String {
            NSLocalizedString("bookmarks.clearAll", value: "Clear All", comment: "Button to clear all bookmarks")
        }
        static var clearAllConfirm: String {
            NSLocalizedString("bookmarks.clearAllConfirm", value: "Are you sure you want to remove all bookmarks?", comment: "Alert body to confirm clearing all bookmarks")
        }
    }

    // MARK: - History Section Headers (Date Grouping)

    enum HistorySection {
        static var today: String {
            NSLocalizedString("historySection.today", value: "Today", comment: "History date group: today")
        }
        static var yesterday: String {
            NSLocalizedString("historySection.yesterday", value: "Yesterday", comment: "History date group: yesterday")
        }
        static func daysAgo(_ n: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("historySection.daysAgo", value: "%d Days Ago", comment: "History date group: N days ago"),
                n
            )
        }
        static func weeksAgo(_ n: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("historySection.weeksAgo", value: "%d Weeks Ago", comment: "History date group: N weeks ago"),
                n
            )
        }
        static var earlierThisMonth: String {
            NSLocalizedString("historySection.earlierThisMonth", value: "Earlier This Month", comment: "History date group: earlier this month")
        }
        static var lastMonth: String {
            NSLocalizedString("historySection.lastMonth", value: "Last Month", comment: "History date group: last month")
        }
        static var lastYear: String {
            NSLocalizedString("historySection.lastYear", value: "Last Year", comment: "History date group: last year")
        }
        static var unknown: String {
            NSLocalizedString("historySection.unknown", value: "Unknown", comment: "History date group: unknown date")
        }
    }

    // MARK: - Detail Container (Layout, Appearance, Zoom)

    enum Detail {
        static var layout: String {
            NSLocalizedString("detail.layout", value: "Layout", comment: "Menu title for article layout options")
        }
        static var appearance: String {
            NSLocalizedString("detail.appearance", value: "Appearance", comment: "Menu title for appearance/theme options")
        }
        static var light: String {
            NSLocalizedString("detail.light", value: "Light", comment: "Appearance mode: light")
        }
        static var auto: String {
            NSLocalizedString("detail.auto", value: "Auto", comment: "Appearance mode: system auto")
        }
        static var dark: String {
            NSLocalizedString("detail.dark", value: "Dark", comment: "Appearance mode: dark")
        }
        static var zoom: String {
            NSLocalizedString("detail.zoom", value: "Zoom", comment: "Menu title for zoom options")
        }
        static var zoomIn: String {
            NSLocalizedString("detail.zoomIn", value: "Zoom In", comment: "Zoom action")
        }
        static var zoomOut: String {
            NSLocalizedString("detail.zoomOut", value: "Zoom Out", comment: "Zoom action")
        }
        static var reset: String {
            NSLocalizedString("detail.reset", value: "Reset", comment: "Reset zoom to default")
        }
        static func currentZoomLevel(_ level: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("detail.currentZoomLevel", value: "Current zoom level: %@", comment: "Zoom menu title showing current level"),
                level
            )
        }
        static func currentLevel(_ level: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("detail.currentLevel", value: "Current level: %@", comment: "Compact zoom menu title showing current level"),
                level
            )
        }
        static var find: String {
            NSLocalizedString("detail.find", value: "Find", comment: "Find in page action")
        }
        static var keywordsPlaceholder: String {
            NSLocalizedString("detail.keywordsPlaceholder", value: "Keywords to highlight\u{2026}", comment: "Search bar placeholder for keyword highlighting")
        }
        static var importingDictionary: String {
            NSLocalizedString("detail.importingDictionary", value: "Importing dictionary\u{2026}", comment: "Loading modal text during dict import")
        }
    }

    // MARK: - Group Info (additional nav titles)

    // (GroupInfo enum already defined above — these are additions)

    // MARK: - Plurals

    static func entryCount(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("plural.entries", value: "%d entries", comment: "Number of dictionary entries"),
            count
        )
    }

    static func dictionaryCount(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("plural.dictionaries", value: "%d dictionaries", comment: "Number of dictionaries in a group"),
            count
        )
    }

    static func allImportedSuccess(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("plural.allImported", value: "All %d dictionaries imported successfully!", comment: "Import success message"),
            count
        )
    }

    static func importedAndFailed(imported: Int, failed: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("plural.importedFailed", value: "%1$d imported, %2$d failed", comment: "Import summary: %1$d = succeeded, %2$d = failed"),
            imported, failed
        )
    }

    static func importingProgress(current: Int, total: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("plural.importingProgress", value: "Importing %1$d of %2$d\u{2026}", comment: "Import progress: %1$d = current, %2$d = total"),
            current, total
        )
    }

    static func confirmSelection(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("plural.confirmSelection", value: "Confirm Selection (%d items)", comment: "Picker continue button with count"),
            count
        )
    }
}
