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

        // Feature cards (order matches WelcomePageViewController)
        static var layoutsTitle: String {
            NSLocalizedString("welcome.feature.layouts.title", value: "Three Layout Modes on iPadOS", comment: "Feature card title")
        }
        static var layoutsBody: String {
            NSLocalizedString("welcome.feature.layouts.body", value: "View multiple definitions from different dictionaries in Columns, Grid or List, all at once.", comment: "Feature card body")
        }
        static var multiWindowTitle: String {
            NSLocalizedString("welcome.feature.multiWindow.title", value: "Multi-Window on iPadOS", comment: "Feature card title")
        }
        static var multiWindowBody: String {
            NSLocalizedString("welcome.feature.multiWindow.body", value: "Enjoy desktop-class productivity by utilizing multiple windows and keyboard shortcuts.", comment: "Feature card body")
        }
        static var extensionsTitle: String {
            NSLocalizedString("welcome.feature.extensions.title", value: "Quick Lookup and Jump Search", comment: "Feature card title for Action Extension + jump search")
        }
        static var extensionsBody: String {
            NSLocalizedString("welcome.feature.extensions.body", value: "Look up words from any app in a pop-up, then keep jump-searching unfamiliar terms within definitions until every word is clear.", comment: "Feature card body for Action Extension + jump search")
        }
        static var presetsTitle: String {
            NSLocalizedString("welcome.feature.presets.title", value: "Preset Dictionaries Included", comment: "Feature card title")
        }
        static var presetsBody: String {
            NSLocalizedString("welcome.feature.presets.body", value: "Pick your starter pack from our curated selection of open-source dictionaries, ready to use with minimum setup.", comment: "Feature card body")
        }
        static var noLimitsTitle: String {
            NSLocalizedString("welcome.feature.noLimits.title", value: "No Limits, Free Forever", comment: "Feature card title")
        }
        static var noLimitsBody: String {
            NSLocalizedString("welcome.feature.noLimits.body", value: "Import unlimited dictionaries and create unlimited groups, without any subscriptions or paid memberships.", comment: "Feature card body")
        }
    }

    // MARK: - Preset Dictionary Picker

    enum Picker {
        static var titleFirstInstall: String {
            NSLocalizedString("picker.title.firstInstall", value: "Choose Dictionaries", comment: "Picker title on first install")
        }
        static var titleManagement: String {
            NSLocalizedString("picker.title.management", value: "Download Presets", comment: "Picker title when adding more presets (matches sidebar label)")
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
        static var skipPresets: String {
            NSLocalizedString("picker.skipPresets", value: "Skip", comment: "Button to skip preset dictionary selection")
        }

        // Section headers (region names)
        static var regionFarEast: String {
            NSLocalizedString("picker.region.farEast", value: "Far East", comment: "Picker section header: Far East region")
        }
        static var regionEurope: String {
            NSLocalizedString("picker.region.europe", value: "Europe", comment: "Picker section header: Europe region")
        }
        static var regionMiddleEast: String {
            NSLocalizedString("picker.region.middleEast", value: "Middle East", comment: "Picker section header: Middle East region")
        }
        static var regionClassical: String {
            NSLocalizedString("picker.region.classical", value: "Classical", comment: "Picker section header: Classical languages region")
        }
        static var regionBible: String {
            NSLocalizedString("picker.region.bible", value: "Bible", comment: "Picker section header: Bible translations region")
        }

        // Empty state
        static var allPresetsInstalled: String {
            NSLocalizedString("picker.allPresetsInstalled", value: "All available preset dictionaries have been installed on your device.", comment: "Empty state when all preset dictionaries are already imported")
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
        static func downloadComplete(size: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("progress.downloadComplete", value: "Download complete: %@", comment: "Subtitle after download finishes; %@ is the formatted file size"),
                size
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
        static var downloadPresets: String {
            NSLocalizedString("sidebar.downloadPresets", value: "Download Presets", comment: "Sidebar management action: download preset dictionaries")
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
            NSLocalizedString("wordList.searchPlaceholder", value: "Type your query here\u{2026}", comment: "Search bar placeholder")
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

        // Section headers (enhanced search UX)
        static var clipboardHeader: String {
            NSLocalizedString("wordList.clipboardHeader", value: "Clipboard", comment: "Section header for clipboard paste section")
        }
        static var clipboardPasteToSearch: String {
            NSLocalizedString("wordList.clipboardPasteToSearch", value: "Paste to search", comment: "Clipboard cell secondary text")
        }
        static var clipboardEmpty: String {
            NSLocalizedString("wordList.clipboardEmpty", value: "Copy a word to paste here", comment: "Clipboard cell text when clipboard is empty")
        }
        static var clipboardPasteFromClipboard: String {
            NSLocalizedString("wordList.clipboardPasteFromClipboard", value: "Paste from clipboard", comment: "Clipboard cell text on iOS 16+ — tapping triggers paste permission alert")
        }
        static var searchResultsHeader: String {
            NSLocalizedString("wordList.searchResultsHeader", value: "Search Results", comment: "Section header for search results")
        }
        static var relatedFormsHeader: String {
            NSLocalizedString("wordList.relatedFormsHeader", value: "Related Forms", comment: "Section header for lemma-resolved related word forms (inflections, base forms)")
        }
        static var suggestionsHeader: String {
            NSLocalizedString("wordList.suggestionsHeader", value: "Suggestions", comment: "Section header for suggested similar words")
        }
        static var searching: String {
            NSLocalizedString("wordList.searching", value: "Searching\u{2026}", comment: "Empty state shown while search pipeline is still running")
        }

        // Empty state (context-filtered history)
        static func noHistoryInSource(_ name: String) -> String {
            String(format: NSLocalizedString("wordList.noHistoryInSource", value: "No lookup history in \u{201C}%@\u{201D}", comment: "Empty state when selected group/dictionary has no lookup history. %@ = group or dictionary name"), name)
        }
        static var noHistoryInContextMessage: String {
            NSLocalizedString("wordList.noHistoryInContextMessage", value: "Words you look up here will appear as recent history.", comment: "Message explaining that history will populate with use")
        }
        static var viewAllHistory: String {
            NSLocalizedString("wordList.viewAllHistory", value: "View All History", comment: "Button to navigate to centralized lookup history")
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
        static var jumpSearch: String {
            NSLocalizedString("articles.jumpSearch", value: "Jump Search", comment: "WKWebView text selection menu: look up selected text in the same dictionary")
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
        static func loadingMessage(dictName: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("articles.loadingMessage", value: "Definition will appear once \u{201C}%@\u{201D} finishes loading.", comment: "Placeholder message while dictionary loads; %@ is the dictionary name"),
                dictName
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

        // Display Settings
        static var displaySettings: String {
            NSLocalizedString("dictInfo.displaySettings", value: "Display", comment: "Section header for per-dict display preferences")
        }
        static var enhanceDarkMode: String {
            NSLocalizedString("dictInfo.enhanceDarkMode", value: "Enhance Dark Mode", comment: "Toggle label for per-dict dark mode enhancement")
        }
        static var enhanceDarkModeDescription: String {
            NSLocalizedString("dictInfo.enhanceDarkModeDescription", value: "Improve readability if this dictionary has custom styles.", comment: "Subtitle explaining the dark mode enhancement toggle")
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
            NSLocalizedString("dictInfo.lookupCount", value: "Lookup Times", comment: "Metadata label: monotonic trophy counter for lookup times")
        }
        static var bookmarkCount: String {
            NSLocalizedString("dictInfo.bookmarkCount", value: "Bookmark Times", comment: "Metadata label: monotonic trophy counter for bookmark times")
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
            NSLocalizedString("groupInfo.lookupCount", value: "Lookup Times", comment: "Metadata label: monotonic trophy counter for lookup times")
        }
        static var bookmarkCount: String {
            NSLocalizedString("groupInfo.bookmarkCount", value: "Bookmark Times", comment: "Metadata label: monotonic trophy counter for bookmark times")
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
            NSLocalizedString("lookupHistory.title", value: "Lookup History", comment: "Navigation title for centralized lookup history list")
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
        static var sortBy: String {
            NSLocalizedString("bookmarkSort.sortBy", value: "Sort By", comment: "Navigation bar button title: choose sort mode")
        }
        static var sortOrder: String {
            NSLocalizedString("bookmarkSort.sortOrder", value: "Sort Order", comment: "Navigation bar button title: choose sort order")
        }
    }

    // MARK: - Bookmarks

    enum Bookmarks {
        static var title: String {
            NSLocalizedString("bookmarks.title", value: "Bookmarks", comment: "Navigation title for bookmarks list")
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

    // MARK: - Dictionary Availability

    /// Suffix shown after dictName when the dictionary is not available locally.
    static var dictUnavailable: String {
        NSLocalizedString("dict.unavailable", value: "Dictionary not imported", comment: "Shown when the dictionary for a history/bookmark entry is not available locally")
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

    // MARK: - Keyboard Shortcuts

    enum Shortcuts {

        // MARK: Category Labels (6 categories for HUD)

        static var categoryQuery: String {
            NSLocalizedString("shortcuts.category.query", value: "Query", comment: "Keyboard shortcut HUD category: query/lookup")
        }
        static var categoryHistory: String {
            NSLocalizedString("shortcuts.category.history", value: "History", comment: "Keyboard shortcut HUD category: lookup history")
        }
        static var categoryBookmarks: String {
            NSLocalizedString("shortcuts.category.bookmarks", value: "Bookmarks", comment: "Keyboard shortcut HUD category: bookmarks")
        }
        static var categoryUtilities: String {
            NSLocalizedString("shortcuts.category.utilities", value: "Utilities", comment: "Keyboard shortcut HUD category: utilities")
        }

        // MARK: Query Category

        static var focusLookup: String {
            NSLocalizedString("shortcuts.focusLookup", value: "Focus on Query Input", comment: "Keyboard shortcut: focus on the query/lookup search bar")
        }
        /// "Select "All Dictionaries"" — default group (⌥⌘`)
        static var selectAllDictionaries: String {
            NSLocalizedString("shortcuts.selectAllDictionaries", value: "Select \"All Dictionaries\"", comment: "Keyboard shortcut: select the default group (all dictionaries)")
        }
        /// "Select My 1st Group" … "Select My 9th Group" — user groups (⌥⌘1~9)
        static func group(_ n: Int) -> String {
            let ordinal = ordinalString(n)
            return String.localizedStringWithFormat(
                NSLocalizedString("shortcuts.selectMyGroup", value: "Select My %@ Group", comment: "Keyboard shortcut: select Nth user group; %@ is an ordinal like 1st, 2nd, 3rd"),
                ordinal
            )
        }
        /// "Select 1st Dictionary" … "Select 9th Dictionary" (⌃⌥⌘1~9)
        static func dictionary(_ n: Int) -> String {
            let ordinal = ordinalString(n)
            return String.localizedStringWithFormat(
                NSLocalizedString("shortcuts.selectDictionary", value: "Select %@ Dictionary", comment: "Keyboard shortcut: select Nth dictionary in default group; %@ is an ordinal like 1st, 2nd, 3rd"),
                ordinal
            )
        }

        /// Returns the English ordinal string for a number (1→"1st", 2→"2nd", …).
        /// For localized builds the format strings handle this differently.
        private static func ordinalString(_ n: Int) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
        }

        // MARK: View Category (appended to system .view)

        static var columnsLayout: String {
            NSLocalizedString("shortcuts.columnsLayout", value: "Switch to Columns Layout", comment: "Keyboard shortcut: switch to columns layout")
        }
        static var gridLayout: String {
            NSLocalizedString("shortcuts.gridLayout", value: "Switch to Grid Layout", comment: "Keyboard shortcut: switch to grid layout")
        }
        static var listLayout: String {
            NSLocalizedString("shortcuts.listLayout", value: "Switch to List Layout", comment: "Keyboard shortcut: switch to list layout")
        }
        static var toggleAppearance: String {
            NSLocalizedString("shortcuts.toggleAppearance", value: "Toggle Appearance", comment: "Keyboard shortcut: cycle light/system/dark")
        }
        static var zoomIn: String {
            NSLocalizedString("shortcuts.zoomIn", value: "Zoom In", comment: "Keyboard shortcut: zoom in")
        }
        static var zoomOut: String {
            NSLocalizedString("shortcuts.zoomOut", value: "Zoom Out", comment: "Keyboard shortcut: zoom out")
        }
        static var actualSize: String {
            NSLocalizedString("shortcuts.actualSize", value: "Actual Size", comment: "Keyboard shortcut: reset zoom to 100%")
        }
        static var findInPage: String {
            NSLocalizedString("shortcuts.findInPage", value: "Find in Page", comment: "Keyboard shortcut: find text in current page")
        }

        // MARK: Bookmarks & History Category

        static var showBookmarks: String {
            NSLocalizedString("shortcuts.showBookmarks", value: "Show Bookmarks", comment: "Keyboard shortcut: show bookmarks list")
        }
        static var showHistory: String {
            NSLocalizedString("shortcuts.showHistory", value: "Show History", comment: "Keyboard shortcut: show lookup history list")
        }

        // MARK: Window Category (appended to system .window)

        static var closeArticle: String {
            NSLocalizedString("shortcuts.closeArticle", value: "Close Article", comment: "Keyboard shortcut: close most recent article (辞条)")
        }
        static var previousPage: String {
            NSLocalizedString("shortcuts.previousPage", value: "Previous Page", comment: "Keyboard shortcut: previous article in list layout")
        }
        static var nextPage: String {
            NSLocalizedString("shortcuts.nextPage", value: "Next Page", comment: "Keyboard shortcut: next article in list layout")
        }
        static var previousSource: String {
            NSLocalizedString("shortcuts.previousSource", value: "Previous Source", comment: "Keyboard shortcut: cycle to previous query source (group or dictionary)")
        }
        static var nextSource: String {
            NSLocalizedString("shortcuts.nextSource", value: "Next Source", comment: "Keyboard shortcut: cycle to next query source (group or dictionary)")
        }
        static var newWindow: String {
            NSLocalizedString("shortcuts.newWindow", value: "New Window", comment: "Keyboard shortcut: open new window")
        }
        static var dismiss: String {
            NSLocalizedString("shortcuts.dismiss", value: "Dismiss", comment: "Keyboard shortcut: dismiss modal or cancel search")
        }

        // MARK: Utilities Category

        static var downloadPresets: String {
            NSLocalizedString("shortcuts.downloadPresets", value: "Download Presets", comment: "Keyboard shortcut: download preset dictionaries")
        }
        static var openSettings: String {
            NSLocalizedString("shortcuts.openSettings", value: "Open Settings", comment: "Keyboard shortcut: open system settings")
        }
    }

    // MARK: - Action Extension

    enum ActionExtension {
        /// No definitions found message with word and dict count. Use with String(format:, word, dictCount).
        static var noResults: String {
            NSLocalizedString("actionExtension.noResults", value: "No definitions found for \u{201C}%1$@\u{201D}\nin your top %2$d dictionaries.", comment: "Action Extension: no results (%1$@ = word, %2$d = number of dictionaries searched)")
        }
        /// Loading message with word and dictionary name. Use with String(format:, word, dictName).
        static var loadingWithName: String {
            NSLocalizedString("actionExtension.loadingWithName", value: "Looking up \u{201C}%1$@\u{201D} in\n\u{201C}%2$@\u{201D}", comment: "Action Extension: loading state (%1$@ = word, %2$@ = dictionary display name)")
        }
        static var loading: String {
            NSLocalizedString("actionExtension.loading", value: "Loading dictionaries\u{2026}", comment: "Action Extension: loading dictionaries state")
        }
        static var noDictionaries: String {
            NSLocalizedString("actionExtension.noDictionaries", value: "No dictionaries available", comment: "Action Extension: no dictionaries imported in the app")
        }
        /// Prompt to look up the word in the full app.
        static var lookItUpInApp: String {
            NSLocalizedString("actionExtension.lookItUpInApp", value: "Look it up in app", comment: "Action Extension: filled button to open main app when word not found")
        }
        /// Prompt to set up dictionaries in the main app.
        static var setupDictionaries: String {
            NSLocalizedString("actionExtension.setupDictionaries", value: "Setup your dictionaries", comment: "Action Extension: filled button to open main app when no dictionaries are available")
        }
        /// Alert title for confirming navigation to an entry link in the main app.
        static var browseEntryTitle: String {
            NSLocalizedString("actionExtension.browseEntryTitle", value: "Browse \u{201C}%@\u{201D} in the app?", comment: "Action Extension: alert title for entry link (%@ = target word)")
        }
        /// Alert message showing the dictionary name for entry link confirmation.
        static var browseEntryMessage: String {
            NSLocalizedString("actionExtension.browseEntryMessage", value: "Go to OpenMDict and view its full definition in \u{201C}%@\u{201D}.", comment: "Action Extension: alert message for entry link (%@ = dictionary display name)")
        }
        /// Alert button to open the entry in the main app.
        static var openInApp: String {
            NSLocalizedString("actionExtension.openInApp", value: "Proceed", comment: "Action Extension: alert button to open entry link in the main app")
        }
    }

    // MARK: - Sync Mode Chooser

    enum SyncChooser {
        /// Screen title
        static var title: String {
            NSLocalizedString("syncChooser.title", value: "Sync with iCloud", comment: "Sync chooser: screen title")
        }
        /// Description text below the title
        static var description: String {
            NSLocalizedString("syncChooser.description", value: "Sync your dictionaries, groups, bookmarks, and lookup history across all your devices.", comment: "Sync chooser: description text")
        }
        /// Shown while checking iCloud availability
        static var checkingICloud: String {
            NSLocalizedString("syncChooser.checkingICloud", value: "Checking iCloud\u{2026}", comment: "Sync chooser: loading state while checking iCloud")
        }
        /// CTA button when iCloud has existing data
        static var restoreFromICloud: String {
            NSLocalizedString("syncChooser.restoreFromICloud", value: "Restore from iCloud", comment: "Sync chooser: button to restore data from iCloud")
        }
        /// CTA button when iCloud is empty
        static var useICloudSync: String {
            NSLocalizedString("syncChooser.useICloudSync", value: "Use iCloud Sync", comment: "Sync chooser: button to enable iCloud sync (no existing data)")
        }
        /// Button to retry iCloud check after error
        static var retry: String {
            NSLocalizedString("syncChooser.retry", value: "Retry", comment: "Sync chooser: retry button after error")
        }
        /// CTA2: skip iCloud
        static var dontUseICloud: String {
            NSLocalizedString("syncChooser.dontUseICloud", value: "Don\u{2019}t Use iCloud", comment: "Sync chooser: button to skip iCloud sync")
        }
        /// Error title: no network (replaces main title)
        static var errorNoNetworkTitle: String {
            NSLocalizedString("syncChooser.errorNoNetworkTitle", value: "No Network", comment: "Sync chooser: title shown when no network is available")
        }
        /// Error title: iCloud not available (replaces main title)
        static var errorICloudNotAvailableTitle: String {
            NSLocalizedString("syncChooser.errorICloudNotAvailableTitle", value: "iCloud Not Available", comment: "Sync chooser: title shown when iCloud is not available")
        }
        /// Error reason: no network
        static var errorNoNetwork: String {
            NSLocalizedString("syncChooser.errorNoNetwork", value: "Check your internet connection and try again.", comment: "Sync chooser: reason text when no network is available")
        }
        /// Error reason: iCloud not available (covers both "not signed in" and "app toggle off")
        static var errorNotSignedIn: String {
            NSLocalizedString("syncChooser.errorNotSignedIn", value: "Make sure you are signed in to iCloud and that OpenMDict is enabled in iCloud settings.", comment: "Sync chooser: reason text when iCloud account is not available")
        }
        /// Error reason: iCloud restricted (e.g. MDM)
        static var errorRestricted: String {
            NSLocalizedString("syncChooser.errorRestricted", value: "iCloud access is restricted on this device.", comment: "Sync chooser: reason text when iCloud is restricted by MDM or parental controls")
        }
        /// Error reason: iCloud temporarily unavailable
        static var errorTemporarilyUnavailable: String {
            NSLocalizedString("syncChooser.errorTemporarilyUnavailable", value: "iCloud is temporarily unavailable. Please try again later.", comment: "Sync chooser: reason text when iCloud is temporarily unavailable")
        }
        /// Error reason: unknown
        static var errorUnknown: String {
            NSLocalizedString("syncChooser.errorUnknown", value: "Unable to determine iCloud availability.", comment: "Sync chooser: reason text when iCloud check fails for unknown reason")
        }
        /// Description when iCloud has existing data: "Your iCloud contains %@. ..."
        static func descriptionWithData(_ inventory: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncChooser.descriptionWithData", value: "Your iCloud contains %@. They will be synced to this device.", comment: "Sync chooser: description when iCloud has existing data. %@ = inventory list e.g. '3 dictionaries, 2 groups, and 5 bookmarks'"),
                inventory
            )
        }
        /// Summary fragment: N dictionaries
        static func summaryDictionaries(_ count: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncChooser.summaryDictionaries", value: "%d dictionaries", comment: "Sync chooser: number of dictionaries found in iCloud"),
                count
            )
        }
        /// Summary fragment: N groups
        static func summaryGroups(_ count: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncChooser.summaryGroups", value: "%d groups", comment: "Sync chooser: number of groups found in iCloud"),
                count
            )
        }
        /// Summary fragment: N bookmarks
        static func summaryBookmarks(_ count: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncChooser.summaryBookmarks", value: "%d bookmarks", comment: "Sync chooser: number of bookmarks found in iCloud"),
                count
            )
        }
        /// Alert title for offline choice confirmation
        static var offlineAlertTitle: String {
            NSLocalizedString("syncChooser.offlineAlertTitle", value: "Use Without iCloud?", comment: "Sync chooser: alert title confirming offline mode")
        }
        /// Alert message for offline choice confirmation
        static var offlineAlertMessage: String {
            NSLocalizedString("syncChooser.offlineAlertMessage", value: "Your dictionaries and data will be stored locally only. They will not sync to your other devices and cannot be recovered if the app is deleted.", comment: "Sync chooser: alert message explaining consequences of offline mode")
        }
        /// Alert destructive button for offline choice
        static var confirmOffline: String {
            NSLocalizedString("syncChooser.confirmOffline", value: "Continue Without iCloud", comment: "Sync chooser: destructive button confirming offline mode")
        }
    }

    // MARK: - Cloud Sync Progress

    enum SyncProgress {
        /// Message below the icon
        static var syncingMessage: String {
            NSLocalizedString("syncProgress.syncingMessage", value: "Syncing your data from iCloud to this device\u{2026}", comment: "Cloud sync progress: message below icon")
        }
        /// Category title: dictionaries
        static var categoryDictionaries: String {
            NSLocalizedString("syncProgress.categoryDictionaries", value: "Your dictionaries", comment: "Cloud sync progress: dictionaries category title")
        }
        /// Category title: groups
        static var categoryGroups: String {
            NSLocalizedString("syncProgress.categoryGroups", value: "Your groups", comment: "Cloud sync progress: groups category title")
        }
        /// Category title: bookmarks
        static var categoryBookmarks: String {
            NSLocalizedString("syncProgress.categoryBookmarks", value: "Your bookmarks", comment: "Cloud sync progress: bookmarks category title")
        }
        /// Subtitle: "X of Y synced"
        static func progressFormat(current: Int, total: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncProgress.progressFormat", value: "%1$d of %2$d synced", comment: "Cloud sync progress: X of Y synced"),
                current, total
            )
        }
        /// Subtitle when a category is fully synced
        static var progressComplete: String {
            NSLocalizedString("syncProgress.progressComplete", value: "Synced", comment: "Cloud sync progress: category fully synced")
        }
        /// Message when all categories are synced
        static var completeMessage: String {
            NSLocalizedString("syncProgress.completeMessage", value: "All data has been synced to this device.", comment: "Cloud sync progress: completion message")
        }
        /// Footer button: done
        static var done: String {
            NSLocalizedString("syncProgress.done", value: "Done", comment: "Cloud sync progress: done button")
        }
        /// Footer button: syncing (disabled state)
        static var syncing: String {
            NSLocalizedString("syncProgress.syncing", value: "Syncing\u{2026}", comment: "Cloud sync progress: syncing button (disabled)")
        }
    }

    // MARK: - Sidebar Sync Status

    enum SyncStatus {
        // -- Per-dictionary statuses --

        /// Alert title when dictionary is synced
        static var syncedTitle: String {
            NSLocalizedString("syncStatus.synced.title", value: "Synced", comment: "Sidebar sync status alert: synced title")
        }
        /// Alert message when dictionary is synced — includes dict name
        static func syncedDictMessage(name: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncStatus.synced.dictMessage", value: "Dictionary \u{201C}%@\u{201D} has been synced to your iCloud.", comment: "Sidebar sync status alert: dictionary synced message. %@ = dictionary name"),
                name
            )
        }
        /// Alert message when group is synced — includes group name
        static func syncedGroupMessage(name: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncStatus.synced.groupMessage", value: "Group \u{201C}%@\u{201D} has been synced to your iCloud.", comment: "Sidebar sync status alert: group synced message. %@ = group name"),
                name
            )
        }
        /// Alert title when dictionary is pending upload
        static var syncingTitle: String {
            NSLocalizedString("syncStatus.syncing.title", value: "Syncing", comment: "Sidebar sync status alert: syncing title")
        }
        /// Alert message when dictionary is pending upload — includes dict name
        static func syncingMessage(name: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncStatus.syncing.message", value: "\u{201C}%@\u{201D} is waiting to be synced to your iCloud.", comment: "Sidebar sync status alert: syncing message. %@ = dictionary name"),
                name
            )
        }
        /// Alert title when dictionary is too large
        static var cannotSyncTitle: String {
            NSLocalizedString("syncStatus.cannotSync.title", value: "Cannot Sync", comment: "Sidebar sync status alert: cannot sync title")
        }
        /// Alert message when dictionary is too large — includes dict name and size
        static func cannotSyncTooLargeMessage(name: String, size: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncStatus.cannotSync.tooLargeMessage", value: "\u{201C}%1$@\u{201D} (%2$@) exceeds the current sync size limit (500 MB) and cannot be synced to iCloud. It is stored locally on this device only.", comment: "Sidebar sync status alert: too large message. %1$@ = dictionary name, %2$@ = file size"),
                name, size
            )
        }
        /// Alert title when dictionary sync failed
        static var syncErrorTitle: String {
            NSLocalizedString("syncStatus.error.title", value: "Sync Error", comment: "Sidebar sync status alert: error title")
        }
        /// Alert message when dictionary sync failed — includes dict name
        static func syncErrorMessage(name: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncStatus.error.message", value: "\u{201C}%@\u{201D} could not be synced to your iCloud. It will be retried automatically.", comment: "Sidebar sync status alert: error message. %@ = dictionary name"),
                name
            )
        }

        // -- Section-level iCloud account status --

        /// Alert title when iCloud is healthy (all synced)
        static var iCloudHealthyTitle: String {
            NSLocalizedString("syncStatus.iCloudHealthy.title", value: "iCloud Sync Active", comment: "Sidebar sync status alert: iCloud healthy title")
        }
        /// Alert message when iCloud is healthy (all dicts synced) — "All Dictionaries" section
        static var iCloudHealthyMessage: String {
            NSLocalizedString("syncStatus.iCloudHealthy.message", value: "All dictionaries are synced to iCloud.", comment: "Sidebar sync status alert: iCloud healthy message — all synced")
        }
        /// Alert message when iCloud is healthy — "My Groups" section, has groups
        static var iCloudGroupsHealthyMessage: String {
            NSLocalizedString("syncStatus.iCloudGroupsHealthy.message", value: "All your groups are synced to iCloud.", comment: "Sidebar sync status alert: iCloud healthy message for My Groups section — all groups synced")
        }
        /// Alert message when "My Groups" section is empty
        static var iCloudNoGroupsMessage: String {
            NSLocalizedString("syncStatus.iCloudNoGroups.message", value: "You haven't added any dictionary groups yet.", comment: "Sidebar sync status alert: My Groups section is empty — no groups to sync")
        }
        /// Alert title when iCloud is syncing
        static var iCloudSyncingTitle: String {
            NSLocalizedString("syncStatus.iCloudSyncing.title", value: "Syncing", comment: "Sidebar sync status alert: iCloud syncing title")
        }
        /// Alert message when iCloud is syncing
        static var iCloudSyncingMessage: String {
            NSLocalizedString("syncStatus.iCloudSyncing.message", value: "Your data is being synced to iCloud.", comment: "Sidebar sync status alert: iCloud syncing message — in progress")
        }
        /// Alert title when iCloud has issues
        static var iCloudIssueTitle: String {
            NSLocalizedString("syncStatus.iCloudIssue.title", value: "iCloud Sync Unavailable", comment: "Sidebar sync status alert: iCloud issue title")
        }
        /// Alert message when iCloud has issues
        static var iCloudIssueMessage: String {
            NSLocalizedString("syncStatus.iCloudIssue.message", value: "iCloud sync is currently unavailable. Please check your iCloud settings and network connection.", comment: "Sidebar sync status alert: iCloud issue message")
        }
    }

    // MARK: - Tab Bar (Compact Layout)

    enum TabBar {
        static var lookup: String {
            NSLocalizedString("tabBar.lookup", value: "Lookup", comment: "Tab bar item: word lookup / search")
        }
        static var bookmarks: String {
            NSLocalizedString("tabBar.bookmarks", value: "Bookmarks", comment: "Tab bar item: bookmarks")
        }
        static var history: String {
            NSLocalizedString("tabBar.history", value: "History", comment: "Tab bar item: lookup history")
        }
        static var management: String {
            NSLocalizedString("tabBar.management", value: "Management", comment: "Tab bar item: dictionary management")
        }
    }

    // MARK: - iCloud Troubleshooting

    enum Troubleshoot {
        static var title: String {
            NSLocalizedString("troubleshoot.title", value: "iCloud Troubleshooting", comment: "Title: iCloud troubleshooting screen")
        }

        // MARK: Section headers
        static var sectionStatus: String {
            NSLocalizedString("troubleshoot.section.status", value: "Current Status", comment: "Section header: iCloud status")
        }
        static var sectionCloudData: String {
            NSLocalizedString("troubleshoot.section.cloudData", value: "Data Stored on iCloud", comment: "Section header: cloud data counts")
        }
        static var dangerZone: String {
            NSLocalizedString("troubleshoot.dangerZone", value: "Danger Zone", comment: "Section header: destructive iCloud actions")
        }

        // MARK: Status
        static var syncStatusTitle: String {
            NSLocalizedString("troubleshoot.syncStatus.title", value: "iCloud Sync", comment: "Cell title: iCloud sync toggle (non-interactive)")
        }
        static var syncStatusSubtitleEnabled: String {
            NSLocalizedString("troubleshoot.syncStatus.subtitle.enabled", value: "Your app data on this device is synced.", comment: "Short subtitle when iCloud sync is on")
        }
        static var syncStatusSubtitleDisabled: String {
            NSLocalizedString("troubleshoot.syncStatus.subtitle.disabled", value: "Your app data on this device is NOT synced.", comment: "Short subtitle when iCloud sync is off")
        }
        static var statusFooterEnabled: String {
            NSLocalizedString("troubleshoot.status.footer.enabled", value: "To change your sync mode, use the reset option below or reinstall the app.", comment: "Section footer: how to change sync mode when enabled")
        }
        static var statusFooterDisabled: String {
            NSLocalizedString("troubleshoot.status.footer.disabled", value: "To enable iCloud sync, use the reset option below or reinstall the app.", comment: "Section footer: how to enable sync when disabled")
        }

        // MARK: Cloud data counts
        static func dictCount(_ n: Int) -> String {
            String(format: NSLocalizedString("troubleshoot.count.dict", value: "%d Dictionaries", comment: "Cell: number of synced dictionaries"), n)
        }
        static func groupCount(_ n: Int) -> String {
            String(format: NSLocalizedString("troubleshoot.count.group", value: "%d Groups", comment: "Cell: number of synced groups"), n)
        }
        static func bookmarkCountLabel(_ n: Int) -> String {
            String(format: NSLocalizedString("troubleshoot.count.bookmark", value: "%d Bookmarks", comment: "Cell: number of synced bookmarks"), n)
        }
        static func historyCount(_ n: Int) -> String {
            String(format: NSLocalizedString("troubleshoot.count.history", value: "%d Lookup History", comment: "Cell: number of synced lookup history entries"), n)
        }

        // MARK: Danger Zone
        static var dangerZoneFooter: String {
            NSLocalizedString("troubleshoot.dangerZone.footer", value: "Use this as a last resort if your data is corrupted, tampered with, or the app malfunctions beyond basic troubleshooting.", comment: "Danger zone footer: explains when to use reset")
        }

        // MARK: Danger Zone — iCloud
        static var clearCloudTitle: String {
            NSLocalizedString("troubleshoot.clearCloud.title", value: "Clear iCloud Data and Reset App", comment: "Button: nuclear reset — delete all synced data and reset app")
        }
        static var clearCloudDescription: String {
            NSLocalizedString("troubleshoot.clearCloud.description", value: "Deletes ALL your synced data on iCloud, as listed above.", comment: "Subtitle for the nuclear reset button")
        }

        // MARK: Danger Zone — Local
        static var clearLocalTitle: String {
            NSLocalizedString("troubleshoot.clearLocal.title", value: "Clear Local Data and Reset App", comment: "Button: local reset — delete all local data and reset app")
        }
        static var clearLocalDescription: String {
            NSLocalizedString("troubleshoot.clearLocal.description", value: "Deletes ALL your local data on this device alone.", comment: "Subtitle for the local reset button")
        }

        // MARK: Alert 1 — iCloud explain impact
        static var confirm1Title: String {
            NSLocalizedString("troubleshoot.confirm1.title", value: "Clear ALL iCloud Data?", comment: "Alert 1 title: first confirmation for nuclear reset")
        }
        static var confirm1Message: String {
            NSLocalizedString("troubleshoot.confirm1.message", value: "This will permanently delete ALL synced bookmarks, history, groups, and dictionary files from iCloud.\n\nThis app on ALL other devices using this iCloud account will also be reset.", comment: "Alert 1 message: first confirmation for nuclear reset")
        }
        static var confirm1Proceed: String {
            NSLocalizedString("troubleshoot.confirm1.proceed", value: "Proceed", comment: "Alert 1 destructive button: proceed to final confirmation")
        }

        // MARK: Alert 2 — final confirmation (swapped buttons)
        static var confirm2Title: String {
            NSLocalizedString("troubleshoot.confirm2.title", value: "ARE YOU SURE YOU WANT TO CLEAR ALL ICLOUD DATA FOR THIS APP?", comment: "Alert 2 title: final confirmation, all caps")
        }
        static var confirm2Message: String {
            NSLocalizedString("troubleshoot.confirm2.message", value: "THIS CANNOT BE UNDONE!\nYou will need to set up this app again and import your dictionaries.", comment: "Alert 2 message: final warning, partially caps")
        }
        static var confirm2Abort: String {
            NSLocalizedString("troubleshoot.confirm2.abort", value: "Abort", comment: "Alert 2 cancel button: abort the reset")
        }
        static var confirm2Confirm: String {
            NSLocalizedString("troubleshoot.confirm2.confirm", value: "Confirm", comment: "Alert 2 destructive button: confirm the nuclear reset")
        }

        // MARK: Local reset alerts (reuses confirm1Proceed, confirm2Abort, confirm2Confirm)
        static var localConfirm1Title: String {
            NSLocalizedString("troubleshoot.localConfirm1.title", value: "Clear ALL Local Data?", comment: "Alert 1 title: local reset confirmation")
        }
        static var localConfirm1Message: String {
            NSLocalizedString("troubleshoot.localConfirm1.message", value: "This will permanently delete all dictionaries, bookmarks, history, and groups on this device.", comment: "Alert 1 message: local reset confirmation")
        }
        static var localConfirm2Title: String {
            NSLocalizedString("troubleshoot.localConfirm2.title", value: "ARE YOU SURE YOU WANT TO CLEAR ALL LOCAL DATA?", comment: "Alert 2 title: local reset final confirmation, all caps")
        }
        static var localConfirm2Message: String {
            NSLocalizedString("troubleshoot.localConfirm2.message", value: "THIS CANNOT BE UNDONE!\nYou will need to set up this app again and import your dictionaries.", comment: "Alert 2 message: local reset final warning")
        }

        // MARK: Progress
        static var resettingTitle: String {
            NSLocalizedString("troubleshoot.resetting.title", value: "Resetting…", comment: "Progress alert title during nuclear reset")
        }
        static var starting: String {
            NSLocalizedString("troubleshoot.progress.starting", value: "Preparing…", comment: "Progress: starting the reset")
        }
        static var deletingCloudData: String {
            NSLocalizedString("troubleshoot.progress.deletingCloud", value: "Deleting cloud data…", comment: "Progress: deleting CloudKit data")
        }
        static var deletingLocalData: String {
            NSLocalizedString("troubleshoot.progress.deletingLocal", value: "Deleting local data…", comment: "Progress: deleting local files")
        }
        static var recreatingDatabase: String {
            NSLocalizedString("troubleshoot.progress.recreating", value: "Rebuilding database…", comment: "Progress: recreating CoreData container")
        }

        // MARK: Error
        static var resetFailed: String {
            NSLocalizedString("troubleshoot.resetFailed", value: "Reset Failed", comment: "Alert title: nuclear reset failed")
        }
        static var resetFailedMessage: String {
            NSLocalizedString("troubleshoot.resetFailed.message", value: "Could not delete cloud data. Your local data has not been modified. Please check your network connection and try again.", comment: "Alert message: nuclear reset failed")
        }
    }
}
