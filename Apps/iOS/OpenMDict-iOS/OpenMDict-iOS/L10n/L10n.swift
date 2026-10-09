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
            NSLocalizedString("welcome.feature.extensions.title", value: "Pop-up Lookup & Jump Search", comment: "Feature card title for Action Extension + jump search")
        }
        static var extensionsBody: String {
            NSLocalizedString("welcome.feature.extensions.body", value: "Look up words from any app in a pop-up, then keep jump-searching unfamiliar terms within definitions until every word is clear.", comment: "Feature card body for Action Extension + jump search")
        }
        static var darkEnhanceTitle: String {
            NSLocalizedString("welcome.feature.darkEnhance.title", value: "Dark Enhancements for Imported Dicts", comment: "Feature card title for enhance dark mode")
        }
        static var darkEnhanceBody: String {
            NSLocalizedString("welcome.feature.darkEnhance.body", value: "Enhance third-party dictionaries\u{2019} readability in dark appearance, with adjustable brightness for each dictionary.", comment: "Feature card body for enhance dark mode")
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

        // Language group header accessory
        static func selectedCount(_ selected: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("picker.selectedCount", value: "%d / %d selected", comment: "Language group header: number of selected dictionaries out of total. %d = selected count, %d = total count"), selected, total)
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
        /// M14. Sidebar / Management entry cell — opens the AI Coach mode chooser.
        static var aiCoach: String {
            NSLocalizedString("sidebar.aiCoach", value: "AI Coach", comment: "Sidebar management action: opens the AI Coach mode chooser")
        }
    }

    // MARK: - AI Coach (M14)

    enum AICoach {
        static var title: String {
            NSLocalizedString("aiCoach.title", value: "AI Coach", comment: "AI Coach: nav bar title for chooser")
        }

        // MARK: Triage (availability states)

        enum Triage {
            static var deviceTitle: String {
                NSLocalizedString("aiCoach.triage.deviceTitle", value: "Device Not Supported", comment: "Triage: device lacks Apple Intelligence hardware")
            }
            /// Device-not-eligible explanation, sharpened with the actual
            /// marketing chip name from `DeviceChipInfo` when available (e.g.
            /// "Apple A13 Bionic") so the user understands *why their specific
            /// device* is excluded, not just an abstract requirement. `chip`
            /// is nil on the simulator / when the sysctl is sandboxed, in
            /// which case the generic variant (no chip name) is used.
            static func deviceMessage(chip: String?) -> String {
                if let chip, !chip.isEmpty {
                    return String(format: NSLocalizedString("aiCoach.triage.deviceMessage", value: "This device's chip (%@) doesn't support Apple Intelligence. AI Coach needs an iPhone 15 Pro / 16 or newer, or an iPad with an M-series chip.", comment: "Triage: device not eligible. Arg = marketing chip name from DeviceChipInfo, e.g. 'Apple A13 Bionic'."), chip)
                }
                return NSLocalizedString("aiCoach.triage.deviceMessage.generic", value: "This device doesn't support Apple Intelligence. AI Coach needs an iPhone 15 Pro / 16 or newer, or an iPad with an M-series chip.", comment: "Triage: device not eligible, generic fallback used when the chip name is unavailable (e.g. simulator).")
            }
            static var learnMore: String {
                NSLocalizedString("aiCoach.triage.learnMore", value: "Learn More", comment: "Triage: button to open Apple Support page")
            }
            static var notEnabledTitle: String {
                NSLocalizedString("aiCoach.triage.notEnabledTitle", value: "Apple Intelligence Not Enabled", comment: "Triage: AI feature not turned on")
            }
            static var notEnabledMessage: String {
                NSLocalizedString("aiCoach.triage.notEnabledMessage", value: "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri, then come back.", comment: "Triage: how to enable AI")
            }
            static var downloadingTitle: String {
                NSLocalizedString("aiCoach.triage.downloadingTitle", value: "Setting Up Apple Intelligence", comment: "Triage: model still downloading")
            }
            static var downloadingMessage: String {
                NSLocalizedString("aiCoach.triage.downloadingMessage", value: "Please wait for Apple Intelligence to finish downloading, then come back.", comment: "Triage: wait for model download")
            }
            static var unknownTitle: String {
                NSLocalizedString("aiCoach.triage.unknownTitle", value: "AI Unavailable", comment: "Triage: unknown unavailability reason")
            }
            static var unknownMessage: String {
                NSLocalizedString("aiCoach.triage.unknownMessage", value: "The on-device language model is unavailable. Please check your device settings.", comment: "Triage: generic fallback message")
            }
            // MARK: Locale mismatch (unified — replaces the old separate
            // languageNotSupported / regionMismatch states)
            //
            // The new framing centers on what the user just *touched* (their
            // app/device language) given a fixed prerequisite (device region).
            // The screen presents up to two solutions:
            //   1. Change app language (via per-app language override — low
            //      impact, doesn't touch device-wide setting)
            //   2. Change device region (high impact, side-effect warning
            //      attached as info row)
            // Solution headers are dynamically numbered based on which ones
            // are visible (only Solution 1 visible → renumber as "1", etc.).

            static var localeMismatchTitle: String {
                NSLocalizedString("aiCoach.triage.localeMismatchTitle", value: "AI Coach Not Available", comment: "Triage: title for the unified locale-mismatch screen — covers both the diaspora region-mismatch case and the entirely-unsupported-language case")
            }
            /// Frames the problem as: given device region X (the prerequisite
            /// the user rarely touches), AI Coach doesn't support their
            /// chosen app language Y (the variable they just touched).
            /// Args: %1$@ = localized region name, %2$@ = localized language name.
            static func localeMismatchSubtitle(region: String, language: String) -> String {
                String(format: NSLocalizedString("aiCoach.triage.localeMismatchSubtitle", value: "When your device region is %1$@, Apple Intelligence doesn't support your current app language (%2$@).", comment: "Triage: subtitle framing the issue with region as prerequisite and language as variable. Arg 1 = localized region name, Arg 2 = localized language name."), region, language)
            }

            /// Solution section header — formatted with the dynamic ordinal
            /// number ("1" or "2" depending on which other solutions are
            /// visible) and the descriptor (changeAppLanguage / changeRegion).
            /// Example: "Solution 1: Change App Language".
            /// Args: %1$d = ordinal, %2$@ = descriptor.
            static func solutionHeader(number: Int, descriptor: String) -> String {
                String(format: NSLocalizedString("aiCoach.triage.solutionHeaderFormat", value: "Solution %1$d: %2$@", comment: "Triage: format for solution-section header. Arg 1 = ordinal number, Arg 2 = solution descriptor (changeAppLanguage / changeRegion)."), number, descriptor)
            }
            static var solutionChangeAppLanguage: String {
                NSLocalizedString("aiCoach.triage.solutionChangeAppLanguage", value: "Change App Language", comment: "Triage: descriptor for Solution 1 — this is the per-app language override, NOT a device-wide language change. The wording should make clear it only affects this app.")
            }
            static var solutionChangeRegion: String {
                NSLocalizedString("aiCoach.triage.solutionChangeRegion", value: "Change Region", comment: "Triage: descriptor for Solution 2 — this is the device-wide region change.")
            }

            // MARK: Solution 1 — change app language (per-app override)

            /// Step 1 of Solution 1: navigation path to OpenMDict's settings
            /// page. The cell is tappable (chevron + tap gesture) and opens
            /// the page directly via UIApplication.openSettingsURLString.
            /// Arg 1 = app display name (e.g. "OpenMDict").
            static func solutionLanguageStep1(appName: String) -> String {
                String(format: NSLocalizedString("aiCoach.triage.solutionLanguageStep1Format", value: "Settings \u{2192} Apps \u{2192} %@", comment: "Triage: Solution 1 step 1 — navigation path to the app's Settings page. Arg 1 = app display name. The path uses iOS 18+ Settings layout which has a unified 'Apps' subgroup; AI Coach is iOS 26+ only so older layouts don't apply."), appName)
            }
            static var solutionLanguageStep2: String {
                NSLocalizedString("aiCoach.triage.solutionLanguageStep2", value: "Tap Preferred Language and pick a supported one.", comment: "Triage: Solution 1 step 2 — the per-app language picker is system-provided and labeled 'Preferred Language' in iOS")
            }

            // MARK: Solution 2 — change device region

            /// Step 1 of Solution 2: navigation path to Language & Region.
            /// Read-only (no deep-link API exists for this pane).
            static var solutionRegionStep1: String {
                NSLocalizedString("aiCoach.triage.solutionRegionStep1", value: "Settings \u{2192} General \u{2192} Language & Region", comment: "Triage: Solution 2 step 1 — navigation path to the Language & Region screen")
            }
            static var solutionRegionStep2: String {
                NSLocalizedString("aiCoach.triage.solutionRegionStep2", value: "Tap Region and pick a supported region.", comment: "Triage: Solution 2 step 2 — the supported-region list renders separately as the cell's subtitle (computed at runtime).")
            }
            static var solutionRegionWarning: String {
                NSLocalizedString("aiCoach.triage.solutionRegionWarning", value: "Changing Region affects calendars, currency, and App Store defaults.", comment: "Triage: Solution 2 warning info row — the side effects of changing device region. Solution 1 (per-app language) avoids these.")
            }

            // MARK: Fallback — neither solution applicable (e.g. ru-RU)

            static var fallbackMessage: String {
                NSLocalizedString("aiCoach.triage.fallbackMessage", value: "Apple Intelligence isn't available for your language and region combination. To use AI Coach, change your iPhone Language and Region in Settings to a supported combination.", comment: "Triage: fallback message when neither Solution 1 nor Solution 2 has any candidates (rare — e.g. ru-RU where neither Russian nor Russia is in Apple's supported list).")
            }
        }
        static var chooseMode: String {
            NSLocalizedString("aiCoach.chooseMode", value: "Choose a study mode", comment: "AI Coach: chooser action sheet message")
        }
        static var flashcard: String {
            NSLocalizedString("aiCoach.flashcard", value: "Flashcard", comment: "AI Coach: chooser option — flashcard mode")
        }
        static var wordTinder: String {
            NSLocalizedString("aiCoach.wordTinder", value: "Word Tinder", comment: "AI Coach: chooser option — word tinder mode")
        }
        static var wordTinderDesc: String {
            NSLocalizedString("aiCoach.wordTinderDesc", value: "Swipe to classify synonyms, antonyms, and look-alikes", comment: "AI Coach: word tinder mode description")
        }
        static var flashcardDesc: String {
            NSLocalizedString("aiCoach.flashcardDesc", value: "AI-generated flashcards from your bookmarks", comment: "AI Coach: flashcard mode description")
        }
        static var amongWurds: String {
            NSLocalizedString("aiCoach.amongWurds", value: "Among wUrdS", comment: "AI Coach: chooser option — morphology quiz mode")
        }
        static var amongWurdsDesc: String {
            NSLocalizedString("aiCoach.amongWurdsDesc", value: "Find imposter words hiding among true relatives", comment: "AI Coach: morphology quiz mode description")
        }
        static var morphemeMaury: String {
            NSLocalizedString("aiCoach.morphemeMaury", value: "Morpheme Maury", comment: "AI Coach: chooser option — Maury Show style morphology reveal")
        }
        static var morphemeMauryDesc: String {
            NSLocalizedString("aiCoach.morphemeMauryDesc", value: "Daytime-TV paternity showdown: is this word really in the family?", comment: "AI Coach: Morpheme Maury mode description")
        }
        static var phrasyFeud: String {
            NSLocalizedString("aiCoach.phrasyFeud", value: "Phrasy Feud", comment: "AI Coach: chooser option — Family Feud-style collocation quiz")
        }
        static var phrasyFeudDesc: String {
            NSLocalizedString("aiCoach.phrasyFeudDesc", value: "Game-show survey: name the words sharing a category", comment: "AI Coach: Phrasy Feud mode description")
        }
        static var openSettings: String {
            NSLocalizedString("aiCoach.openSettings", value: "Open OpenMDict Settings", comment: "AI Coach: button to open app settings")
        }

        // MARK: Flashcard

        enum Flashcard {
            static var title: String {
                NSLocalizedString("aiCoach.flashcard.title", value: "Flashcard", comment: "Flashcard: nav bar title (DEBUG-only mode)")
            }
            static var sectionDefinition: String {
                NSLocalizedString("aiCoach.flashcard.definition", value: "Definition", comment: "Flashcard: section title")
            }
            static var sectionExample: String {
                NSLocalizedString("aiCoach.flashcard.example", value: "Example", comment: "Flashcard: section title")
            }
            static var sectionMnemonic: String {
                NSLocalizedString("aiCoach.flashcard.mnemonic", value: "Mnemonic", comment: "Flashcard: section title")
            }
            static var sectionRelated: String {
                NSLocalizedString("aiCoach.flashcard.related", value: "Related words", comment: "Flashcard: section title")
            }
            static var reveal: String {
                NSLocalizedString("aiCoach.flashcard.reveal", value: "Reveal", comment: "Flashcard: reveal button")
            }
            static var again: String {
                NSLocalizedString("aiCoach.flashcard.again", value: "Again", comment: "Flashcard: rating button — need to review again")
            }
            static var good: String {
                NSLocalizedString("aiCoach.flashcard.good", value: "Good", comment: "Flashcard: rating button — understood")
            }
            static var easy: String {
                NSLocalizedString("aiCoach.flashcard.easy", value: "Easy", comment: "Flashcard: rating button — already knew")
            }
            static var nextCard: String {
                NSLocalizedString("aiCoach.flashcard.nextCard", value: "Next card →", comment: "Flashcard: next card button")
            }
            static func cardProgress(_ current: Int, _ total: Int) -> String {
                String(format: NSLocalizedString("aiCoach.flashcard.cardProgress", value: "Card %d of %d", comment: "Flashcard: progress header — Card 1 of 5"), current, total)
            }
            static var generating: String {
                NSLocalizedString("aiCoach.flashcard.generating", value: "Generating flashcard with on-device AI\u{2026}", comment: "Flashcard: loading status")
            }
            static var ready: String {
                NSLocalizedString("aiCoach.flashcard.ready", value: "Ready. Reveal when you want to check yourself.", comment: "Flashcard: generation complete status")
            }
            static var noContent: String {
                NSLocalizedString("aiCoach.flashcard.noContent", value: "Model returned no content.", comment: "Flashcard: empty generation result")
            }
            static var noCards: String {
                NSLocalizedString("aiCoach.flashcard.noCards", value: "Bookmark some English words first, then come back to try AI Coach. It reviews up to 5 of your most recent bookmarks.", comment: "Flashcard: empty state — no bookmarks")
            }
            static func allDone(_ count: Int) -> String {
                String(format: NSLocalizedString("aiCoach.flashcard.allDone", value: "That's all %d cards for this session.", comment: "Flashcard: all cards completed"), count)
            }
            static var notReady: String {
                NSLocalizedString("aiCoach.flashcard.notReady", value: "Not ready", comment: "Flashcard: header when AI not available")
            }
            /// Header label shown in the empty-state slot when the user has
            /// no bookmarks yet. The longer `noCards` message renders below.
            static var noCardsHeader: String {
                NSLocalizedString("aiCoach.flashcard.noCardsHeader", value: "No cards", comment: "Flashcard: short header above the empty-state message — the longer noCards copy appears below this")
            }
        }

        // MARK: Word Quiz

        enum Quiz {
            static var title: String {
                NSLocalizedString("aiCoach.quiz.title", value: "Word Quiz", comment: "Quiz: nav bar title")
            }
            static var titleShort: String {
                NSLocalizedString("aiCoach.quiz.titleShort", value: "Word Tinder", comment: "Quiz: compact nav bar title (next to icon)")
            }
            static var selectAnswer: String {
                NSLocalizedString("aiCoach.quiz.selectAnswer", value: "Select your answer", comment: "Quiz: candidate cell placeholder subtitle")
            }
            static func questionsToGo(_ count: Int) -> String {
                let fmt = count == 1
                    ? NSLocalizedString("aiCoach.quiz.questionsToGo.one", value: "%d question to go", comment: "Quiz: CTA — 1 question remaining")
                    : NSLocalizedString("aiCoach.quiz.questionsToGo.other", value: "%d questions to go", comment: "Quiz: CTA — N questions remaining")
                return String(format: fmt, count)
            }
            static var next: String {
                NSLocalizedString("aiCoach.quiz.next", value: "Next", comment: "Quiz: CTA after grading — start next quiz")
            }
            static var instruction: String {
                NSLocalizedString("aiCoach.quiz.instruction", value: "Classify each word's relationship:", comment: "Quiz: instruction label")
            }
            static func classifyInstruction(_ word: String) -> String {
                String(format: NSLocalizedString("aiCoach.quiz.classifyInstruction", value: "Please classify each word's relationship to \"%@\":", comment: "Quiz: header message below card — Args: quiz word"), word)
            }
            static var viewDefinitions: String {
                NSLocalizedString("aiCoach.quiz.viewDefinitions", value: "Tap on each word card to view its definition.", comment: "Quiz: header message after grading")
            }
            static func scoreMessage(_ correct: Int, _ total: Int) -> String {
                String(format: NSLocalizedString("aiCoach.quiz.scoreMessage", value: "You got %d out of %d correct.", comment: "Quiz: score alert message — Args: correct count, total count"), correct, total)
            }
            static var synonym: String {
                NSLocalizedString("aiCoach.quiz.synonym", value: "Synonym", comment: "Quiz: relationship option")
            }
            static var antonym: String {
                NSLocalizedString("aiCoach.quiz.antonym", value: "Antonym", comment: "Quiz: relationship option")
            }
            static var irrelevant: String {
                NSLocalizedString("aiCoach.quiz.irrelevant", value: "Irrelevant", comment: "Quiz: relationship option — not related")
            }
            static var checkAnswers: String {
                NSLocalizedString("aiCoach.quiz.checkAnswers", value: "Check Answers", comment: "Quiz: submit button")
            }
            static func score(_ correct: Int, _ total: Int) -> String {
                String(format: NSLocalizedString("aiCoach.quiz.score", value: "Score: %d / %d", comment: "Quiz: score display — Score: 7 / 9"), correct, total)
            }
            static var generating: String {
                NSLocalizedString("aiCoach.quiz.generating", value: "Generating quiz with on-device AI\u{2026}", comment: "Quiz: loading status")
            }
            // Word Tinder = dating-app parody. The loading copy mirrors
            // that frame: "matchmaker" for the AI, "dates" for the quiz,
            // "match / candidate / sparks" for the candidates being
            // evaluated. Replaces the previous generic "brewing your
            // quiz" / "picking words for you" boilerplate, which broke
            // the dating-app illusion the moment the loading state hit.
            static var generatingTitle: String {
                NSLocalizedString("aiCoach.quiz.generatingTitle", value: "Setting up your dates\u{2026}", comment: "Word Tinder: placeholder title during initial quiz generation — dating-set-up framing")
            }
            static var generatingMessage: String {
                NSLocalizedString("aiCoach.quiz.generatingMessage", value: "Our matchmaker is swiping through your bookmarks, looking for sparks.", comment: "Word Tinder: placeholder message during initial generation — matchmaker swipes through user's bookmarked words")
            }
            static var retryingTitle: String {
                NSLocalizedString("aiCoach.quiz.retryingTitle", value: "Looking for another match\u{2026}", comment: "Word Tinder: placeholder title during retry — dating-app 'next candidate' framing")
            }
            static var errorTitle: String {
                NSLocalizedString("aiCoach.quiz.errorTitle", value: "Something went wrong", comment: "Quiz: placeholder title on error")
            }
            static func retrying(_ attempt: Int, _ word: String) -> String {
                String(format: NSLocalizedString("aiCoach.quiz.retrying", value: "Vetting \"%@\" as your match\u{2026} (attempt %d)", comment: "Word Tinder: retry status mentioning the specific word — Args: word, attempt number. 'Vetting' carries the matchmaker-pre-screens-candidate vibe."), word, attempt + 1)
            }
            static func retryingGeneric(_ attempt: Int) -> String {
                String(format: NSLocalizedString("aiCoach.quiz.retryingGeneric", value: "Trying another match\u{2026} (attempt %d)", comment: "Word Tinder: retry status without specific word — Args: attempt number"), attempt + 1)
            }
            static func allRetriesFailed(_ error: String) -> String {
                String(format: NSLocalizedString("aiCoach.quiz.allRetriesFailed", value: "Could not generate a quiz after multiple attempts.\n%@", comment: "Quiz: all retries exhausted — Args: error description"), error)
            }
            static var tryAgain: String {
                NSLocalizedString("aiCoach.quiz.tryAgain", value: "Try Again", comment: "Quiz: CTA on error — retry from scratch")
            }
            static var completedTitle: String {
                NSLocalizedString("aiCoach.quiz.completedTitle", value: "You did it!", comment: "Quiz: all quizzes completed title")
            }
            static var completedMessage: String {
                NSLocalizedString("aiCoach.quiz.completedMessage", value: "You've gone through all your bookmarked words. Come back after adding more bookmarks for new challenges!", comment: "Quiz: all quizzes completed message")
            }
            static var noBookmarks: String {
                NSLocalizedString("aiCoach.quiz.noBookmarks", value: "Bookmark some English words first, then come back.", comment: "Quiz: empty state — no bookmarks")
            }
            static var noBookmarksTitle: String {
                NSLocalizedString("aiCoach.quiz.noBookmarksTitle", value: "No bookmarks yet", comment: "Quiz: empty state title — no English bookmarks")
            }
            static var noBookmarksMessage: String {
                NSLocalizedString("aiCoach.quiz.noBookmarksMessage", value: "Bookmark some English words first, then come back for a quiz.", comment: "Quiz: empty state message — no English bookmarks")
            }
            static var noCandidates: String {
                NSLocalizedString("aiCoach.quiz.noCandidates", value: "Couldn't verify any candidates in your dictionaries. Try bookmarking words from a monolingual English dictionary (like WordNet).", comment: "Quiz: no verified candidates")
            }

            // Grading result subtitles: "Actually, X is [a synonym]."
            static func correctResult(_ word: String, _ relationship: String) -> String {
                String(format: NSLocalizedString("aiCoach.quiz.correctResult", value: "Correct — \"%@\" is %@.", comment: "Quiz: grading — correct answer. Args: word, relationship"), word, relationship)
            }
            static func incorrectResult(_ word: String, _ relationship: String) -> String {
                String(format: NSLocalizedString("aiCoach.quiz.incorrectResult", value: "Actually, \"%@\" is %@.", comment: "Quiz: grading — incorrect answer. Args: word, relationship"), word, relationship)
            }
            static var aSynonym: String {
                NSLocalizedString("aiCoach.quiz.aSynonym", value: "a synonym", comment: "Quiz: relationship article form for subtitle")
            }
            static var anAntonym: String {
                NSLocalizedString("aiCoach.quiz.anAntonym", value: "an antonym", comment: "Quiz: relationship article form for subtitle")
            }
            static var aSimilarWord: String {
                NSLocalizedString("aiCoach.quiz.aSimilarWord", value: "a similar-looking but different word", comment: "Quiz: relationship article form for subtitle")
            }
            static var unrelated: String {
                NSLocalizedString("aiCoach.quiz.unrelated", value: "irrelevant", comment: "Quiz: relationship article form for subtitle")
            }
            /// Back-nav double-check alert — Word Tinder is a dating-app
            /// parody, so the copy leans into ghosting / soulmate /
            /// heartbreak metaphors instead of generic "leave quiz".
            /// Avoids re-using the "swipe" verb (already in the chooser
            /// description text) to keep variety; the romantic framing
            /// also gives both buttons emotional weight so the user
            /// actually pauses to consider.
            static var leaveTitle: String {
                NSLocalizedString("aiCoach.quiz.leaveTitle", value: "Heartbroken?", comment: "Word Tinder: back-nav alert title — dating-app heartbreak framing")
            }
            static var leaveMessage: String {
                NSLocalizedString("aiCoach.quiz.leaveMessage", value: "Your match is still in your queue, smiling, hoping for a yes. Walk away and you'll ghost them forever.", comment: "Word Tinder: back-nav alert body — leans into ghosting + waiting-match dating-app tropes")
            }
            static var ghostThem: String {
                NSLocalizedString("aiCoach.quiz.ghostThem", value: "Ghost Them", comment: "Word Tinder: confirm leaving mid-round — destructive action, plays on dating-app ghosting")
            }
            static var giveLoveChance: String {
                NSLocalizedString("aiCoach.quiz.giveLoveChance", value: "Give Love a Chance", comment: "Word Tinder: cancel leaving mid-round — wraps 'stay' in a romantic appeal so the user pauses")
            }
        }

        // MARK: Dismiss confirmation

        static var leaveTitle: String {
            NSLocalizedString("aiCoach.leave.title", value: "Leave Quiz?", comment: "AI Coach: dismiss confirmation alert title")
        }
        static var leaveMessage: String {
            NSLocalizedString("aiCoach.leave.message", value: "Your progress will be lost.", comment: "AI Coach: dismiss confirmation alert message")
        }
        static var leaveAction: String {
            NSLocalizedString("aiCoach.leave.action", value: "Leave", comment: "AI Coach: dismiss confirmation — destructive action")
        }
        static var stayAction: String {
            NSLocalizedString("aiCoach.leave.stay", value: "Stay", comment: "AI Coach: dismiss confirmation — cancel action")
        }

        // MARK: Availability / error messages

        static var deviceNotEligible: String {
            NSLocalizedString("aiCoach.error.deviceNotEligible", value: "This device does not support Apple Intelligence on-device language models. AI Coach requires an iPhone 15 Pro / iPhone 16 / Apple silicon iPad or Mac.", comment: "AI Coach: device not eligible error")
        }
        static var aiNotEnabled: String {
            NSLocalizedString("aiCoach.error.aiNotEnabled", value: "Apple Intelligence is not enabled on this device. Open Settings \u{2192} Apple Intelligence & Siri and turn on Apple Intelligence, then try again.", comment: "AI Coach: Apple Intelligence not enabled error")
        }
        static var modelNotReady: String {
            NSLocalizedString("aiCoach.error.modelNotReady", value: "The on-device language model is still downloading or warming up. Try again in a few minutes.", comment: "AI Coach: model not ready error")
        }
        static var contextTooLong: String {
            NSLocalizedString("aiCoach.error.contextTooLong", value: "The word and its dictionary definition together are too long for the on-device model (>4096 tokens). Try a shorter definition.", comment: "AI Coach: context window exceeded error")
        }
        static var guardrail: String {
            NSLocalizedString("aiCoach.error.guardrail", value: "The on-device model blocked this content (safety guardrail). Skip this word for now.", comment: "AI Coach: guardrail violation error")
        }
        static var assetsUnavailable: String {
            NSLocalizedString("aiCoach.error.assetsUnavailable", value: "The on-device language model assets aren't available yet. They may still be downloading \u{2014} try again in a few minutes.", comment: "AI Coach: assets unavailable error")
        }
        static var rateLimited: String {
            NSLocalizedString("aiCoach.error.rateLimited", value: "The on-device model is rate-limited right now. Wait a moment and try again.", comment: "AI Coach: rate limited error")
        }

        // MARK: Among wUrdS (morphology quiz)

        enum AmongWurds {
            static var title: String {
                NSLocalizedString("aiCoach.amongWurds.title", value: "Among wUrdS", comment: "Among wUrdS: nav bar title")
            }
            static func impostersAmongUs(_ count: Int) -> String {
                String(format: NSLocalizedString("aiCoach.amongWurds.impostersAmongUs", value: "There are %d imposters among us", comment: "Among wUrdS: imposter count banner"), count)
            }
            static var eject: String {
                NSLocalizedString("aiCoach.amongWurds.eject", value: "Eject", comment: "Among wUrdS: eject button")
            }
            static var rootLabel: String {
                NSLocalizedString("aiCoach.amongWurds.rootLabel", value: "Root", comment: "Among wUrdS: root morpheme label")
            }
            static var markSus: String {
                NSLocalizedString("aiCoach.amongWurds.markSus", value: "Tap words you think are imposters", comment: "Among wUrdS: instruction text")
            }
            static func scoreMessage(_ correct: Int, _ total: Int) -> String {
                String(format: NSLocalizedString("aiCoach.amongWurds.scoreMessage", value: "%d of %d correctly identified", comment: "Among wUrdS: score summary"), correct, total)
            }
            static var generatingTitle: String {
                NSLocalizedString("aiCoach.amongWurds.generatingTitle", value: "Assigning roles\u{2026}", comment: "Among wUrdS: loading placeholder title")
            }
            static var generatingMessage: String {
                NSLocalizedString("aiCoach.amongWurds.generatingMessage", value: "Analyzing word origins\u{2026}", comment: "Among wUrdS: loading placeholder message")
            }
            static func onboarded(_ count: Int) -> String {
                let noun = count == 1 ? "member" : "members"
                return "\(count) \(noun) onboarded"
            }
            static var next: String {
                NSLocalizedString("aiCoach.amongWurds.next", value: "Next", comment: "Among wUrdS: next quiz button")
            }
            static var tryAgain: String {
                NSLocalizedString("aiCoach.amongWurds.tryAgain", value: "Try Again", comment: "Among wUrdS: retry button")
            }
            static var errorTitle: String {
                NSLocalizedString("aiCoach.amongWurds.errorTitle", value: "Error", comment: "Among wUrdS: error placeholder title")
            }
            static var completedTitle: String {
                NSLocalizedString("aiCoach.amongWurds.completedTitle", value: "Mission Complete!", comment: "Among wUrdS: all quizzes done title")
            }
            static var completedMessage: String {
                NSLocalizedString("aiCoach.amongWurds.completedMessage", value: "All crew members verified.", comment: "Among wUrdS: all quizzes done message")
            }
            static var noBookmarksTitle: String {
                NSLocalizedString("aiCoach.amongWurds.noBookmarksTitle", value: "No Bookmarks", comment: "Among wUrdS: empty state title")
            }
            static var noBookmarksMessage: String {
                NSLocalizedString("aiCoach.amongWurds.noBookmarksMessage", value: "Bookmark some English words first, then come back to hunt imposters.", comment: "Among wUrdS: empty state message")
            }
            static var allRetriesFailed: String {
                NSLocalizedString("aiCoach.amongWurds.allRetriesFailed", value: "Could not generate a quiz for your bookmarks. Try adding more English words.", comment: "Among wUrdS: all quiz attempts failed")
            }
            static var victoryTitle: String {
                NSLocalizedString("aiCoach.amongWurds.victoryTitle", value: "\u{1F389} Victory", comment: "Among wUrdS: victory alert title")
            }
            static var victoryMessage: String {
                NSLocalizedString("aiCoach.amongWurds.victoryMessage", value: "All imposters have been ejected.", comment: "Among wUrdS: victory alert message")
            }
            static var defeatTitle: String {
                NSLocalizedString("aiCoach.amongWurds.defeatTitle", value: "Defeat", comment: "Among wUrdS: defeat alert title")
            }
            static var defeatMessage: String {
                NSLocalizedString("aiCoach.amongWurds.defeatMessage", value: "The crew has been eliminated.", comment: "Among wUrdS: defeat alert message")
            }
            /// In-game banner text shown in the reveal header (reuses the
            /// imposter-count label slot).
            static var victoryBanner: String {
                NSLocalizedString("aiCoach.amongWurds.victoryBanner", value: "Victory!", comment: "Among wUrdS: reveal banner when player wins")
            }
            /// First line of the defeat banner. Rendered red. The reason
            /// follows on a second line, rendered white.
            static var defeatBannerTitle: String {
                NSLocalizedString("aiCoach.amongWurds.defeatBannerTitle", value: "Defeat", comment: "Among wUrdS: defeat banner title (first line, red)")
            }
            /// Defeat reason: all crewmates are dead or ejected.
            static var defeatReasonAllDead: String {
                NSLocalizedString("aiCoach.amongWurds.defeatReasonAllDead", value: "the crew has been eliminated", comment: "Among wUrdS: defeat reason — zero crewmates alive")
            }
            /// Defeat reason: imposters reached parity — Among Us classic lose condition.
            static var defeatReasonNotEnough: String {
                NSLocalizedString("aiCoach.amongWurds.defeatReasonNotEnough", value: "not enough crewmates left alive", comment: "Among wUrdS: defeat reason — imposters reached parity")
            }
            static var verifyIdentities: String {
                NSLocalizedString("aiCoach.amongWurds.verifyIdentities", value: "Verify Identities", comment: "Among wUrdS: reveal button in endgame alert")
            }
            static var crewmateLabel: String {
                NSLocalizedString("aiCoach.amongWurds.crewmateLabel", value: "CREWMATE", comment: "Among wUrdS: revealed crewmate subtitle")
            }
            static var imposterLabel: String {
                NSLocalizedString("aiCoach.amongWurds.imposterLabel", value: "IMPOSTER", comment: "Among wUrdS: revealed imposter subtitle")
            }
            static var reactorMeltdown: String {
                NSLocalizedString("aiCoach.amongWurds.reactorMeltdown", value: "Reactor Meltdown!", comment: "Among wUrdS: loading failure — ship exploded, retry")
            }
            static var reassemblingCrew: String {
                NSLocalizedString("aiCoach.amongWurds.reassemblingCrew", value: "Reassembling crew\u{2026}", comment: "Among wUrdS: brief message after reactor meltdown before next attempt")
            }
            static func ejectLimitAlert(_ max: Int) -> String {
                String(format: NSLocalizedString("aiCoach.amongWurds.ejectLimitAlert", value: "You can only eject up to %d crew members at a time.", comment: "Among wUrdS: eject limit warning"), max)
            }
            /// All-caps variant for the in-game CTA button. Distinct from
            /// `eject` (Title Case "Eject" used in menus) because the CTA
            /// follows broadcast-style ALL CAPS — translators may choose
            /// whether casing applies in their script (CJK has no casing).
            static var ejectCTA: String {
                NSLocalizedString("aiCoach.amongWurds.ejectCTA", value: "EJECT", comment: "Among wUrdS: in-game eject CTA — broadcast-style ALL CAPS; non-Latin scripts can ignore casing")
            }
            /// Eject-result overlay text when the chosen crew member WAS an
            /// imposter. `%@` is the word. `\n` for a two-line layout.
            static func ejectedImposter(_ word: String) -> String {
                String(format: NSLocalizedString("aiCoach.amongWurds.ejectedImposter", value: "\"%@\"\nwas An Imposter!", comment: "Among wUrdS: eject overlay text when the player correctly ejected an imposter; %@ is the word"), word)
            }
            /// Eject-result overlay text when the chosen crew member was NOT
            /// an imposter (i.e. the player ejected a crewmate by mistake).
            static func ejectedCrewmate(_ word: String) -> String {
                String(format: NSLocalizedString("aiCoach.amongWurds.ejectedCrewmate", value: "\"%@\"\nwas not An Imposter\u{2026}", comment: "Among wUrdS: eject overlay text when the player ejected an innocent crewmate; %@ is the word"), word)
            }
            /// Back-nav double-check alert title — Among Us spaceship-eject
            /// metaphor (player abandoning the crew). The destructive action
            /// reuses the existing `eject` key.
            static var leaveTitle: String {
                NSLocalizedString("aiCoach.amongWurds.leaveTitle", value: "Eject from Ship?", comment: "Among wUrdS: back-nav alert title — Among Us spaceship metaphor")
            }
            static var leaveMessage: String {
                NSLocalizedString("aiCoach.amongWurds.leaveMessage", value: "Your crew's lives are still in danger \u{2014} imposters on the loose!", comment: "Among wUrdS: back-nav alert body — appeals to player's responsibility to the surviving crew")
            }
            /// Cancel-button label for the back-nav alert. Stays in-theme
            /// (player remains on the spaceship). Distinct from any
            /// existing `eject*` keys.
            static var stayAboard: String {
                NSLocalizedString("aiCoach.amongWurds.stayAboard", value: "Stay Aboard", comment: "Among wUrdS: cancel leaving mid-round — keeps the spaceship-crew metaphor")
            }
        }

        // MARK: Morpheme Maury

        enum Maury {
            static var title: String {
                NSLocalizedString("aiCoach.maury.title", value: "Morpheme Maury", comment: "Maury: nav bar title")
            }
            static func episodeIntro(_ target: String) -> String {
                String(format: NSLocalizedString("aiCoach.maury.episodeIntro", value: "Today on Morpheme Maury\u{2026} is \u{201C}%@\u{201D} really the root father?", comment: "Maury: show intro banner; %@ is target word"), target)
            }
            static var curtainUp: String {
                NSLocalizedString("aiCoach.maury.curtainUp", value: "Curtain up\u{2026}", comment: "Maury: loading state")
            }
            static var stagehandsAtWork: String {
                NSLocalizedString("aiCoach.maury.stagehandsAtWork", value: "Stagehands at work\u{2026}", comment: "Maury: loading secondary message")
            }
            static func caseProgress(_ current: Int, _ total: Int) -> String {
                String(format: NSLocalizedString("aiCoach.maury.caseProgress", value: "Case %d of %d", comment: "Maury: progress label — Case 3 of 6"), current, total)
            }
            static var verdictFamily: String {
                NSLocalizedString("aiCoach.maury.verdictFamily", value: "FAMILY!", comment: "Maury: user verdict button — believes candidate shares root")
            }
            static var verdictLiar: String {
                NSLocalizedString("aiCoach.maury.verdictLiar", value: "LIAR!", comment: "Maury: user verdict button — believes candidate is false relative")
            }
            static var resultsAreIn: String {
                NSLocalizedString("aiCoach.maury.resultsAreIn", value: "THE RESULTS ARE IN\u{2026}", comment: "Maury: envelope reveal headline")
            }
            static var tapEnvelope: String {
                NSLocalizedString("aiCoach.maury.tapEnvelope", value: "Tap the envelope to reveal", comment: "Maury: envelope instruction")
            }
            /// Big verdict text — candidate IS in the root family
            static var youAreTheMorpheme: String {
                NSLocalizedString("aiCoach.maury.youAreTheMorpheme", value: "you ARE\nthe morpheme!", comment: "Maury: reveal text for true cognate")
            }
            /// Big verdict text — candidate is NOT in the root family
            static var youAreNotTheMorpheme: String {
                NSLocalizedString("aiCoach.maury.youAreNotTheMorpheme", value: "you are NOT\nthe morpheme!", comment: "Maury: reveal text for false relative")
            }
            static var caseClosed: String {
                NSLocalizedString("aiCoach.maury.caseClosed", value: "Case Closed.", comment: "Maury: finale title")
            }
            static func finalScore(_ correct: Int, _ total: Int) -> String {
                String(format: NSLocalizedString("aiCoach.maury.finalScore", value: "You judged %d of %d correctly.", comment: "Maury: finale score; %d correct out of %d total"), correct, total)
            }
            static var nextEpisode: String {
                NSLocalizedString("aiCoach.maury.nextEpisode", value: "Next Episode", comment: "Maury: next quiz button")
            }
            static var backstageTitle: String {
                NSLocalizedString("aiCoach.maury.backstageTitle", value: "Leaving the show?", comment: "Maury: dismiss confirmation title")
            }
            static var backstageMessage: String {
                NSLocalizedString("aiCoach.maury.backstageMessage", value: "The audience is waiting on your verdict.", comment: "Maury: dismiss confirmation message")
            }
            static var stayOnStage: String {
                NSLocalizedString("aiCoach.maury.stayOnStage", value: "Back to the Stage", comment: "Maury: cancel dismiss")
            }
            static var leaveShow: String {
                NSLocalizedString("aiCoach.maury.leaveShow", value: "Leave Show", comment: "Maury: confirm dismiss")
            }
            static var noBookmarksTitle: String {
                NSLocalizedString("aiCoach.maury.noBookmarksTitle", value: "No Guests Booked", comment: "Maury: empty state title")
            }
            static var noBookmarksMessage: String {
                NSLocalizedString("aiCoach.maury.noBookmarksMessage", value: "Bookmark some English words first — Maury needs guests for the show.", comment: "Maury: empty state message")
            }
            static var episodeBusted: String {
                NSLocalizedString("aiCoach.maury.episodeBusted", value: "We couldn't book an episode with any of your bookmarks. Try adding more English words with Latin or Greek roots.", comment: "Maury: all quizzes failed")
            }
            /// Build-up text shown briefly before the verdict reveal, in the
            /// daytime-TV-host "drumroll" cadence ("You... ARE the morpheme!").
            static var buildupPrompt: String {
                NSLocalizedString("aiCoach.maury.buildupPrompt", value: "You\u{2026}", comment: "Maury: drumroll lead-in text before the verdict reveal — Maury Show signature phrase 'You ARE / You are NOT'")
            }
            /// Hint shown at the bottom of the reveal overlay telling the user
            /// to tap anywhere to proceed to the next case.
            static var continueHint: String {
                NSLocalizedString("aiCoach.maury.continueHint", value: "Tap to continue", comment: "Maury: hint at the bottom of the reveal overlay — user taps anywhere to proceed")
            }
            /// Loading-state title when the engine has exhausted retries and
            /// can't produce a quiz at all (different from per-episode failure).
            static var failedTitle: String {
                NSLocalizedString("aiCoach.maury.failedTitle", value: "The show can't go on", comment: "Maury: error-state title shown when the engine fails to produce ANY quiz")
            }
            /// Title shown when the user has played through every guest in
            /// their bookmark library and no more episodes are bookable.
            static var allDoneTitle: String {
                NSLocalizedString("aiCoach.maury.allDoneTitle", value: "That's a wrap!", comment: "Maury: title when the user has played through all bookmarked words — distinct from per-episode 'Case Closed.'")
            }
            /// Subtitle for `allDoneTitle` — every guest has been on the show.
            static var allDoneMessage: String {
                NSLocalizedString("aiCoach.maury.allDoneMessage", value: "All bookmarked guests have been on the show.", comment: "Maury: subtitle when the user has played through all bookmarked words")
            }
        }

        // MARK: Phrasy Feud

        enum PhrasyFeud {
            static var loadingTitle: String {
                NSLocalizedString("aiCoach.phrasyFeud.loadingTitle", value: "Tonight on Phrasy Feud\u{2026}", comment: "Phrasy Feud: loading state title (game-show-host voice)")
            }
            static var loadingMessage: String {
                NSLocalizedString("aiCoach.phrasyFeud.loadingMessage", value: "Surveying the audience\u{2026}", comment: "Phrasy Feud: loading state subtitle")
            }
            static var notEnoughBookmarksTitle: String {
                NSLocalizedString("aiCoach.phrasyFeud.notEnoughBookmarksTitle", value: "Not Ready for Showtime", comment: "Phrasy Feud: gate-failure placeholder title")
            }
            static var notEnoughBookmarksMessage: String {
                NSLocalizedString("aiCoach.phrasyFeud.notEnoughBookmarksMessage", value: "Bookmark more English words and come back to play.", comment: "Phrasy Feud: gate-failure placeholder body — intentionally does NOT name the threshold (24) so the user can't try to game it; copy stays vague on purpose")
            }
            static var engineErrorTitle: String {
                NSLocalizedString("aiCoach.phrasyFeud.engineErrorTitle", value: "Couldn't Dream Up a Round", comment: "Phrasy Feud: engine-failure placeholder title")
            }
            static var engineErrorMessage: String {
                NSLocalizedString("aiCoach.phrasyFeud.engineErrorMessage", value: "The on-device model didn't cooperate this time. Want to try again?", comment: "Phrasy Feud: engine-failure placeholder body")
            }
            static var tryAgain: String {
                NSLocalizedString("aiCoach.phrasyFeud.tryAgain", value: "Try Again", comment: "Phrasy Feud: retry button after engine error")
            }
            static var leaveTitle: String {
                NSLocalizedString("aiCoach.phrasyFeud.leaveTitle", value: "Walking off the show?", comment: "Phrasy Feud: back-nav double-check alert title — broadcast contestant-walks-off-stage framing")
            }
            static var leaveMessage: String {
                NSLocalizedString("aiCoach.phrasyFeud.leaveMessage", value: "You'll forfeit the prize money still on the table — don't walk away from the cash!", comment: "Phrasy Feud: back-nav alert body — appeals to contestants' core motivation (prize money) per Family Feud broadcast convention")
            }
            static var leaveShow: String {
                NSLocalizedString("aiCoach.phrasyFeud.leaveShow", value: "Walk Off", comment: "Phrasy Feud: confirm leaving mid-round — destructive action verb, stage exit metaphor")
            }
            static var stayOnShow: String {
                NSLocalizedString("aiCoach.phrasyFeud.stayOnShow", value: "Stay on Stage", comment: "Phrasy Feud: cancel leaving mid-round — keeps the broadcast-stage metaphor")
            }
            static func finaleTitle(_ points: Int) -> String {
                String(format: NSLocalizedString("aiCoach.phrasyFeud.finaleTitle", value: "%d POINTS", comment: "Phrasy Feud: end-of-round headline — the points scored, formatted as the large hero text"), points)
            }
            static func finaleScore(_ correct: Int, _ total: Int) -> String {
                String(format: NSLocalizedString("aiCoach.phrasyFeud.finaleScore", value: "%d of %d answers found", comment: "Phrasy Feud: finale subtitle line under the points; %1$d correct, %2$d total"), correct, total)
            }
            static var nextRound: String {
                NSLocalizedString("aiCoach.phrasyFeud.nextRound", value: "Next Round", comment: "Phrasy Feud: button to start the next round from the finale screen")
            }
            static var timerLabel: String {
                NSLocalizedString("aiCoach.phrasyFeud.timerLabel", value: "TIME", comment: "Phrasy Feud: small label above the countdown timer LCD (left of buzzer)")
            }
            static var scoreLabel: String {
                NSLocalizedString("aiCoach.phrasyFeud.scoreLabel", value: "TOTAL", comment: "Phrasy Feud: small label above the running-score LCD (right of buzzer)")
            }
            static var tapToStart: String {
                NSLocalizedString("aiCoach.phrasyFeud.tapToStart", value: "Tap to Start", comment: "Phrasy Feud: banner CTA shown before the user taps to flip the banner and start the timer")
            }
            static var submitAnswerMessage: String {
                NSLocalizedString("aiCoach.phrasyFeud.submitAnswerMessage", value: "Submit your answer", comment: "Phrasy Feud: alert message when the buzzer is tapped — prompts the user to type their guess")
            }
            static var answerPlaceholder: String {
                NSLocalizedString("aiCoach.phrasyFeud.answerPlaceholder", value: "Your answer\u{2026}", comment: "Phrasy Feud: alert text-field placeholder for the user's typed guess")
            }
            static var submit: String {
                NSLocalizedString("aiCoach.phrasyFeud.submit", value: "Submit", comment: "Phrasy Feud: alert action — submit the typed guess for matching")
            }
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
        static var backButtonTitle: String {
            NSLocalizedString("wordList.backButtonTitle", value: "Word Lookup", comment: "Back button title")
        }

        // Search bar scope segmented control (M15 — spelling vs semantic
        // vs article-content lookup)
        static var searchScopeSpelling: String {
            NSLocalizedString("wordList.searchScope.spelling", value: "Spelling", comment: "Search bar scope: literal/lemma-based lookup (default)")
        }
        static var searchScopeSemantic: String {
            NSLocalizedString("wordList.searchScope.semantic", value: "Semantic", comment: "Search bar scope: NLEmbedding-based semantic neighbor lookup (slower)")
        }
        /// Third scope button, only shown when the user has flipped on
        /// `articleSearchEnabled` in the article-search overview VC.
        /// Matches the feature name ("Search by Article Contents")
        /// shown on the overview VC title.
        static var searchScopeArticle: String {
            NSLocalizedString("wordList.searchScope.article", value: "Article", comment: "Search bar scope: article-content (full-text body) lookup; only visible when the user enabled article search in Settings")
        }

        // Empty-state copy shown when the user picks the Article scope
        // before the query-time consumer ships (Phase 3.5 follow-up).
        static var articleScopeComingSoonTitle: String {
            NSLocalizedString("wordList.articleScopeComingSoon.title", value: "Article search coming soon", comment: "Empty-state title when the user taps the Article scope while the query consumer is still under construction")
        }
        static var articleScopeComingSoonMessage: String {
            NSLocalizedString("wordList.articleScopeComingSoon.message", value: "Your dictionaries are being indexed for article-content search. Once that's done, this scope will return matches by article body, not just by spelling.", comment: "Body copy for the Article-scope coming-soon empty state")
        }

        // Two distinct headers: in semantic scope BOTH sections can appear at
        // once (semantic candidates + Levenshtein-fuzzy fallback for suspected
        // typos), so calling them both "Suggestions" leaves users wondering
        // which is which.
        static var spellingSuggestionsHeader: String {
            NSLocalizedString("wordList.spellingSuggestionsHeader", value: "Spelling Suggestions", comment: "Section header for Levenshtein-distance fuzzy spelling fallback (was 'Suggestions' pre-M15)")
        }
        static var semanticSuggestionsHeader: String {
            NSLocalizedString("wordList.semanticSuggestionsHeader", value: "Semantic Suggestions", comment: "Section header for NLEmbedding semantic neighbor candidates in semantic scope")
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
            NSLocalizedString("wordList.searchResultsHeader", value: "Search Results", comment: "Section header for search results in word list")
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
        // Status copy shown beneath the searching title. With Phase 2's
        // Option C (NLEmbedding-direct, no per-dict cache) the only step
        // slow enough to warrant a status line is the Levenshtein fuzzy
        // fallback in semantic scope — see SemanticLookupSession. The
        // spelling pipeline is fast enough that no status detail is useful.
        static var statusCheckingSpelling: String {
            NSLocalizedString("wordList.statusCheckingSpelling", value: "Checking spelling\u{2026}", comment: "Status line during the Levenshtein-distance fuzzy fallback (typo check) in semantic scope")
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
        static var enhanceDarkMode: String {
            NSLocalizedString("dictInfo.enhanceDarkMode", value: "Enhance Dark Mode", comment: "Toggle label for per-dict dark mode enhancement")
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
        static var sectionFonts: String {
            NSLocalizedString("resourceEditor.section.fonts", value: "CUSTOM FONTS (TTF, OTF, WOFF, WOFF2)", comment: "Section header; the parenthetical lists supported font file formats")
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

        // Enhance dark mode strength (tap menu on moon button).
        // --- Enhance Dark Mode popover ---
        static var enhanceDarkModeTitle: String {
            NSLocalizedString("detail.enhanceDarkModeTitle", value: "Dark Enhancements", comment: "Popover title for per-dict dark mode enhancement slider")
        }
        static var enhanceDarkModeEnabled: String {
            NSLocalizedString("detail.enhanceDarkModeEnabled", value: "Enabled", comment: "Switch label to enable/disable dark mode enhancement")
        }
        static var enhanceDarkModeAdjustment: String {
            NSLocalizedString("detail.enhanceDarkModeAdjustment", value: "Adjustment", comment: "Label for the enhancement strength adjustment row")
        }
        static var enhanceDarkModeDescription: String {
            NSLocalizedString("detail.enhanceDarkModeDescription", value: "Improve readability if this dictionary has custom styles.", comment: "Section footer explaining the dark mode enhancement purpose")
        }
        // "Dim/bright" avoids collision with "light/dark" appearance terminology.
        static var enhanceDarkModeNone: String {
            NSLocalizedString("detail.enhanceDarkModeNone", value: "None", comment: "Turn off dark mode enhancement for this dictionary")
        }
        static var enhanceDimmest: String {
            NSLocalizedString("detail.enhanceDimmest", value: "Dimmest", comment: "Dimmest dark mode enhancement tier (gamma=0.4)")
        }
        static var enhanceDimmer: String {
            NSLocalizedString("detail.enhanceDimmer", value: "Dimmer", comment: "Dimmer dark mode enhancement tier (gamma=0.6)")
        }
        static var enhanceDim: String {
            NSLocalizedString("detail.enhanceDim", value: "Dim", comment: "Dim dark mode enhancement tier (gamma=0.8)")
        }
        static var enhanceStandard: String {
            NSLocalizedString("detail.enhanceStandard", value: "Standard", comment: "Standard/baseline dark mode enhancement tier (gamma=1.0)")
        }
        static var enhanceBright: String {
            NSLocalizedString("detail.enhanceBright", value: "Bright", comment: "Bright dark mode enhancement tier (gamma=1.2)")
        }
        static var enhanceBrighter: String {
            NSLocalizedString("detail.enhanceBrighter", value: "Brighter", comment: "Brighter dark mode enhancement tier (gamma=1.4)")
        }
        static var enhanceBrightest: String {
            NSLocalizedString("detail.enhanceBrightest", value: "Brightest", comment: "Brightest dark mode enhancement tier (gamma=1.6)")
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
            NSLocalizedString("shortcuts.category.query", value: "Lookup", comment: "Keyboard shortcut HUD category: query/lookup")
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
            NSLocalizedString("shortcuts.focusLookup", value: "Focus on Lookup Input", comment: "Keyboard shortcut: focus on the query/lookup search bar")
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
        /// Footer for CTA section when suggestions are available. Use with String(format:, word).
        static var noExactMatch: String {
            NSLocalizedString("actionExtension.noExactMatch", value: "No exact match for \u{201C}%@\u{201D}.", comment: "Action Extension: footer text when no exact/lemma match found (%@ = word)")
        }
        /// Section header for spelling suggestions list.
        static var didYouMean: String {
            NSLocalizedString("actionExtension.didYouMean", value: "Did you mean\u{2026}", comment: "Action Extension: section header for spelling suggestions")
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
        /// Summary item: N lookup history entries
        static func summaryLookupHistory(_ count: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("syncChooser.summaryLookupHistory", value: "%d lookup history entries", comment: "Sync chooser: number of lookup history entries found in iCloud"),
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
        /// Category title: lookup history
        static var categoryLookupHistory: String {
            NSLocalizedString("syncProgress.categoryLookupHistory", value: "Your lookup history", comment: "Cloud sync progress: lookup history category title")
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

    // MARK: - App Icon Chooser

    enum AppIcon {
        static var title: String {
            NSLocalizedString("appIcon.title", value: "App Icon", comment: "Title: app icon chooser screen / sidebar item")
        }
        static var sectionStandard: String {
            NSLocalizedString("appIcon.section.standard", value: "Standard", comment: "Section header: standard app icons")
        }
        static var defaultIcon: String {
            NSLocalizedString("appIcon.default", value: "Default", comment: "App icon name: default icon")
        }
        static var defaultInverse: String {
            NSLocalizedString("appIcon.defaultInverse", value: "Default (Inverse)", comment: "App icon name: inverted colors variant of default icon")
        }
        static var west: String {
            NSLocalizedString("appIcon.west", value: "Latin", comment: "App icon name: Latin alphabet variant (Aa)")
        }
        static var east1: String {
            NSLocalizedString("appIcon.east1", value: "Chinese Character", comment: "App icon name: Chinese character variant (辞)")
        }
        static var east2: String {
            NSLocalizedString("appIcon.east2", value: "Chinese Character - Traditional", comment: "App icon name: traditional Chinese character variant (詞)")
        }
        static var east3: String {
            NSLocalizedString("appIcon.east3", value: "Chinese Character - Simplified", comment: "App icon name: simplified Chinese character variant (词)")
        }
        static var east4: String {
            NSLocalizedString("appIcon.east4", value: "Hiragana", comment: "App icon name: Japanese hiragana variant (ひ)")
        }
        static var east5: String {
            NSLocalizedString("appIcon.east5", value: "Hangul", comment: "App icon name: Korean hangul variant (한)")
        }
        static var east114514: String {
            NSLocalizedString("appIcon.east114514", value: "114514", comment: "App icon name: easter egg variant")
        }
        /// Format string for dark variant labels on iOS 15–17.
        /// %@ is the base icon name, e.g. "Default" → "Default (Dark)".
        static var darkFormat: String {
            NSLocalizedString("appIcon.darkFormat", value: "%@ (Dark)", comment: "Format: dark variant of an icon name. %@ = base name")
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

        // MARK: Status — last CloudKit mirroring reset
        static var lastResetTitle: String {
            NSLocalizedString("troubleshoot.lastReset.title", value: "Last Sync Reset", comment: "Cell title: when iCloud mirroring last reset itself on this device")
        }
        static var lastResetNever: String {
            NSLocalizedString("troubleshoot.lastReset.never", value: "Never", comment: "Cell subtitle: iCloud mirroring has never reset on this device")
        }
        static var lastResetReasonHistoryExpired: String {
            NSLocalizedString("troubleshoot.lastReset.reason.historyExpired", value: "History expired", comment: "Reason for an iCloud mirroring reset: persistent history token expired")
        }
        static var lastResetReasonChangeTokenExpired: String {
            NSLocalizedString("troubleshoot.lastReset.reason.changeTokenExpired", value: "Server change token expired", comment: "Reason for an iCloud mirroring reset: CloudKit server change token expired")
        }
        static var lastResetReasonZoneDeleted: String {
            NSLocalizedString("troubleshoot.lastReset.reason.zoneDeleted", value: "iCloud zone deleted", comment: "Reason for an iCloud mirroring reset: the CloudKit record zone was deleted")
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

    // MARK: - Tutorial (New User Guide)

    enum Tutorial {
        static var title: String {
            NSLocalizedString("tutorial.title", value: "New User Guide", comment: "Title: tutorial / new user guide screen and sidebar item")
        }

        // Section headers
        static var sectionIntroductory: String {
            NSLocalizedString("tutorial.section.introductory", value: "Introductory", comment: "Section header: introductory tutorial levels")
        }
        static var sectionIntermediate: String {
            NSLocalizedString("tutorial.section.intermediate", value: "Intermediate", comment: "Section header: intermediate tutorial levels")
        }
        static var sectionAdvanced: String {
            NSLocalizedString("tutorial.section.advanced", value: "Advanced", comment: "Section header: advanced tutorial levels")
        }

        // Hands-on level titles
        static var zoomAndLayoutTitle: String {
            NSLocalizedString("tutorial.zoomAndLayout.title", value: "Zoom & Layout", comment: "Tutorial level title: zoom and layout")
        }
        static var enhanceDarkModeTitle: String {
            NSLocalizedString("tutorial.enhanceDarkMode.title", value: "Dark Mode Enhancements", comment: "Tutorial level title: enhance dark mode")
        }
        static var bookmarksTitle: String {
            NSLocalizedString("tutorial.bookmarks.title", value: "Bookmarks", comment: "Tutorial level title: bookmarks")
        }
        static var jumpSearchTitle: String {
            NSLocalizedString("tutorial.jumpSearch.title", value: "Jump Search", comment: "Tutorial level title: jump search")
        }
        static var findInPageTitle: String {
            NSLocalizedString("tutorial.findInPage.title", value: "Find in Page", comment: "Tutorial level title: find in page")
        }

        // Guide level titles
        static var lookupBasicsTitle: String {
            NSLocalizedString("tutorial.lookupBasics.title", value: "Lookup Basics", comment: "Tutorial level title: lookup basics")
        }
        static var popupLookupTitle: String {
            NSLocalizedString("tutorial.popupLookup.title", value: "Pop-up Lookup", comment: "Tutorial level title: pop-up lookup (action extension)")
        }
        static var dictionaryGroupsTitle: String {
            NSLocalizedString("tutorial.dictionaryGroups.title", value: "Dictionary Groups", comment: "Tutorial level title: dictionary groups")
        }
        static var importAndResourcesTitle: String {
            NSLocalizedString("tutorial.importAndResources.title", value: "MDX Import & Resources", comment: "Tutorial level title: import and resource management")
        }
        static var iPadProductivityTitle: String {
            NSLocalizedString("tutorial.iPadProductivity.title", value: "iPad Productivity", comment: "Tutorial level title: iPad multitasking and keyboard shortcuts")
        }

        // Hands-on level descriptions
        static var zoomAndLayoutDesc: String {
            NSLocalizedString("tutorial.zoomAndLayout.desc", value: "Adjust text size and article layout", comment: "Tutorial level description: zoom and layout")
        }
        static var enhanceDarkModeDesc: String {
            NSLocalizedString("tutorial.enhanceDarkMode.desc", value: "Fix dark mode's readability on imported dictionaries with custom styles", comment: "Tutorial level description: enhance dark mode")
        }
        static var bookmarksDesc: String {
            NSLocalizedString("tutorial.bookmarks.desc", value: "Save and manage favorite entries", comment: "Tutorial level description: bookmarks")
        }
        static var jumpSearchDesc: String {
            NSLocalizedString("tutorial.jumpSearch.desc", value: "Look up words directly from articles", comment: "Tutorial level description: jump search")
        }
        static var findInPageDesc: String {
            NSLocalizedString("tutorial.findInPage.desc", value: "Search for text within an article", comment: "Tutorial level description: find in page")
        }

        // Guide level descriptions
        static var lookupBasicsDesc: String {
            NSLocalizedString("tutorial.lookupBasics.desc", value: "Clipboard, search results, related forms, and suggestions", comment: "Tutorial level description: lookup basics")
        }
        static var popupLookupDesc: String {
            NSLocalizedString("tutorial.popupLookup.desc", value: "Look up words from any app via Share Sheet", comment: "Tutorial level description: pop-up lookup")
        }
        static var dictionaryGroupsDesc: String {
            NSLocalizedString("tutorial.dictionaryGroups.desc", value: "Organize dictionaries into groups", comment: "Tutorial level description: dictionary groups")
        }
        static var importAndResourcesDesc: String {
            NSLocalizedString("tutorial.importAndResources.desc", value: "Import MDX files and manage CSS/JS resources", comment: "Tutorial level description: import and resource management")
        }
        static var iPadProductivityDesc: String {
            NSLocalizedString("tutorial.iPadProductivity.desc", value: "Multitasking, multi-window, and keyboard shortcuts", comment: "Tutorial level description: iPad productivity")
        }

        // Coaching mark buttons
        static var next: String {
            NSLocalizedString("tutorial.button.next", value: "Next", comment: "Tutorial coaching button: advance to next step")
        }
        static var tryIt: String {
            NSLocalizedString("tutorial.button.tryIt", value: "Try It", comment: "Tutorial coaching button: try the interaction")
        }
        static var gotIt: String {
            NSLocalizedString("tutorial.button.gotIt", value: "Got It", comment: "Tutorial coaching button: understood, finish")
        }
        static func stepOf(_ current: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("tutorial.stepOf", value: "Step %d of %d", comment: "Tutorial step indicator: Step X of Y"), current, total)
        }

        // Wrong action alert
        static var wrongActionTitle: String {
            NSLocalizedString("tutorial.wrongAction.title", value: "Not Quite!", comment: "Alert title: user tapped wrong button during tutorial")
        }
        static var wrongActionBookmark: String {
            NSLocalizedString("tutorial.wrongAction.bookmark", value: "Please tap the highlighted bookmark button to continue.", comment: "Alert message: expected bookmark tap")
        }
        static var wrongActionMoon: String {
            NSLocalizedString("tutorial.wrongAction.moon", value: "Please tap the highlighted moon button to continue.", comment: "Alert message: expected moon button tap")
        }
        static var wrongActionFind: String {
            NSLocalizedString("tutorial.wrongAction.find", value: "Please tap the highlighted find button to continue.", comment: "Alert message: expected find button tap")
        }
        static var wrongActionZoom: String {
            NSLocalizedString("tutorial.wrongAction.zoom", value: "Please tap one of the zoom buttons in the toolbar to continue.", comment: "Alert message: expected zoom control tap")
        }
        static var wrongActionJumpSearch: String {
            NSLocalizedString("tutorial.wrongAction.jumpSearch", value: "Long-press a word in the article, then select \"Jump Search\" from the menu.", comment: "Alert message: expected jump search")
        }

        // Completion celebration
        static var completionTitle: String {
            NSLocalizedString("tutorial.completion.title", value: "Congratulations", comment: "Celebration title when tutorial is completed")
        }
        static var completionMessage: String {
            NSLocalizedString("tutorial.completion.message", value: "Well done! You've completed this tutorial.", comment: "Celebration subtitle when tutorial is completed")
        }
        static var completionButton: String {
            NSLocalizedString("tutorial.completion.button", value: "Good to Know!", comment: "Celebration button: return to tutorial list")
        }

        // Wrong keyboard shortcut
        static func wrongKeyboardShortcut(_ pressed: String) -> String {
            String(format: NSLocalizedString("tutorial.wrongAction.keyboard", value: "You pressed %@. Please check the shortcut reference and try the correct key combination.", comment: "Alert message: wrong keyboard shortcut pressed. %@ = what the user pressed"), pressed)
        }

        // Wrong action: Import & Resources
        static var wrongActionImport: String {
            NSLocalizedString("tutorial.wrongAction.import", value: "Please tap \"Import Dictionary\" to continue.", comment: "Alert message: expected Import Dictionary tap")
        }
        static var wrongActionEdit: String {
            NSLocalizedString("tutorial.wrongAction.edit", value: "Please tap the Edit button in the navigation bar to continue.", comment: "Alert message: expected Edit button tap")
        }
        static var wrongActionDictInfo: String {
            NSLocalizedString("tutorial.wrongAction.dictInfo", value: "Please tap the ℹ button on the highlighted dictionary to continue.", comment: "Alert message: expected dict info button tap")
        }
        static var wrongActionManageResources: String {
            NSLocalizedString("tutorial.wrongAction.manageResources", value: "Please tap \"Manage Resources\" to continue.", comment: "Alert message: expected Manage Resources tap")
        }
        static var wrongActionAddMDD: String {
            NSLocalizedString("tutorial.wrongAction.addMDD", value: "Please tap \"Add MDD File\" to continue.", comment: "Alert message: expected Add MDD tap")
        }

        // Find in Page iOS 15 unavailable
        static var findUnavailableMessage: String {
            NSLocalizedString("tutorial.findUnavailable.message", value: "Find in Page requires iOS 16 or later. Please update your device to access this feature.", comment: "Alert message: Find in Page not available on iOS 15")
        }

        // Wrong action: Dictionary Groups
        static var wrongActionGroupInfo: String {
            NSLocalizedString("tutorial.wrongAction.groupInfo", value: "Please tap the ℹ button on the highlighted group to continue.", comment: "Alert message: expected group info button tap")
        }
        static var wrongActionContainedItems: String {
            NSLocalizedString("tutorial.wrongAction.containedItems", value: "Please tap \"Contained Items\" to continue.", comment: "Alert message: expected Contained Items tap")
        }

        // Exit confirmation
        static var exitTitle: String {
            NSLocalizedString("tutorial.exit.title", value: "Leave Tutorial?", comment: "Alert title: leaving incomplete tutorial")
        }
        static var exitMessage: String {
            NSLocalizedString("tutorial.exit.message", value: "This tutorial is not complete yet. Are you sure you want to leave?", comment: "Alert message: leaving incomplete tutorial")
        }
        static var exitConfirm: String {
            NSLocalizedString("tutorial.exit.confirm", value: "Leave", comment: "Alert button: confirm leaving tutorial")
        }
        static var exitCancel: String {
            NSLocalizedString("tutorial.exit.cancel", value: "Stay", comment: "Alert button: cancel leaving tutorial")
        }
    }

    // MARK: - M15 Article-Content Search Indexing

    enum ArticleIndex {
        static var title: String {
            NSLocalizedString("articleIndex.title", value: "Search by Article Contents", comment: "Title: article-content indexing overview screen / sidebar item — the feature name shown to users")
        }
        static var enableTitle: String {
            NSLocalizedString("articleIndex.enable.title", value: "Enable Article Search", comment: "Switch label: master toggle for article-content (full-text) search")
        }
        /// "What" copy in the master-toggle section's footer — describes
        /// what the feature DOES for the user. The master cell itself
        /// is now just the toggle + title (kept compact);
        /// the "what" copy fits naturally below as the section footer.
        static var enableFooter: String {
            NSLocalizedString("articleIndex.enable.footer", value: "Find words by the meaning of their definitions, not just by spelling.", comment: "Section footer below the master toggle — explains what article search does (the 'what')")
        }
        /// "How" copy in the Enabled-dictionaries section footer — explains
        /// the resource cost / side effects of indexing. Lives on the
        /// `Enabled` section because it describes what happens TO the
        /// enabled dictionaries (they get indexed on-device while
        /// charging).
        static var enabledSectionFooter: String {
            NSLocalizedString("articleIndex.enabledSection.footer", value: "Indexing runs entirely on-device and can take a while for large dictionaries; it continues in the background while your device is charging.", comment: "Section footer below Enabled dictionaries — explains how article-search indexing is built (the 'how')")
        }
        static var sectionDicts: String {
            NSLocalizedString("articleIndex.section.dicts", value: "Dictionaries", comment: "Section header: per-dictionary indexing status list")
        }
        static var sectionEnabled: String {
            NSLocalizedString("articleIndex.section.enabled", value: "Enabled dictionaries", comment: "Section header: dictionaries enabled for article search")
        }
        static var sectionDisabled: String {
            NSLocalizedString("articleIndex.section.disabled", value: "Disabled dictionaries", comment: "Section header: dictionaries excluded from article search")
        }
        static var emptyEnabled: String {
            NSLocalizedString("articleIndex.empty.enabled", value: "No dictionaries enabled.\nTap one below to enable.", comment: "Empty-section placeholder: shown when Enabled section has zero dictionaries. The \\n splits the two sentences onto separate lines (cell uses numberOfLines = 0).")
        }
        static var emptyDisabled: String {
            NSLocalizedString("articleIndex.empty.disabled", value: "All dictionaries are enabled.", comment: "Empty-section placeholder: shown when Disabled section has zero dictionaries (every dict is enabled)")
        }
        /// Special-case placeholder for "user has zero dictionaries in the
        /// whole library" — distinct from `emptyEnabled` / `emptyDisabled`
        /// (which assume the other section has dicts). Surfaces "import
        /// one first" rather than the inappropriate "tap one below" /
        /// "all are enabled" copy. Shown in the Disabled section per
        /// design.
        static var emptyNoDicts: String {
            NSLocalizedString("articleIndex.empty.noDicts", value: "No dictionaries imported yet.\nImport a dictionary first to use article search.", comment: "Empty-section placeholder: shown in the Disabled section when the user has zero dictionaries in the entire library")
        }

        // MARK: - Master-toggle confirmation alerts
        //
        // Both directions of the "Enable Article Search" switch show a
        // confirmation alert before committing. ON warns about the ~80 MB
        // ODR download + per-dict indexing. OFF warns about removing the
        // model and every existing sidecar (the indexed-dict count is
        // interpolated into the body copy).
        enum MasterToggle {
            static var enableTitle: String {
                NSLocalizedString("articleIndex.masterToggle.enable.title", value: "Enable article search?", comment: "Confirmation alert title when the user flips the master toggle ON")
            }
            static var enableMessage: String {
                NSLocalizedString("articleIndex.masterToggle.enable.message", value: "OpenMDict will download a roughly 80 MB language model and index your dictionaries one by one. Once indexing is done, you'll be able to pick \"Article\" in the search scope to look up by article body.", comment: "Confirmation body explaining the ~80 MB download + per-dict indexing trigger on enable")
            }
            static var enableConfirm: String {
                NSLocalizedString("articleIndex.masterToggle.enable.confirm", value: "Enable", comment: "Confirm-enable button title")
            }
            static var disableTitle: String {
                NSLocalizedString("articleIndex.masterToggle.disable.title", value: "Disable Article Lookup?", comment: "Confirmation alert title when the user flips the master toggle OFF")
            }
            static func disableMessage(indexedCount: Int) -> String {
                // Deliberately vague about the language model: disabling drops
                // the ODR reservation, but iOS purges the on-disk asset lazily
                // (no API to force-delete it now), so we don't promise it's
                // gone. We DO delete the sidecars + CoreData rows eagerly, so
                // the re-index caveat is the honest, user-actionable part.
                if indexedCount == 0 {
                    // Nothing indexed yet → nothing to clear, only the caveat.
                    return NSLocalizedString("articleIndex.masterToggle.disable.message.none", value: "If you turn it back on later, your dictionaries will need to be re-indexed.", comment: "Disable-confirmation body when zero dictionaries are currently indexed — nothing to clear, only the re-index caveat")
                }
                return String(format: NSLocalizedString("articleIndex.masterToggle.disable.message", value: "This will remove the article-content index for %d dictionary/dictionaries. If you turn it back on later, they'll need to be re-indexed.", comment: "Disable-confirmation body; %d is the number of indexed dictionaries whose on-device indexes are removed"), indexedCount)
            }
            static var disableConfirm: String {
                NSLocalizedString("articleIndex.masterToggle.disable.confirm", value: "Turn Off", comment: "Confirm-disable button title; destructive")
            }
            static var cancel: String {
                NSLocalizedString("articleIndex.masterToggle.cancel", value: "Cancel", comment: "Cancel button for the master-toggle confirmation alert (used by both enable + disable paths)")
            }
        }

        /// In-app result-count tier knob (Fewer / Default / More) shown under
        /// the master toggle — the article-search counterpart to the semantic
        /// results setting in Settings.bundle. Kept in-app because the feature
        /// is iOS 26+ and Settings.bundle can't conditionally hide a row.
        enum ResultsCount {
            static var title: String {
                NSLocalizedString("articleIndex.resultsCount.title", value: "Results per dictionary", comment: "Setting label: how many article-content matches to return per dictionary")
            }
            static var few: String {
                NSLocalizedString("articleIndex.resultsCount.few", value: "Fewer", comment: "Article-search result-count tier: fewer results")
            }
            static var `default`: String {
                NSLocalizedString("articleIndex.resultsCount.default", value: "Default", comment: "Article-search result-count tier: default")
            }
            static var more: String {
                NSLocalizedString("articleIndex.resultsCount.more", value: "More", comment: "Article-search result-count tier: more results")
            }
        }

        static var statusIndexed: String {
            NSLocalizedString("articleIndex.status.indexed", value: "Indexed", comment: "Status: dictionary fully indexed for article search")
        }
        static var statusNotIndexed: String {
            NSLocalizedString("articleIndex.status.notIndexed", value: "Not indexed", comment: "Status: dictionary not yet indexed")
        }
        static var statusToBeIndexed: String {
            NSLocalizedString("articleIndex.status.toBeIndexed", value: "To be indexed", comment: "Status: dictionary queued for indexing")
        }
        static func statusIndexing(_ percent: Int) -> String {
            String(format: NSLocalizedString("articleIndex.status.indexing", value: "Indexing… %d%%", comment: "Status: indexing in progress; %d is percent complete"), percent)
        }
        static func statusPaused(_ percent: Int) -> String {
            String(format: NSLocalizedString("articleIndex.status.paused", value: "Paused at %d%%", comment: "Status: indexing paused by user; %d is percent complete"), percent)
        }
        static var statusExcluded: String {
            NSLocalizedString("articleIndex.status.excluded", value: "Excluded", comment: "Status: dictionary excluded from article search by the user")
        }
        static var statusError: String {
            NSLocalizedString("articleIndex.status.error", value: "Failed — tap to retry", comment: "Status: indexing failed; tapping the row retries")
        }
        static var actionCancel: String {
            NSLocalizedString("articleIndex.action.cancel", value: "Cancel", comment: "Swipe action: cancel an in-progress index")
        }
        static var actionPause: String {
            NSLocalizedString("articleIndex.action.pause", value: "Pause", comment: "Button: pause an in-progress index for a dictionary")
        }
        static var actionResume: String {
            NSLocalizedString("articleIndex.action.resume", value: "Resume", comment: "Button: resume a paused index for a dictionary")
        }
        static var actionRetry: String {
            NSLocalizedString("articleIndex.action.retry", value: "Retry", comment: "Button: retry a failed indexing job")
        }
        static var actionExclude: String {
            NSLocalizedString("articleIndex.action.exclude", value: "Exclude", comment: "Swipe action: exclude a dictionary from article search")
        }
        static var actionInclude: String {
            NSLocalizedString("articleIndex.action.include", value: "Include", comment: "Swipe action: re-include a previously excluded dictionary")
        }
        /// Subtitle's secondary line on dict cells with non-zero progress —
        /// e.g. "40023 / 153888 entries". Kept on its own line so the
        /// long N/M numbers don't trigger awkward truncation/wrapping
        /// on the primary status line.
        static func entriesProgress(_ done: Int32, _ total: Int) -> String {
            String(format: NSLocalizedString("articleIndex.status.entriesProgress", value: "%d / %d entries", comment: "Cell subtitle line: indexed-through count vs total article count"), done, total)
        }
        /// Per-reason full-sentence subtitles for gate-pauses. Each case
        /// maps to a complete, human-readable phrase so the user
        /// immediately understands WHY indexing stopped and what to
        /// expect — short noun labels ("thermal", "low power") were
        /// terse and ambiguous. Used directly as the cell subtitle when
        /// the dispatcher is gate-paused (see Dispatcher.primaryReason
        /// for which one wins when multiple gates fire concurrently).
        enum PauseReason {
            static var userInitiated: String {
                NSLocalizedString("articleIndex.pauseReason.userInitiated", value: "Paused by you", comment: "Pause subtitle: user explicitly paused this dictionary (currently surfaced via persisted .paused state, not via the global gate set)")
            }
            static var insufficientStorage: String {
                NSLocalizedString("articleIndex.pauseReason.insufficientStorage", value: "Paused — free up storage to continue", comment: "Pause subtitle: free disk space below the threshold needed to keep indexing safely")
            }
            /// Static placeholder shown when the dispatcher reports
            /// `.downloadingModel` but no progress fraction is available
            /// yet (the very first KVO tick from NSBundleResourceRequest
            /// arrives within a few ms; this should rarely actually show).
            static var downloadingModelIndeterminate: String {
                NSLocalizedString("articleIndex.pauseReason.downloadingModelIndeterminate", value: "Downloading language model…", comment: "Pause subtitle: ODR download started but progress fraction not yet reported")
            }
            /// Progress-aware variant — `%d` is the integer percentage in
            /// [0, 100]. The VC formats this in place of `localizedLabel`
            /// when `Dispatcher.downloadProgress` is non-nil.
            static func downloadingModel(_ percent: Int) -> String {
                String(format: NSLocalizedString("articleIndex.pauseReason.downloadingModel", value: "Downloading language model (%d%%)…", comment: "Pause subtitle: ODR download in progress; %d is integer percent complete"), percent)
            }
            static var thermal: String {
                NSLocalizedString("articleIndex.pauseReason.thermal", value: "Paused until device cools down", comment: "Gate-pause subtitle: device thermal state is serious/critical — indexing waits for cooldown")
            }
            static var lowPower: String {
                NSLocalizedString("articleIndex.pauseReason.lowPower", value: "Paused while Low Power Mode is on", comment: "Gate-pause subtitle: Low Power Mode active — indexing yields to battery preservation")
            }
            static var memory: String {
                NSLocalizedString("articleIndex.pauseReason.memory", value: "Paused to free up memory", comment: "Gate-pause subtitle: recent memory warning, encoder evicted, brief cool-down before retry")
            }
        }
        static var emptyTitle: String {
            NSLocalizedString("articleIndex.empty.title", value: "No Dictionaries", comment: "Empty state: no dictionaries available to index")
        }
        static var emptyMessage: String {
            NSLocalizedString("articleIndex.empty.message", value: "Import a dictionary first, then enable article search here.", comment: "Empty state message")
        }
        // MARK: - Model-acquisition overlay (EmptyStateView in the overview VC)
        //
        // Shown when the master toggle is ON and the model isn't usable
        // yet (downloading OR in a classified error state). Error path
        // uses `L10n.ODRError.*` (extracted in the ODRError commit);
        // these strings are for the loading and retry-button paths.
        static var modelOverlayDownloadingTitle: String {
            NSLocalizedString("articleIndex.modelOverlay.downloading.title", value: "Downloading Language Model", comment: "EmptyStateView title shown when the ODR model is downloading")
        }
        static func modelOverlayDownloadingMessage(pct: Int) -> String {
            String(format: NSLocalizedString("articleIndex.modelOverlay.downloading.message", value: "%d%% — about 80 MB total. Indexing will start automatically once this is done.", comment: "EmptyStateView body shown while the ODR model is downloading; %d is integer percent complete"), pct)
        }
        /// Shown when we know the model fetch is pending but no
        /// progress fraction has arrived yet (pre-probe window OR
        /// before NSBundleResourceRequest's first KVO tick). Showing
        /// "0%" would imply the download has started + made no
        /// progress, which is misleading during the brief
        /// pre-progress window.
        static var modelOverlayDownloadingMessageIndeterminate: String {
            NSLocalizedString("articleIndex.modelOverlay.downloading.message.indeterminate", value: "About 80 MB total. Indexing will start automatically once this is done.", comment: "EmptyStateView body shown while the ODR model fetch is pending but no progress fraction is yet known")
        }
        static var modelOverlayRetry: String {
            NSLocalizedString("articleIndex.modelOverlay.retry", value: "Retry", comment: "EmptyStateView action button title shown when the model failed to download")
        }
    }

    // MARK: - On-Demand Resource error surfaces
    //
    // Bound to `ODRError` cases (Services/ODRError.swift). Each case has
    // a title + a body. Used by `EmptyStateView.Configuration.error(...)`.
    enum ODRError {
        static var noNetworkTitle: String {
            NSLocalizedString("odrError.noNetwork.title", value: "No Internet Connection", comment: "ODR download failed because the device has no usable network")
        }
        static var noNetworkMessage: String {
            NSLocalizedString("odrError.noNetwork.message", value: "Please check your Wi-Fi or cellular connection and try again.", comment: "ODR no-network body copy")
        }
        static var dataNotAllowedTitle: String {
            NSLocalizedString("odrError.dataNotAllowed.title", value: "Data Use Restricted", comment: "ODR download blocked because the app's data permission is off")
        }
        static var dataNotAllowedMessage: String {
            NSLocalizedString("odrError.dataNotAllowed.message", value: "Allow OpenMDict to use cellular or Wi-Fi data in Settings, then try again.", comment: "ODR data-not-allowed body copy")
        }
        static var insufficientStorageTitle: String {
            NSLocalizedString("odrError.insufficientStorage.title", value: "Not Enough Storage", comment: "ODR download failed because the device is out of free disk")
        }
        static var insufficientStorageMessage: String {
            NSLocalizedString("odrError.insufficientStorage.message", value: "Free up some storage on this device and try again.", comment: "ODR insufficient-storage body copy")
        }
        static var temporarilyUnavailableTitle: String {
            NSLocalizedString("odrError.temporarilyUnavailable.title", value: "Temporarily Unavailable", comment: "ODR download server unreachable or timed out")
        }
        static var temporarilyUnavailableMessage: String {
            NSLocalizedString("odrError.temporarilyUnavailable.message", value: "The download couldn't reach Apple's servers. Please try again in a moment.", comment: "ODR temporarily-unavailable body copy")
        }
        static var fileNotFoundAfterDownloadTitle: String {
            NSLocalizedString("odrError.fileNotFoundAfterDownload.title", value: "Download Incomplete", comment: "ODR succeeded but the expected file is missing from the bundle — likely an Xcode tag mis-configuration")
        }
        static func fileNotFoundAfterDownloadMessage(tag: String, filename: String) -> String {
            String(format: NSLocalizedString("odrError.fileNotFoundAfterDownload.message", value: "Expected file %1$@ (tag “%2$@”) wasn't present after download. This is likely an app packaging issue — please report it.", comment: "ODR file-not-found body copy; %1$@ is filename, %2$@ is resource tag"), filename, tag)
        }
        static var unknownTitle: String {
            NSLocalizedString("odrError.unknown.title", value: "Couldn't Download", comment: "ODR fallback when the error doesn't match any known category")
        }
        static func unknownMessage(description: String) -> String {
            String(format: NSLocalizedString("odrError.unknown.message", value: "Something went wrong while downloading. Details: %@", comment: "ODR unknown body copy; %@ is the underlying error.localizedDescription"), description)
        }
    }
}
