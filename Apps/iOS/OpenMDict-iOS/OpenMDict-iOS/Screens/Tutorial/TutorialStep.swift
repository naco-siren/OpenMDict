//
//  TutorialStep.swift
//  OpenMDict-iOS
//
//  Defines the coaching steps for each tutorial level.
//  Each step specifies what to highlight, what message to show,
//  which action advances the step, and whether the WebView is interactive.
//

import UIKit

// MARK: - TutorialStep

struct TutorialStep {

    /// Where to point the coaching mark.
    enum AnchorTarget {
        case headerArea             // Article header region
        case bookmarkButton         // Bookmark button in header
        case moonButton             // Enhance dark mode button
        case zoomControls           // Zoom bar button items in nav bar
        case findButton             // Find-in-page button in header
        case newWindowButton        // Open in New Window button in header
        case webViewCenter          // WebView content area
        case guideContent           // The guide content view area
        case wordListClipboard      // Clipboard section in WordListVC
        case wordListSearchBar      // Search bar in WordListVC
        case wordListRelatedForms   // Related Forms section in WordListVC
        case wordListSuggestions    // Suggestions section in WordListVC
        case mgmtImportCell         // "Import Dictionary" cell in CompactManagementVC
        case sidebarEditButton      // Edit button in sidebar nav bar
        case sidebarDictInfoButton  // Info button on a specific dict cell (editing mode)
        case sidebarUserGroup       // First user group header cell
        case sidebarUserGroupContent // User group + its children (expanded)
        case sidebarUserGroupInfoButton // Info button on user group cell (editing mode)
        case sidebarAddGroup        // "Add Group" cell in My Groups section
        case groupInfoSection        // GROUP INFO section in GroupInfoVC
        case groupInfoEditButton     // Edit button in GroupInfoVC nav bar
        case groupInfoContainedItems // "Contained Items" cell in GroupInfoVC
        case dictInfoManageResources // "Manage Resources" cell in DictInfoVC
        case resourceEditorAddMDD   // "Add MDD" button in DictResourceEditorVC
        case center                 // Center of screen (no arrow)
    }

    /// Which user action advances this step.
    enum ValidAction: Equatable {
        case tapCoachingButton      // Tap the coaching mark's action button (Next/Got It)
        case tapBookmark            // Tap the bookmark button in the header
        case tapMoonButton          // Tap the enhance dark mode button
        case tapFindButton          // Tap the find-in-page button
        case tapZoomControl         // Tap any zoom control in the nav bar
        case tapJumpSearch          // Long-press word + select Jump Search in WebView
        case tapImportDictionary    // Tap "Import Dictionary" in management list
        case tapEditButton          // Tap Edit button in sidebar nav bar
        case tapDictInfoButton      // Tap info button on a dict cell
        case tapGroupInfoButton     // Tap info button on a group cell
        case tapContainedItems      // Tap "Contained Items" in GroupInfoVC
        case tapManageResources     // Tap "Manage Resources" in DictInfoVC
        case tapAddMDD              // Tap "Add MDD File" in ResourceEditorVC
        case freeInteraction        // Interact freely, advance via coaching button
        case pressKeyboardShortcut(input: String, modifiers: UIKeyModifierFlags) // Press a specific key combo
    }

    enum ButtonStyle: String {
        case next    = "next"
        case tryIt   = "tryIt"
        case gotIt   = "gotIt"

        var title: String {
            switch self {
            case .next:  return L10n.Tutorial.next
            case .tryIt: return L10n.Tutorial.tryIt
            case .gotIt: return L10n.Tutorial.gotIt
            }
        }
    }

    let anchorTarget: AnchorTarget
    let messageKey: String
    let buttonStyle: ButtonStyle
    let validAction: ValidAction
    let webViewInteractive: Bool    // Whether WebView is touchable during this step

    init(anchorTarget: AnchorTarget, messageKey: String,
         buttonStyle: ButtonStyle, validAction: ValidAction,
         webViewInteractive: Bool = false) {
        self.anchorTarget = anchorTarget
        self.messageKey = messageKey
        self.buttonStyle = buttonStyle
        self.validAction = validAction
        self.webViewInteractive = webViewInteractive
    }
}

// MARK: - Steps Per Level

extension TutorialLevel {

    /// Ordered coaching steps for this level.
    var steps: [TutorialStep] {
        switch self {

        // ── Hands-on: Zoom & Layout ──
        case .zoomAndLayout:
            return [
                TutorialStep(
                    anchorTarget: .zoomControls,
                    messageKey: "zoomAndLayout.step1",
                    buttonStyle: .next,
                    validAction: .tapCoachingButton
                ),
                TutorialStep(
                    anchorTarget: .zoomControls,
                    messageKey: "zoomAndLayout.step2",
                    buttonStyle: .gotIt,
                    validAction: .tapZoomControl
                ),
            ]

        // ── Hands-on: Enhance Dark Mode ──
        case .enhanceDarkMode:
            return [
                TutorialStep(
                    anchorTarget: .moonButton,
                    messageKey: "enhanceDarkMode.step1",
                    buttonStyle: .next,
                    validAction: .tapCoachingButton
                ),
                TutorialStep(
                    anchorTarget: .moonButton,
                    messageKey: "enhanceDarkMode.step2",
                    buttonStyle: .tryIt,
                    validAction: .tapMoonButton
                ),
                TutorialStep(
                    anchorTarget: .center,
                    messageKey: "enhanceDarkMode.step3",
                    buttonStyle: .gotIt,
                    validAction: .freeInteraction
                ),
            ]

        // ── Hands-on: Bookmarks ──
        case .bookmarks:
            return [
                TutorialStep(
                    anchorTarget: .webViewCenter,
                    messageKey: "bookmarks.step1",
                    buttonStyle: .next,
                    validAction: .tapCoachingButton
                ),
                TutorialStep(
                    anchorTarget: .bookmarkButton,
                    messageKey: "bookmarks.step2",
                    buttonStyle: .tryIt,
                    validAction: .tapBookmark
                ),
                TutorialStep(
                    anchorTarget: .bookmarkButton,
                    messageKey: "bookmarks.step3",
                    buttonStyle: .gotIt,
                    validAction: .tapCoachingButton
                ),
            ]

        // ── Hands-on: Jump Search ──
        case .jumpSearch:
            return [
                TutorialStep(
                    anchorTarget: .webViewCenter,
                    messageKey: "jumpSearch.step1",
                    buttonStyle: .next,
                    validAction: .tapCoachingButton
                ),
                TutorialStep(
                    anchorTarget: .webViewCenter,
                    messageKey: "jumpSearch.step2",
                    buttonStyle: .tryIt,
                    validAction: .tapJumpSearch,
                    webViewInteractive: true
                ),
                TutorialStep(
                    anchorTarget: .center,
                    messageKey: "jumpSearch.step3",
                    buttonStyle: .gotIt,
                    validAction: .tapCoachingButton
                ),
            ]

        // ── Hands-on: Find in Page ──
        case .findInPage:
            return [
                TutorialStep(
                    anchorTarget: .findButton,
                    messageKey: "findInPage.step1",
                    buttonStyle: .next,
                    validAction: .tapCoachingButton
                ),
                TutorialStep(
                    anchorTarget: .findButton,
                    messageKey: "findInPage.step2",
                    buttonStyle: .tryIt,
                    validAction: .tapFindButton
                ),
                TutorialStep(
                    anchorTarget: .center,
                    messageKey: "findInPage.step3",
                    buttonStyle: .gotIt,
                    validAction: .freeInteraction
                ),
            ]

        // ── Feature Guides (all use tapCoachingButton) ──

        case .lookupBasics:
            return [
                TutorialStep(anchorTarget: .wordListClipboard, messageKey: "lookupBasics.step1",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                TutorialStep(anchorTarget: .wordListSearchBar, messageKey: "lookupBasics.step2",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                TutorialStep(anchorTarget: .wordListRelatedForms, messageKey: "lookupBasics.step3",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                TutorialStep(anchorTarget: .wordListSuggestions, messageKey: "lookupBasics.step4",
                             buttonStyle: .gotIt, validAction: .tapCoachingButton),
            ]

        case .popupLookup:
            return [
                TutorialStep(anchorTarget: .center, messageKey: "popupLookup.step1",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                TutorialStep(anchorTarget: .center, messageKey: "popupLookup.step2",
                             buttonStyle: .gotIt, validAction: .tapCoachingButton),
            ]

        case .dictionaryGroups:
            return [
                // Step 0: Highlight "Japanese" user group — explain concept
                TutorialStep(anchorTarget: .sidebarUserGroup, messageKey: "dictionaryGroups.step1",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                // Step 1: Highlight expanded group + its dict children
                TutorialStep(anchorTarget: .sidebarUserGroupContent, messageKey: "dictionaryGroups.step2",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                // Step 2: Highlight "Add New Group" cell
                TutorialStep(anchorTarget: .sidebarAddGroup, messageKey: "dictionaryGroups.step3",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                // Step 3: Highlight Edit button → user taps Edit
                TutorialStep(anchorTarget: .sidebarEditButton, messageKey: "dictionaryGroups.step4",
                             buttonStyle: .tryIt, validAction: .tapEditButton),
                // Step 4: Editing mode — highlight "Japanese" group ℹ button → user taps
                TutorialStep(anchorTarget: .sidebarUserGroupInfoButton, messageKey: "dictionaryGroups.step5",
                             buttonStyle: .tryIt, validAction: .tapGroupInfoButton),
                // Step 5: GroupInfoVC — highlight GROUP INFO section
                TutorialStep(anchorTarget: .groupInfoSection, messageKey: "dictionaryGroups.step6",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                // Step 6: Highlight Edit button in GroupInfoVC nav bar
                TutorialStep(anchorTarget: .groupInfoEditButton, messageKey: "dictionaryGroups.step7",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                // Step 7: Highlight "Contained Items" → user taps
                TutorialStep(anchorTarget: .groupInfoContainedItems, messageKey: "dictionaryGroups.step8",
                             buttonStyle: .tryIt, validAction: .tapContainedItems),
                // Step 8: GroupDictEditorVC overview
                TutorialStep(anchorTarget: .center, messageKey: "dictionaryGroups.step9",
                             buttonStyle: .gotIt, validAction: .tapCoachingButton),
            ]

        case .importAndResources:
            return [
                // Step 0: Show Management list, highlight "Import Dictionary" (explain only)
                TutorialStep(anchorTarget: .mgmtImportCell, messageKey: "importAndResources.step1",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                // Step 1: Show sidebar with fake dicts, highlight Edit button
                TutorialStep(anchorTarget: .sidebarEditButton, messageKey: "importAndResources.step2",
                             buttonStyle: .tryIt, validAction: .tapEditButton),
                // Step 2: Editing mode, highlight WordNet's info button
                TutorialStep(anchorTarget: .sidebarDictInfoButton, messageKey: "importAndResources.step3",
                             buttonStyle: .tryIt, validAction: .tapDictInfoButton),
                // Step 3: DictInfoVC overview — highlight custom name, explain fields
                TutorialStep(anchorTarget: .center, messageKey: "importAndResources.step4",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                // Step 4: Highlight "Manage Resources" row
                TutorialStep(anchorTarget: .dictInfoManageResources, messageKey: "importAndResources.step5",
                             buttonStyle: .tryIt, validAction: .tapManageResources),
                // Step 5: ResourceEditorVC overview
                TutorialStep(anchorTarget: .center, messageKey: "importAndResources.step6",
                             buttonStyle: .next, validAction: .tapCoachingButton),
                // Step 6: Highlight "Add MDD File"
                TutorialStep(anchorTarget: .resourceEditorAddMDD, messageKey: "importAndResources.step7",
                             buttonStyle: .tryIt, validAction: .tapAddMDD),
            ]

        case .iPadProductivity:
            var steps = [
                TutorialStep(anchorTarget: .newWindowButton, messageKey: "iPadProductivity.step1",
                             buttonStyle: .next, validAction: .tapCoachingButton),
            ]
            if Self.hasHardwareKeyboard {
                // Quiz: ⌘= (zoom in), ⌘2 (grid layout), ⌃⌥⌘1 (select first dict)
                steps += [
                    TutorialStep(anchorTarget: .center, messageKey: "iPadProductivity.keyboardIntro",
                                 buttonStyle: .next, validAction: .tapCoachingButton),
                    TutorialStep(anchorTarget: .center, messageKey: "iPadProductivity.quizZoom",
                                 buttonStyle: .tryIt,
                                 validAction: .pressKeyboardShortcut(input: "=", modifiers: .command)),
                    TutorialStep(anchorTarget: .center, messageKey: "iPadProductivity.quizGrid",
                                 buttonStyle: .tryIt,
                                 validAction: .pressKeyboardShortcut(input: "2", modifiers: .command)),
                    TutorialStep(anchorTarget: .center, messageKey: "iPadProductivity.quizDict",
                                 buttonStyle: .tryIt,
                                 validAction: .pressKeyboardShortcut(input: "1", modifiers: [.control, .alternate, .command])),
                ]
            } else {
                steps.append(
                    TutorialStep(anchorTarget: .center, messageKey: "iPadProductivity.noKeyboard",
                                 buttonStyle: .gotIt, validAction: .tapCoachingButton)
                )
            }
            return steps
        }
    }
}
