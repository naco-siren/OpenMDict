//
//  TutorialViewController.swift
//  OpenMDict-iOS
//
//  Interactive tutorial VC hosting a single ArticlePageView with coaching mark
//  overlay. Shows ALL header actions (just like the real app) and validates
//  user interactions per step — correct actions advance, wrong actions alert.
//
//  Mocks real state changes: bookmark toggle, zoom scaling, dark mode
//  force-dark, find-in-page with target word. Nav bar includes zoom controls
//  matching DetailContainerVC (iOS 15 buttons / iOS 16+ slider).
//

import UIKit
import WebKit

final class TutorialViewController: UIViewController {

    // MARK: - Properties

    private let level: TutorialLevel
    private let steps: [TutorialStep]
    private var currentStepIndex = 0
    private var tutorialStarted = false

    private var articlePageView: ArticlePageView!
    private var coachingMark: CoachingMarkView?

    // Zoom state (mock)
    private var zoom = ZoomLevel()
    private weak var zoomSlider: UISlider?
    private weak var zoomInItem: UIBarButtonItem?
    private weak var zoomOutItem: UIBarButtonItem?
    private weak var zoomResetItem: UIBarButtonItem?

    // Bookmark state (mock)
    private var isBookmarked = false

    // MARK: - Init

    init(level: TutorialLevel) {
        self.level = level
        self.steps = level.steps
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = level.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        // Force dark appearance for Enhance Dark Mode tutorial
        if level == .enhanceDarkMode {
            overrideUserInterfaceStyle = .dark
        }

        // Custom back button for exit confirmation
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain,
            target: self,
            action: #selector(backTapped)
        )

        if level.usesArticlePageView {
            setupZoomBarItems()
            setupArticlePageView()
            loadTutorialArticle()
        } else {
            setupGuideContentView()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !tutorialStarted else { return }
        tutorialStarted = true

        // Show first coaching mark after a brief delay for the article to render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showCurrentStep()
        }
    }

    // MARK: - Exit Confirmation

    @objc private func backTapped() {
        if currentStepIndex < steps.count {
            let alert = UIAlertController(
                title: L10n.Tutorial.exitTitle,
                message: L10n.Tutorial.exitMessage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.Tutorial.exitConfirm, style: .destructive) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            })
            alert.addAction(UIAlertAction(title: L10n.Tutorial.exitCancel, style: .cancel))
            present(alert, animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    // MARK: - Zoom Bar Items (matches DetailContainerVC)

    private func setupZoomBarItems() {
        guard level.isInteractive else { return }

        if #available(iOS 16.0, *) {
            // iOS 16+: slider in nav bar (same as DetailContainerVC)
            let sliderContainer = makeZoomSliderContainer()
            let sliderItem = UIBarButtonItem(customView: sliderContainer)
            navigationItem.rightBarButtonItems = [sliderItem]
        } else {
            // iOS 15: +/- buttons with reset in the middle
            let out = UIBarButtonItem(
                image: UIImage(systemName: "minus.magnifyingglass"),
                style: .plain, target: self, action: #selector(zoomOutTapped)
            )
            let reset = UIBarButtonItem(
                title: zoom.displayString,
                style: .plain, target: self, action: #selector(zoomResetTapped)
            )
            let zIn = UIBarButtonItem(
                image: UIImage(systemName: "plus.magnifyingglass"),
                style: .plain, target: self, action: #selector(zoomInTapped)
            )
            zoomOutItem = out
            zoomResetItem = reset
            zoomInItem = zIn
            out.isEnabled = zoom.canZoomOut
            reset.isEnabled = !zoom.isDefault
            navigationItem.rightBarButtonItems = [zIn, reset, out]
        }
    }

    @available(iOS 16.0, *)
    private func makeZoomSliderContainer() -> UIView {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = Float(ZoomLevel.levels.count - 1)
        slider.value = Float(ZoomLevel.levels.firstIndex(of: zoom.current) ?? 2)
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(zoomSliderChanged(_:)), for: .valueChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        self.zoomSlider = slider

        let smallerIcon = UIImageView(image: UIImage(systemName: "textformat.size.smaller"))
        smallerIcon.tintColor = .secondaryLabel
        smallerIcon.contentMode = .scaleAspectFit
        smallerIcon.translatesAutoresizingMaskIntoConstraints = false
        smallerIcon.setContentHuggingPriority(.required, for: .horizontal)

        let largerIcon = UIImageView(image: UIImage(systemName: "textformat.size.larger"))
        largerIcon.tintColor = .secondaryLabel
        largerIcon.contentMode = .scaleAspectFit
        largerIcon.translatesAutoresizingMaskIntoConstraints = false
        largerIcon.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [smallerIcon, slider, largerIcon])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            slider.widthAnchor.constraint(equalToConstant: 140),
            smallerIcon.widthAnchor.constraint(equalToConstant: 16),
            smallerIcon.heightAnchor.constraint(equalToConstant: 16),
            largerIcon.widthAnchor.constraint(equalToConstant: 16),
            largerIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        return stack
    }

    @objc private func zoomSliderChanged(_ sender: UISlider) {
        let index = Int(sender.value.rounded())
        sender.value = Float(index)
        let newLevel = ZoomLevel.levels[index]
        guard newLevel != zoom.current else { return }
        zoom = ZoomLevel(newLevel)
        articlePageView.setZoomLevel(zoom.current)
        handleUserAction(.tapZoomControl)
    }

    @objc private func zoomInTapped() {
        zoom.zoomIn()
        applyZoomState()
        handleUserAction(.tapZoomControl)
    }

    @objc private func zoomOutTapped() {
        zoom.zoomOut()
        applyZoomState()
        handleUserAction(.tapZoomControl)
    }

    @objc private func zoomResetTapped() {
        zoom.reset()
        applyZoomState()
        handleUserAction(.tapZoomControl)
    }

    private func applyZoomState() {
        articlePageView.setZoomLevel(zoom.current)
        // Update iOS 15 button states
        zoomOutItem?.isEnabled = zoom.canZoomOut
        zoomResetItem?.isEnabled = !zoom.isDefault
        zoomResetItem?.title = zoom.displayString
        zoomInItem?.isEnabled = zoom.canZoomIn
    }

    // MARK: - Article Setup

    private func setupArticlePageView() {
        let webConfig = WKWebViewConfiguration()

        // Show ALL actions for hands-on tutorials (consistent with real app)
        var features: ArticlePageView.Features
        if level.isInteractive {
            features = [.bookmark, .enhanceDarkMode, .findInPage, .jumpSearch, .lookupCount]
        } else if level == .iPadProductivity {
            features = [.bookmark, .enhanceDarkMode, .findInPage, .jumpSearch, .lookupCount, .newWindowButton]
        } else {
            features = []
        }

        let config = ArticlePageView.Configuration(
            features: features,
            webViewConfiguration: webConfig,
            headerHeight: 46,
            cornerRadius: 0
        )

        articlePageView = ArticlePageView(configuration: config)
        articlePageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(articlePageView)

        NSLayoutConstraint.activate([
            articlePageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            articlePageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            articlePageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            articlePageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Configure header
        let word = TutorialDictionaryProvider.word(for: level)
        articlePageView.configure(
            word: word,
            dictName: TutorialDictionaryProvider.dictName,
            dictId: TutorialDictionaryProvider.dictId,
            isBookmarked: false
        )

        // Wire up ALL callbacks to route through action validation
        articlePageView.onBookmarkTapped = { [weak self] _ in
            self?.handleUserAction(.tapBookmark)
        }
        articlePageView.onFindTapped = { [weak self] in
            self?.handleUserAction(.tapFindButton)
        }
        articlePageView.onEnhanceDarkModeStrengthChanged = { [weak self] _ in
            self?.handleUserAction(.tapMoonButton)
        }
        articlePageView.onJumpSearch = { [weak self] selectedText in
            _ = selectedText
            self?.handleUserAction(.tapJumpSearch)
        }
        articlePageView.onNewWindowTapped = { /* No-op in tutorial */ }

        // Disable WebView interaction by default
        articlePageView.webView.isUserInteractionEnabled = false
    }

    private func loadTutorialArticle() {
        let word = TutorialDictionaryProvider.word(for: level)
        let html = TutorialDictionaryProvider.articleHTML(
            for: word,
            traitCollection: traitCollection
        )
        articlePageView.loadHTMLContent(html)
    }

    // MARK: - Keyboard Event Handling

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard currentStepIndex < steps.count else {
            super.pressesBegan(presses, with: event)
            return
        }

        let step = steps[currentStepIndex]
        guard case .pressKeyboardShortcut(let expectedInput, let expectedMods) = step.validAction else {
            super.pressesBegan(presses, with: event)
            return
        }

        // Extract key info from the press
        guard let press = presses.first, let key = press.key else {
            super.pressesBegan(presses, with: event)
            return
        }

        let inputChar = key.charactersIgnoringModifiers
        let mods = key.modifierFlags.intersection([.command, .alternate, .control, .shift])

        if inputChar == expectedInput && mods == expectedMods {
            // Apply visual feedback for correct shortcut
            if expectedInput == "=" && expectedMods == .command && level.usesArticlePageView {
                zoom.zoomIn()
                applyZoomState()
            }
            advanceStep()
        } else if !inputChar.isEmpty && mods.contains(.command) {
            // User pressed a wrong shortcut — give feedback
            let description = shortcutDescription(input: inputChar, modifiers: mods)
            let alert = UIAlertController(
                title: L10n.Tutorial.wrongActionTitle,
                message: L10n.Tutorial.wrongKeyboardShortcut(description),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.Tutorial.gotIt, style: .default))
            present(alert, animated: true)
        }
        // Don't call super — absorb the key event
    }

    private func shortcutDescription(input: String, modifiers: UIKeyModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.alternate) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        let displayInput: String
        switch input {
        case "=": displayInput = "+"
        case "-": displayInput = "−"
        default: displayInput = input.uppercased()
        }
        parts.append(displayInput)
        return parts.joined()
    }

    // MARK: - Guide Content View (non-ArticlePageView levels)

    private var guideContentView: UIView?
    private weak var embeddedWordListVC: WordListViewController?
    private var mockLookupSession: MockLookupSession?

    private func setupGuideContentView() {
        switch level {
        case .lookupBasics:
            let session = MockLookupSession()
            mockLookupSession = session

            let wordListVC = WordListViewController()
            wordListVC.isTutorialMode = true
            wordListVC.searchSession = session
            // Disable selection callbacks — tutorial is view-only
            wordListVC.onWordSelected = { _ in }

            // Wrap in UINavigationController so UISearchController's search bar
            // appears in the navigation bar (it requires a nav bar host).
            let navWrapper = UINavigationController(rootViewController: wordListVC)
            navWrapper.navigationBar.prefersLargeTitles = false
            navWrapper.isNavigationBarHidden = false

            addChild(navWrapper)
            navWrapper.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(navWrapper.view)
            navWrapper.didMove(toParent: self)
            guideContentView = navWrapper.view
            embeddedWordListVC = wordListVC

            NSLayoutConstraint.activate([
                navWrapper.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                navWrapper.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                navWrapper.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                navWrapper.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

            // Step 0: empty query — WordListVC shows clipboard/history from stub
            session.setStep(0)
            return

        case .importAndResources:
            setupImportAndResourcesGuide()
            return

        default:
            // Other guides (popupLookup, dictionaryGroups)
            let placeholder = UIView()
            placeholder.backgroundColor = .systemGroupedBackground
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(placeholder)
            guideContentView = placeholder

            NSLayoutConstraint.activate([
                placeholder.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                placeholder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                placeholder.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    /// Called by advanceStep to swap guide content between steps.
    /// Returns `true` if a VC was pushed (caller should delay showCurrentStep).
    @discardableResult
    private func updateGuideContentForStep(_ stepIndex: Int) -> Bool {
        // Import & Resources: transition between embedded VCs at specific steps
        if level == .importAndResources {
            switch stepIndex {
            case 1:
                if isImportGuideCompact {
                    // Compact: push sidebar VC (no management section, dicts already expanded)
                    let sidebarVC = makeTutorialSidebar(compactMode: true)
                    embeddedSidebarVC = sidebarVC
                    embeddedGuideNav?.pushViewController(sidebarVC, animated: true)
                    return true
                } else {
                    // Regular: expand "All Dictionaries" on the existing sidebar
                    embeddedSidebarVC?.expandDefaultGroup(animated: true)
                    return false
                }
            case 2:
                // Step 2: Sidebar already in edit mode (user tapped Edit in step 1)
                // Just show coaching mark for info button
                return false
            case 3:
                // Step 3: Push DictInfoVC
                pushDictInfoVC()
                return true
            case 5:
                // Step 5: Push ResourceEditorVC
                pushResourceEditorVC()
                return true
            default:
                return false
            }
        }

        guard level == .lookupBasics, let session = mockLookupSession else { return false }

        let queryText: String
        switch stepIndex {
        case 0: queryText = ""
        case 1: queryText = "Too"
        case 2: queryText = "bombardio"
        case 3: queryText = "Tralalero"
        default: return false
        }

        // Set search bar text (updates displayState)
        embeddedWordListVC?.injectSearchText(queryText)
        // Publish mock data and sync synchronously so section frames
        // are available immediately for coaching mark spotlight
        session.setStep(stepIndex)
        embeddedWordListVC?.syncFromSession()
        return false
    }

    // MARK: - Import & Resources Guide

    private weak var embeddedGuideNav: UINavigationController?
    private weak var embeddedSidebarVC: DictionaryListViewController?
    private weak var embeddedMgmtVC: CompactManagementViewController?
    private weak var embeddedDictInfoVC: DictInfoViewController?
    private weak var embeddedResourceEditorVC: DictResourceEditorViewController?
    private let mockDictDataSource = MockDictManagementDataSource()
    private let mockDictProvider = MockDictionaryDataProvider()
    private let mockMetadataProvider = MockDictMetadataProvider()

    /// Whether the Import & Resources tutorial uses the compact layout
    /// (CompactManagementVC first, then push sidebar without management section).
    /// Uses device idiom instead of traitCollection because the tutorial is
    /// presented as a modal (.formSheet) which always has compact horizontal
    /// size class on iPad.
    private var isImportGuideCompact: Bool {
        UIDevice.current.userInterfaceIdiom != .pad
    }

    private func setupImportAndResourcesGuide() {
        if isImportGuideCompact {
            setupImportGuideCompact()
        } else {
            setupImportGuideRegular()
        }
    }

    /// Regular (iPad): Unified sidebar with "All Dictionaries" + "Management" sections.
    private func setupImportGuideRegular() {
        let sidebarVC = makeTutorialSidebar(compactMode: false)
        sidebarVC.tutorialDefaultGroupCollapsed = true  // Collapsed at step 0, expanded at step 1
        embeddedSidebarVC = sidebarVC

        let navWrapper = UINavigationController(rootViewController: sidebarVC)
        navWrapper.navigationBar.prefersLargeTitles = true
        embeddedGuideNav = navWrapper
        embedGuideNav(navWrapper)

        sidebarVC.view.subviews.compactMap { $0 as? UICollectionView }.first?.isScrollEnabled = false
    }

    /// Compact (iPhone): Start with CompactManagementVC, push sidebar at step 1.
    private func setupImportGuideCompact() {
        let mgmtVC = CompactManagementViewController()
        embeddedMgmtVC = mgmtVC

        // All taps are no-ops — step 0 uses tapCoachingButton
        let noop: () -> Void = {}
        mgmtVC.onImportSelected = noop
        mgmtVC.onAddGroupSelected = noop
        mgmtVC.onDownloadPresetsSelected = noop
        mgmtVC.onChangeAppIconSelected = noop
        mgmtVC.onTroubleshootSelected = noop
        mgmtVC.onAppSettingsSelected = noop
        mgmtVC.onNewUserGuideSelected = noop

        let navWrapper = UINavigationController(rootViewController: mgmtVC)
        navWrapper.navigationBar.prefersLargeTitles = true
        embeddedGuideNav = navWrapper
        embedGuideNav(navWrapper)
    }

    /// Create a tutorial sidebar VC with mock data and wired callbacks.
    private func makeTutorialSidebar(compactMode: Bool) -> DictionaryListViewController {
        let sidebarVC = DictionaryListViewController()
        sidebarVC.dictionaryProvider = mockDictProvider
        sidebarVC.metadataProvider = mockMetadataProvider
        sidebarVC.isTutorialMode = true
        sidebarVC.isCompactSidebarMode = compactMode

        sidebarVC.onEditingChanged = { [weak self] editing in
            guard editing else { return }
            self?.handleUserAction(.tapEditButton)
        }
        sidebarVC.onDictionaryInfoSelected = { [weak self] _ in
            self?.handleUserAction(.tapDictInfoButton)
        }

        // All other callbacks are no-ops
        sidebarVC.onGroupSelected = { _ in }
        sidebarVC.onDictionarySelected = { _ in }
        sidebarVC.onImportDictionarySelected = {}
        sidebarVC.onAddGroupSelected = {}
        sidebarVC.onBookmarksSelected = {}
        sidebarVC.onLookupHistorySelected = {}
        sidebarVC.onManagePresetsSelected = {}
        sidebarVC.onNewUserGuideSelected = {}
        sidebarVC.onChangeAppIconSelected = {}
        sidebarVC.onTroubleshootSelected = {}

        return sidebarVC
    }

    /// Embed a nav controller as the guide content view.
    private func embedGuideNav(_ navWrapper: UINavigationController) {
        addChild(navWrapper)
        navWrapper.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(navWrapper.view)
        navWrapper.didMove(toParent: self)
        guideContentView = navWrapper.view

        NSLayoutConstraint.activate([
            navWrapper.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navWrapper.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navWrapper.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navWrapper.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Push DictInfoVC with mock data onto the embedded nav stack.
    private func pushDictInfoVC() {
        let dictInfoVC = DictInfoViewController()
        dictInfoVC.serviceDataSource = mockDictDataSource
        dictInfoVC.isTutorialMode = true
        dictInfoVC.showEditMode(for: MockDictManagementDataSource.tutorialDictId)
        // "Manage Resources" tap → advance tutorial
        dictInfoVC.onManageResources = { [weak self] _ in
            self?.handleUserAction(.tapManageResources)
        }
        embeddedDictInfoVC = dictInfoVC
        embeddedGuideNav?.pushViewController(dictInfoVC, animated: true)
    }

    /// Push DictResourceEditorVC with mock data onto the embedded nav stack.
    private func pushResourceEditorVC() {
        let editorVC = DictResourceEditorViewController()
        editorVC.serviceDataSource = mockDictDataSource
        editorVC.showEditor(for: MockDictManagementDataSource.tutorialDictId)
        editorVC.onTutorialAddTapped = { [weak self] section in
            guard section == .mdd else { return }
            self?.handleUserAction(.tapAddMDD)
        }
        embeddedResourceEditorVC = editorVC
        embeddedGuideNav?.pushViewController(editorVC, animated: true)
    }

    // MARK: - Action Validation

    private func handleUserAction(_ action: TutorialStep.ValidAction) {
        guard currentStepIndex < steps.count else { return }
        let step = steps[currentStepIndex]

        switch step.validAction {
        case .tapCoachingButton:
            showWrongActionAlert(for: step)

        case .freeInteraction:
            break

        default:
            if action == step.validAction {
                applyMockStateChange(for: action)
                advanceStep()
            } else {
                showWrongActionAlert(for: step)
            }
        }
    }

    /// Update visual state after a correct action (mock the real app behavior).
    private func applyMockStateChange(for action: TutorialStep.ValidAction) {
        switch action {
        case .tapBookmark:
            // Toggle bookmark icon
            isBookmarked.toggle()
            articlePageView.setBookmarked(isBookmarked)

        case .tapMoonButton:
            // The onEnhanceDarkModeStrengthChanged callback fires after the popover
            // already applied the dark mode filter live — no extra work needed here.
            break

        case .tapZoomControl:
            // Zoom already applied in zoomInTapped/zoomSliderChanged
            break

        case .tapFindButton:
            // Open the WKFindInteraction navigator (iOS 16+; iOS 15 blocked at list level)
            if #available(iOS 16.0, *) {
                articlePageView.presentFind()
            }

        case .tapJumpSearch:
            // In tutorial, just acknowledge — no actual cross-dict lookup
            break

        case .pressKeyboardShortcut:
            break  // Handled by pressesBegan

        case .tapImportDictionary:
            break

        case .tapEditButton:
            // Editing mode already toggled by the system edit button
            break

        case .tapDictInfoButton:
            // Info VC will be pushed by updateGuideContentForStep
            break

        case .tapManageResources:
            break

        case .tapAddMDD:
            // No-op — tutorial just congratulates on completion
            break

        case .tapCoachingButton, .freeInteraction:
            break
        }
    }

    private func showWrongActionAlert(for step: TutorialStep) {
        let targetName: String
        switch step.validAction {
        case .tapBookmark:      targetName = L10n.Tutorial.wrongActionBookmark
        case .tapMoonButton:    targetName = L10n.Tutorial.wrongActionMoon
        case .tapFindButton:    targetName = L10n.Tutorial.wrongActionFind
        case .tapZoomControl:   targetName = L10n.Tutorial.wrongActionZoom
        case .tapJumpSearch:    targetName = L10n.Tutorial.wrongActionJumpSearch
        case .tapImportDictionary: targetName = L10n.Tutorial.wrongActionImport
        case .tapEditButton:    targetName = L10n.Tutorial.wrongActionEdit
        case .tapDictInfoButton: targetName = L10n.Tutorial.wrongActionDictInfo
        case .tapManageResources: targetName = L10n.Tutorial.wrongActionManageResources
        case .tapAddMDD:        targetName = L10n.Tutorial.wrongActionAddMDD
        case .pressKeyboardShortcut: return // Handled by pressesBegan
        case .tapCoachingButton, .freeInteraction:
            return
        }

        let alert = UIAlertController(
            title: L10n.Tutorial.wrongActionTitle,
            message: targetName,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Tutorial.gotIt, style: .default))
        present(alert, animated: true)
    }

    // MARK: - Step Progression

    private func showCurrentStep() {
        guard currentStepIndex < steps.count else {
            completeTutorial()
            return
        }

        let step = steps[currentStepIndex]

        // Update WebView interactivity
        if level.usesArticlePageView {
            articlePageView.webView.isUserInteractionEnabled = step.webViewInteractive
        }

        // Remove existing coaching mark
        coachingMark?.removeFromSuperview()

        let mark = CoachingMarkView(frame: view.bounds)
        mark.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(mark)
        coachingMark = mark

        // Resolve anchor frame
        let spotlightFrame = resolveSpotlightFrame(for: step.anchorTarget)

        // Determine arrow direction
        let arrowDirection: CoachingMarkView.ArrowDirection
        if let frame = spotlightFrame {
            arrowDirection = frame.midY < view.bounds.midY ? .up : .down
        } else {
            arrowDirection = .none
        }

        // Step text
        let stepText = L10n.Tutorial.stepOf(currentStepIndex + 1, steps.count)

        // Coaching message
        let message = tutorialStepMessage(for: step.messageKey)

        // Pass through spotlight touches when step expects a target tap
        let passThrough: Bool
        switch step.validAction {
        case .tapBookmark, .tapMoonButton, .tapFindButton, .tapZoomControl, .tapJumpSearch,
             .tapImportDictionary, .tapEditButton, .tapDictInfoButton,
             .tapManageResources, .tapAddMDD:
            passThrough = true
        default:
            passThrough = false
        }

        mark.configure(with: .init(
            message: message,
            buttonTitle: step.buttonStyle.title,
            spotlightFrame: spotlightFrame,
            arrowDirection: arrowDirection,
            stepText: stepText,
            passThroughSpotlight: passThrough
        ))

        mark.onAction = { [weak self] in
            guard let self else { return }
            let currentStep = self.steps[self.currentStepIndex]
            switch currentStep.validAction {
            case .tapCoachingButton, .freeInteraction:
                self.advanceStep()
            default:
                break
            }
        }

        mark.showAnimated()
    }

    private func advanceStep() {
        coachingMark?.hideAnimated { [weak self] in
            guard let self else { return }
            self.coachingMark?.removeFromSuperview()
            self.coachingMark = nil
            self.currentStepIndex += 1
            // Swap guide content if needed (may push a new VC)
            let didPushVC = self.updateGuideContentForStep(self.currentStepIndex)
            if didPushVC {
                // Delay to let the pushed VC's view lay out before resolving spotlight frames
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.showCurrentStep()
                }
            } else {
                self.showCurrentStep()
            }
        }
    }

    private func completeTutorial() {
        TutorialProgressService.markCompleted(level)

        if level.usesArticlePageView {
            articlePageView.webView.isUserInteractionEnabled = true
            if #available(iOS 16.0, *) {
                articlePageView.dismissFind()
            }
        }

        // Show celebration coaching mark
        coachingMark?.removeFromSuperview()
        let mark = CoachingMarkView(frame: view.bounds)
        mark.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(mark)
        coachingMark = mark

        mark.configure(with: .init(
            message: L10n.Tutorial.completionMessage,
            buttonTitle: L10n.Tutorial.completionButton,
            spotlightFrame: nil,
            arrowDirection: .none,
            stepText: nil,
            celebrationTitle: L10n.Tutorial.completionTitle,
            celebrationIcon: "hands.clap"
        ))

        mark.onAction = { [weak self] in
            self?.coachingMark?.hideAnimated {
                self?.navigationController?.popViewController(animated: true)
            }
        }

        mark.showAnimated()
    }

    // MARK: - Spotlight Resolution

    private func resolveSpotlightFrame(for target: TutorialStep.AnchorTarget) -> CGRect? {
        switch target {
        case .headerArea:
            return articlePageView.headerView.convert(
                articlePageView.headerView.bounds, to: view
            )

        case .bookmarkButton:
            if let btn = findButton(withSymbol: "bookmark", in: articlePageView.headerView) {
                return btn.convert(btn.bounds, to: view)
            }
            return articlePageView.headerView.convert(
                articlePageView.headerView.bounds, to: view
            )

        case .moonButton:
            if let btn = findButton(withSymbol: "moon", in: articlePageView.headerView) {
                return btn.convert(btn.bounds, to: view)
            }
            return nil

        case .zoomControls:
            if let navBar = navigationController?.navigationBar {
                if let zoomInView = zoomInItem?.value(forKey: "view") as? UIView,
                   let zoomOutView = zoomOutItem?.value(forKey: "view") as? UIView {
                    let inFrame = zoomInView.convert(zoomInView.bounds, to: view)
                    let outFrame = zoomOutView.convert(zoomOutView.bounds, to: view)
                    return inFrame.union(outFrame)
                }
                // iOS 16+ slider: spotlight the right bar items area
                if let sliderView = zoomSlider?.superview {
                    return sliderView.convert(sliderView.bounds, to: view)
                }
                let navFrame = navBar.convert(navBar.bounds, to: view)
                return CGRect(x: navFrame.midX, y: navFrame.minY,
                              width: navFrame.width / 2, height: navFrame.height)
            }
            return nil

        case .findButton:
            if let btn = findButton(withSymbol: "magnifyingglass", in: articlePageView.headerView) {
                return btn.convert(btn.bounds, to: view)
            }
            return nil

        case .newWindowButton:
            if let btn = findButton(withSymbol: "rectangle.badge.plus", in: articlePageView.headerView) {
                return btn.convert(btn.bounds, to: view)
            }
            return nil

        case .webViewCenter:
            return articlePageView.webView.convert(
                articlePageView.webView.bounds, to: view
            )

        case .guideContent:
            if let gv = guideContentView {
                return gv.convert(gv.bounds, to: view)
            }
            return nil

        case .wordListClipboard:
            return embeddedWordListVC?.sectionFrame(matching: .clipboard, in: view)

        case .wordListSearchBar:
            return embeddedWordListVC?.searchBarFrame(in: view)

        case .wordListRelatedForms:
            if var frame = embeddedWordListVC?.sectionFrame(matching: .relatedForms, in: view) {
                // Extend bottom edge for more breathing room below the last row
                frame.size.height += 40
                return frame
            }
            return nil

        case .wordListSuggestions:
            return embeddedWordListVC?.sectionFrame(matching: .suggestions, in: view)

        case .mgmtImportCell:
            if isImportGuideCompact {
                // Compact: find "Import Dictionary" in CompactManagementVC
                guard let mgmtVC = embeddedMgmtVC,
                      let cv = mgmtVC.view.subviews.compactMap({ $0 as? UICollectionView }).first else { return nil }
                // "Import Dictionary" is item index 1 in section 0
                let indexPath = IndexPath(item: 1, section: 0)
                guard let cell = cv.cellForItem(at: indexPath) else { return nil }
                return cell.convert(cell.bounds, to: view)
            } else {
                // Regular: find "Import Dictionary" management action in the sidebar
                guard let sidebarVC = embeddedSidebarVC,
                      let cv = sidebarVC.view.subviews.compactMap({ $0 as? UICollectionView }).first else { return nil }
                for cell in cv.visibleCells where cell is ManagementActionCell {
                    if let actionCell = cell as? ManagementActionCell,
                       actionCell.item == .mgmtImportDictionary {
                        return cell.convert(cell.bounds, to: view)
                    }
                }
                return nil
            }

        case .sidebarEditButton:
            guard let sidebarVC = embeddedSidebarVC,
                  let editItem = sidebarVC.navigationItem.rightBarButtonItem,
                  let editView = editItem.value(forKey: "view") as? UIView else { return nil }
            return editView.convert(editView.bounds, to: view)

        case .sidebarDictInfoButton:
            // Highlight the first dict cell (WordNet) in edit mode — user taps its ℹ️ button
            guard let sidebarVC = embeddedSidebarVC,
                  let cv = sidebarVC.view.subviews.compactMap({ $0 as? UICollectionView }).first else { return nil }
            // The first dict cell is a DefaultGroupDictCell
            for cell in cv.visibleCells where cell is DefaultGroupDictCell {
                return cell.convert(cell.bounds, to: view)
            }
            return nil

        case .dictInfoManageResources:
            guard let dictInfoVC = embeddedDictInfoVC,
                  let cv = dictInfoVC.view.subviews.compactMap({ $0 as? UICollectionView }).first else { return nil }
            // "Manage Resources" is item 0 in section 0 (first section in viewing mode)
            let indexPath = IndexPath(item: 0, section: 0)
            guard let cell = cv.cellForItem(at: indexPath) else { return nil }
            return cell.convert(cell.bounds, to: view)

        case .resourceEditorAddMDD:
            guard let editorVC = embeddedResourceEditorVC,
                  let cv = editorVC.view.subviews.compactMap({ $0 as? UICollectionView }).first else { return nil }
            // "Add MDD" is the last item in the MDD section (section 1: MDX=0, MDD=1)
            let mddSection = 1
            let itemCount = cv.numberOfItems(inSection: mddSection)
            guard itemCount > 0 else { return nil }
            let lastItem = IndexPath(item: itemCount - 1, section: mddSection)
            guard let cell = cv.cellForItem(at: lastItem) else { return nil }
            return cell.convert(cell.bounds, to: view)

        case .center:
            return nil
        }
    }

    private func findButton(withSymbol symbolPrefix: String, in parentView: UIView) -> UIButton? {
        for subview in parentView.subviews {
            if let button = subview as? UIButton {
                if let config = button.configuration,
                   let img = config.image,
                   img.description.contains(symbolPrefix) {
                    return button
                }
                if let img = button.currentImage,
                   img.description.contains(symbolPrefix) {
                    return button
                }
            }
            if let found = findButton(withSymbol: symbolPrefix, in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Step Messages

    private func tutorialStepMessage(for key: String) -> String {
        let fullKey = "tutorial.step.\(key)"
        return NSLocalizedString(fullKey, value: defaultMessage(for: key),
                                 comment: "Tutorial coaching step message")
    }

    private func defaultMessage(for key: String) -> String {
        switch key {

        // ── Hands-on: Zoom & Layout ──
        case "zoomAndLayout.step1":
            return "You can adjust the text size using the zoom controls in the toolbar above."
        case "zoomAndLayout.step2":
            if #available(iOS 16.0, *) {
                return "Try dragging the slider to change the text size."
            }
            return "Try tapping a zoom button to change the text size."

        // ── Hands-on: Enhance Dark Mode ──
        case "enhanceDarkMode.step1":
            return "The moon button lets you enhance readability in dark mode for each dictionary."
        case "enhanceDarkMode.step2":
            return "Tap the highlighted moon button to open the adjustment panel."
        case "enhanceDarkMode.step3":
            return "Adjust the slider to find the perfect brightness. Each dictionary can have its own setting."

        // ── Hands-on: Bookmarks ──
        case "bookmarks.step1":
            return "This is a dictionary article. You can bookmark any article to save it for later."
        case "bookmarks.step2":
            return "Tap the highlighted bookmark button to save this article."
        case "bookmarks.step3":
            return "Great! The article is now bookmarked. You can find all your bookmarks in the Bookmarks tab."

        // ── Hands-on: Jump Search ──
        case "jumpSearch.step1":
            return "When reading an article, you can look up any word by selecting it."
        case "jumpSearch.step2":
            return "Long-press on a word to select it, then choose \"Jump Search\" from the context menu."
        case "jumpSearch.step3":
            return "Jump Search will look up the selected word across all your dictionaries — it's like having a dictionary within a dictionary!"

        // ── Hands-on: Find in Page ──
        case "findInPage.step1":
            return "The find button lets you search for specific text within an article."
        case "findInPage.step2":
            return "Tap the highlighted find button to open the search bar."
        case "findInPage.step3":
            return "Try searching for \"definition\" — you'll see all matches highlighted. Use the arrows to navigate between them."

        // ── Guide: Lookup Basics ──
        case "lookupBasics.step1":
            return "Before you type anything, the word list shows your clipboard content and recent lookup history for quick access."
        case "lookupBasics.step2":
            return "As you type, you'll see the results in real time. Tap any result to view full articles from all your dictionaries."
        case "lookupBasics.step3":
            return "OpenMDict automatically finds related forms — so searching for \"running\" also finds \"run\". Great for conjugations and inflections!"
        case "lookupBasics.step4":
            return "If your query has a typo or too few direct matches, suggestions appear to help you find the right word through fuzzy matching."

        // ── Guide: Pop-up Lookup ──
        case "popupLookup.step1":
            return "Pop-up Lookup lets you look up words from any app without leaving it. Select text, tap Share, and choose OpenMDict."
        case "popupLookup.step2":
            return "The lookup result appears in a compact overlay. You can browse articles, bookmark entries, and even adjust dark mode — all without switching apps."

        // ── Guide: Dictionary Groups ──
        case "dictionaryGroups.step1":
            return "Groups let you organize your dictionaries by topic or language — for example, \"English\", \"Japanese\", or \"Medical\"."
        case "dictionaryGroups.step2":
            return "Create groups in the sidebar or Management tab. Drag dictionaries between groups to organize them."

        // ── Guide: MDX Import & Resources ──
        case "importAndResources.step1":
            return "\"Import Dictionary\" lets you add MDX dictionary files — via the Files app, AirDrop, or directly from this button."
        case "importAndResources.step2":
            return "Tap the Edit button in the navigation bar to manage your imported dictionaries."
        case "importAndResources.step3":
            return "Tap the ℹ button on WordNet to view and edit its dictionary info."
        case "importAndResources.step4":
            return "This is the dictionary info screen. You can see metadata, lookup and bookmark counts, and customize the display name."
        case "importAndResources.step5":
            return "Tap \"Manage Resources\" to add supplementary files like MDD, CSS, or JavaScript."
        case "importAndResources.step6":
            return "The resource editor shows all files associated with this dictionary. MDD files contain images and audio, while CSS and JS customize the article appearance."
        case "importAndResources.step7":
            return "Tap \"Add MDD File\" to attach a resource archive. This is how you add pronunciation audio, images, or other media."

        // ── Guide: iPad Productivity ──
        case "iPadProductivity.step1":
            return "Tap this button to open the current article in a new window. You can also long-press any search result to find the same option — great for comparing definitions side by side."

        // With keyboard: quiz flow
        case "iPadProductivity.keyboardIntro":
            if #available(iOS 26, *) {
                return "You have a keyboard connected! Check the menus in the menu bar at the top of the screen to discover all available shortcuts. Let's practice a few:"
            } else {
                return "You have a keyboard connected! Hold down the ⌘ key to see all available shortcuts at a glance. Let's practice a few:"
            }
        case "iPadProductivity.quizZoom":
            if #available(iOS 26, *) {
                return "Find the shortcut for \"Zoom In\" in the menu bar, then press it."
            } else {
                return "Hold ⌘ to open the cheat sheet, find the shortcut for \"Zoom In\", then press it."
            }
        case "iPadProductivity.quizGrid":
            if #available(iOS 26, *) {
                return "Well done! Shortcuts let you quickly switch between different layouts on iPad. Now find and press the shortcut for \"Grid Layout\"."
            } else {
                return "Well done! Shortcuts let you quickly switch between different layouts on iPad. Now find and press the shortcut for \"Grid Layout\"."
            }
        case "iPadProductivity.quizDict":
            if #available(iOS 26, *) {
                return "Excellent! Bonus challenge: shortcuts are particularly useful for selecting a specific dictionary or group. Find and press the shortcut for \"Dictionary 1\"."
            } else {
                return "Excellent! Bonus challenge: shortcuts are particularly useful for selecting a specific dictionary or group. Find and press the shortcut for \"Dictionary 1\"."
            }

        // Without keyboard
        case "iPadProductivity.noKeyboard":
            if #available(iOS 26, *) {
                return "When you connect a physical keyboard, check the menus in the menu bar at the top of the screen to discover all available keyboard shortcuts — from zooming and finding text to switching layouts and managing windows."
            } else {
                return "When you connect a physical keyboard, hold down the ⌘ key to reveal a cheat sheet of all available keyboard shortcuts — from zooming and finding text to switching layouts and managing windows."
            }

        default:
            return key
        }
    }

}
