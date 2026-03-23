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
        articlePageView.onJumpSearch = { [weak self] selectedText in
            _ = selectedText
            self?.handleUserAction(.tapJumpSearch)
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

        // Pass through spotlight touches when step expects a target tap
        let passThrough: Bool
        switch step.validAction {
        case .tapBookmark, .tapMoonButton, .tapFindButton, .tapZoomControl, .tapJumpSearch:
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
            self.showCurrentStep()
        }
    }

    private func completeTutorial() {
        TutorialProgressService.markCompleted(level)
        articlePageView.webView.isUserInteractionEnabled = true

        // Dismiss find navigator if open
        if #available(iOS 16.0, *) {
            articlePageView.dismissFind()
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
            isCelebration: true
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

        case .webViewCenter:
            return articlePageView.webView.convert(
                articlePageView.webView.bounds, to: view
            )

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
