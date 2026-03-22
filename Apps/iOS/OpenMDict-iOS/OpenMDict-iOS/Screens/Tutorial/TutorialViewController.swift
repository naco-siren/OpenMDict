//
//  TutorialViewController.swift
//  OpenMDict-iOS
//
//  Interactive tutorial VC hosting a single ArticlePageView with coaching mark
//  overlay. Shows ALL header actions (just like the real app) and validates
//  user interactions per step — correct actions advance, wrong actions alert.
//
//  Nav bar includes mock zoom controls (matching DetailContainerVC layout)
//  so "Zoom & Layout" tutorials feel consistent with the real experience.
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

    // Nav bar zoom items (mock)
    private weak var zoomInItem: UIBarButtonItem?
    private weak var zoomOutItem: UIBarButtonItem?

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

        // Custom back button for exit confirmation
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain,
            target: self,
            action: #selector(backTapped)
        )

        setupZoomBarItems()
        setupArticlePageView()
        loadTutorialArticle()
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
            // Tutorial not complete — confirm exit
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

    // MARK: - Zoom Bar Items (Mock)

    private func setupZoomBarItems() {
        guard level.isInteractive else { return }

        let zoomOut = UIBarButtonItem(
            image: UIImage(systemName: "minus.magnifyingglass"),
            style: .plain,
            target: self,
            action: #selector(zoomControlTapped)
        )
        let zoomIn = UIBarButtonItem(
            image: UIImage(systemName: "plus.magnifyingglass"),
            style: .plain,
            target: self,
            action: #selector(zoomControlTapped)
        )
        zoomOutItem = zoomOut
        zoomInItem = zoomIn
        navigationItem.rightBarButtonItems = [zoomIn, zoomOut]
    }

    @objc private func zoomControlTapped() {
        handleUserAction(.tapZoomControl)
    }

    // MARK: - Article Setup

    private func setupArticlePageView() {
        let webConfig = WKWebViewConfiguration()

        // Show ALL actions for hands-on tutorials (consistent with real app)
        let features: ArticlePageView.Features
        if level.isInteractive {
            features = [.bookmark, .enhanceDarkMode, .findInPage, .jumpSearch, .lookupCount]
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
        articlePageView.onJumpSearch = { [weak self] _ in
            // Jump search in tutorial context: just acknowledge
            self?.handleUserAction(.freeInteraction)
        }

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

    // MARK: - Action Validation

    /// Central handler for all user interactions. Validates against the current
    /// step's `validAction` — advances on correct, alerts on wrong.
    private func handleUserAction(_ action: TutorialStep.ValidAction) {
        guard currentStepIndex < steps.count else { return }
        let step = steps[currentStepIndex]

        switch step.validAction {
        case .tapCoachingButton:
            // Only the coaching button advances; any toolbar tap is "wrong"
            showWrongActionAlert(for: step)

        case .freeInteraction:
            // Any interaction is fine during free interaction — don't alert
            break

        default:
            if action == step.validAction {
                // Correct action! Advance.
                advanceStep()
            } else {
                showWrongActionAlert(for: step)
            }
        }
    }

    private func showWrongActionAlert(for step: TutorialStep) {
        let targetName: String
        switch step.validAction {
        case .tapBookmark:      targetName = L10n.Tutorial.wrongActionBookmark
        case .tapMoonButton:    targetName = L10n.Tutorial.wrongActionMoon
        case .tapFindButton:    targetName = L10n.Tutorial.wrongActionFind
        case .tapZoomControl:   targetName = L10n.Tutorial.wrongActionZoom
        case .tapCoachingButton, .freeInteraction:
            return // Never alert for these
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
        articlePageView.webView.isUserInteractionEnabled = step.webViewInteractive

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

        mark.configure(with: .init(
            message: message,
            buttonTitle: step.buttonStyle.title,
            spotlightFrame: spotlightFrame,
            arrowDirection: arrowDirection,
            stepText: stepText
        ))

        mark.onAction = { [weak self] in
            guard let self else { return }
            let currentStep = self.steps[self.currentStepIndex]
            switch currentStep.validAction {
            case .tapCoachingButton, .freeInteraction:
                self.advanceStep()
            default:
                // Coaching button not the valid action — do nothing,
                // wait for the correct toolbar interaction
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
            self.showCurrentStep()
        }
    }

    private func completeTutorial() {
        TutorialProgressService.markCompleted(level)

        // Re-enable WebView before leaving
        articlePageView.webView.isUserInteractionEnabled = true

        navigationController?.popViewController(animated: true)
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
            // Spotlight the zoom bar button items in the nav bar
            if let navBar = navigationController?.navigationBar {
                // Try to find the zoom button views
                if let zoomInView = zoomInItem?.value(forKey: "view") as? UIView,
                   let zoomOutView = zoomOutItem?.value(forKey: "view") as? UIView {
                    let inFrame = zoomInView.convert(zoomInView.bounds, to: view)
                    let outFrame = zoomOutView.convert(zoomOutView.bounds, to: view)
                    return inFrame.union(outFrame)
                }
                // Fallback: right portion of nav bar
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

        case .webViewCenter:
            return articlePageView.webView.convert(
                articlePageView.webView.bounds, to: view
            )

        case .center:
            return nil
        }
    }

    /// Recursively find a UIButton whose SF Symbol name contains the given prefix.
    private func findButton(withSymbol symbolPrefix: String, in parentView: UIView) -> UIButton? {
        for subview in parentView.subviews {
            if let button = subview as? UIButton {
                // Check UIButton.Configuration image
                if let config = button.configuration,
                   let img = config.image,
                   img.description.contains(symbolPrefix) {
                    return button
                }
                // Fallback: check currentImage
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

    /// Fallback English messages for each step key.
    private func defaultMessage(for key: String) -> String {
        switch key {

        // ── Hands-on: Zoom & Layout ──
        case "zoomAndLayout.step1":
            return "You can adjust the text size using the zoom controls in the toolbar above."
        case "zoomAndLayout.step2":
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
            return "Type a word to highlight all matches. Use the arrows to navigate between them."

        // ── Guide: Lookup Basics ──
        case "lookupBasics.step1":
            return "Before you type anything, the word list shows your clipboard content and recent lookup history for quick access."
        case "lookupBasics.step2":
            return "Type a word to see instant search results. Tap any result to view full articles from all your dictionaries."
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
            return "Import MDX dictionary files via the Files app, AirDrop, or the \"Import Dictionary\" button. OpenMDict indexes them automatically."
        case "importAndResources.step2":
            return "For dictionaries with custom styling, you can manage CSS and JavaScript resources in the dictionary settings to fine-tune the display."

        // ── Guide: iPad Productivity ──
        case "iPadProductivity.step1":
            return "On iPad, use Split View or Slide Over to look up words while reading in another app. Open multiple OpenMDict windows for side-by-side dictionary comparison."
        case "iPadProductivity.step2":
            return "Physical keyboard shortcuts speed up your workflow: ⌘F for Find in Page, ⌘+/⌘− for Zoom, and arrow keys to navigate search results."

        default:
            return key
        }
    }
}
