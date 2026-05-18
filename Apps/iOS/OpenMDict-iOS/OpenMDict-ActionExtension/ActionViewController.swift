//
//  ActionViewController.swift
//  OpenMDict-ActionExtension
//
//  Action Extension entry point. Presents a half-screen sheet showing
//  dictionary definitions for the user-selected text.
//
//  Architecture:
//  - Scans all user dictionaries sequentially (one MDX reader at a time)
//  - Extracts article HTML into Sendable value types, releases reader immediately
//  - Streams results into a horizontal pager (UIScrollView + WKWebViews)
//  - MDD resources pre-extracted to disk cache, served via scheme handler
//  - Audio playback via AVAudioPlayer (on-demand MDD extraction)
//  - Entry links show confirmation alert → open main app with direct article URL
//

import AVFoundation
import Combine
import UIKit
import WebKit
import CoreData
import OpenMDict

// MARK: - ArticleResult

/// Sendable value type — does not hold any reader reference.
/// Extracted during scan, displayed in pager after reader is released.
private struct ArticleResult: Sendable {
    let dictId: String
    let dictName: String
    let keyword: String         // Original keyword preserving case (e.g., "Job" vs "job")
    let html: String            // Article HTML extracted during scan
    let resolvedFrom: String?   // Original query when found via lemma (e.g. "books" when keyword is "book")
}

// MARK: - ActionViewController

class ActionViewController: UIViewController {

    // MARK: - Pages

    private var pages: [ArticlePageView] = []
    private var pageLeadingConstraints: [NSLayoutConstraint] = []
    private var isBookmarked = false

    // MARK: - Pager UI

    /// Container for loading/error states — removed when pager is displayed.
    private var statusContainerView: UIView?

    /// Horizontal pager container.
    private var scrollView: UIScrollView?

    /// Page indicator (hidden when only 1 result).
    private var pageControl: UIPageControl?

    /// Translucent backdrop behind page control dots.
    private var pageControlBackdrop: UIVisualEffectView?

    /// Spinner shown next to page control while scan is in progress.
    private var scanSpinner: UIActivityIndicatorView?

    /// Shared WKWebView configuration (no scheme handler — pure HTML).
    private var webViewConfiguration: WKWebViewConfiguration?

    // MARK: - Nav Bar Items

    private var appearanceButton: UIBarButtonItem?
    private weak var appearanceSegmentedControl: UISegmentedControl?
    private var zoomInButton: UIBarButtonItem?       // iOS 15 individual zoom-in
    private var zoomOutButton: UIBarButtonItem?      // iOS 15 individual zoom-out
    private var zoomResetButton: UIBarButtonItem?    // iOS 15 reset zoom

    // iOS 16+ stored refs for in-place zoom updates (avoids full nav bar rebuild)
    private weak var zoomSlider: UISlider?
    private weak var zoomRepresentativeItem: UIBarButtonItem?

    // MARK: - State

    /// The word/phrase selected by the user.
    private var selectedText: String = ""

    /// All article results from scanning all dictionaries.
    private var results: [ArticleResult] = []

    /// Maximum number of articles to display, based on device RAM and user setting.
    private let articlesCapacityLimit: Int = UserDefaults.shared.articlesCapacity.limit

    /// Currently visible page index.
    private var currentPageIndex: Int = 0

    /// Number of dictionaries searched (for "in your top N dictionaries" message).
    private var searchedDictCount: Int = 0

    /// Spelling suggestions accumulated during scan (used when no articles found).
    private var collectedSuggestions: [ScoredSuggestion] = []

    /// Deduplicated + sorted suggestions for the table view data source.
    private var displaySuggestions: [ScoredSuggestion] = []

    /// Suggestions table view (shown when no articles found but suggestions exist).
    private var suggestionsTableView: UITableView?

    /// Zoom level for article text.  Seeded from the persisted level when the
    /// user has the Remember Zoom Level toggle on; otherwise starts at default.
    ///
    /// The Action Extension is a narrow single-pane sheet, so it shares the
    /// `compact` persisted key with `CompactTabBarController.lookupDetailContainer`
    /// — both contexts feel the same to the user.
    private var zoom = ZoomLevel(UserDefaults.shared.initialZoomLevel(compact: true))

    /// Appearance mode (light/dark/auto) — reads from App Group shared defaults.
    private var appearanceMode: AppearanceMode = UserDefaults.shared.appearanceMode

    /// Lookup count Combine subscription.
    private var lookupCountCancellable: AnyCancellable?

    /// Audio player — kept alive for the duration of playback.
    private var audioPlayer: AVAudioPlayer?

    /// Root URL for dictionaries in the App Group shared container.
    private nonisolated static let dictionariesRoot: URL = {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier
        ) else {
            fatalError("App Group container unavailable — check Signing & Capabilities → App Groups")
        }
        return groupURL.appendingPathComponent("Library/Dictionaries", isDirectory: true)
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Bootstrap the shared OpenMDict sidecar index cache (same App Group
        // directory used by the main app). Must run before any MDictReader.
        //
        // `.disabled` write mode — the Action Extension is a pure *reader*
        // of sidecar files. The main app is the single source of truth for
        // generation, so the extension never writes .idx files even if it
        // hits the slow path. The main app has almost certainly written
        // them already, since the user must have launched it at least once
        // to import or download the dictionary in the first place.
        //
        // Path comes from `AppGroupPaths` (a small shared helper) — the
        // full `DictionaryService` / `DictionaryStorageService` facade is
        // main-app-only and not linked into this extension.
        MDictSidecarCache.cacheDirectory = AppGroupPaths.sidecarIndexCacheURL
        MDictSidecarCache.writeMode = .disabled

        // Extensions are short-lived, read-only — never need CloudKit sync.
        CoreDataStack.shared.setup(enableCloudKit: false)

        ArticlePageView.registerJumpSearchMenuItem()

        view.backgroundColor = .systemBackground

        configureNavigationBar()
        configureLoadingUI()
        applyAppearance()
        configureAudioSession()

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        extractSelectedText { [weak self] text in
            guard let self else { return }

            if let text, !text.isEmpty {
                self.selectedText = text
                self.loadDictionaryAndLookup(word: text)
            } else {
                self.showNotFound()
            }
        }
    }

    // MARK: - Trait Collection

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            reloadAllPages()
        }
    }

    /// Re-render all article pages with the current traitCollection.
    /// Called when appearance mode changes so that static CSS colors
    /// (baked by ArticleHTMLRenderer at render time) are refreshed.
    private func reloadAllPages() {
        for (index, page) in pages.enumerated() where index < results.count {
            let result = results[index]
            let renderedHTML = ArticleHTMLRenderer.renderArticle(
                html: result.html,
                dictId: result.dictId,
                traitCollection: traitCollection
            )
            page.loadHTMLContent(renderedHTML)
        }
    }

    // MARK: - Keyboard Shortcuts

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                         action: #selector(dismissTapped)),
            UIKeyCommand(input: "d", modifierFlags: .command,
                         action: #selector(bookmarkTapped)),
            UIKeyCommand(input: "=", modifierFlags: .command,
                         action: #selector(zoomInTapped)),
            UIKeyCommand(input: "-", modifierFlags: .command,
                         action: #selector(zoomOutTapped)),
            UIKeyCommand(input: "0", modifierFlags: .command,
                         action: #selector(resetZoomTapped)),
            UIKeyCommand(input: "a", modifierFlags: [.shift, .command],
                         action: #selector(toggleAppearanceShortcut)),
        ]
        if results.count > 1 {
            commands.append(contentsOf: [
                UIKeyCommand(input: "[", modifierFlags: .command,
                             action: #selector(previousPageShortcut)),
                UIKeyCommand(input: "]", modifierFlags: .command,
                             action: #selector(nextPageShortcut)),
            ])
        }
        return commands
    }

    @objc private func resetZoomTapped() { resetZoom() }

    @objc private func toggleAppearanceShortcut() {
        let next = AppearanceMode(rawValue: (appearanceMode.rawValue + 1) % 3) ?? .system
        setAppearanceMode(next)
    }

    @objc private func previousPageShortcut() {
        guard currentPageIndex > 0 else { return }
        navigateToPage(currentPageIndex - 1)
    }

    @objc private func nextPageShortcut() {
        guard currentPageIndex < results.count - 1 else { return }
        navigateToPage(currentPageIndex + 1)
    }

    /// Navigate to a specific page. Keyboard shortcuts use `animated: false`
    /// to avoid race conditions when pressing shortcuts in quick succession;
    /// page control tap uses `animated: true` for a smooth swipe feel.
    private func navigateToPage(_ page: Int, animated: Bool = false) {
        guard let sv = scrollView else { return }
        sv.setContentOffset(
            CGPoint(x: CGFloat(page) * sv.bounds.width, y: 0),
            animated: animated
        )
        currentPageIndex = page
        pageControl?.currentPage = page
        updateCurrentPageState()
    }

    // MARK: - Navigation Bar
    
    private func configureNavigationBar() {
        title = nil
        navigationItem.titleView = nil

        let dismissItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(dismissTapped)
        )

        // Appearance: shared segmented control (both iOS 15 and 16+)
        let segmented = appearanceMode.segmentedControl(
            target: self, action: #selector(appearanceChanged(_:))
        )
        self.appearanceSegmentedControl = segmented

        // Appearance: representativeItem (collapsed fallback on iOS 16+ / unused on iOS 15)
        let appearance = UIBarButtonItem(
            image: appearanceMode.icon,
            style: .plain,
            target: self,
            action: nil
        )
        appearance.menu = appearanceMode.menu { [weak self] m in self?.setAppearanceMode(m) }
        self.appearanceButton = appearance

        if #available(iOS 16, *) {
            navigationItem.style = .browser

            navigationItem.leadingItemGroups = [
                .fixedGroup(items: [dismissItem]),
                .optionalGroup(
                    customizationIdentifier: "appearance",
                    representativeItem: appearance,
                    items: [.init(customView: segmented)]
                ),
            ]

            navigationItem.centerItemGroups = []

            let sliderContainer = makeZoomSliderContainer()
            let sliderItem = UIBarButtonItem(customView: sliderContainer)

            let representative = UIBarButtonItem(
                title: L10n.Detail.currentLevel(zoom.displayString),
                image: .init(systemName: "textformat.size"),
                menu: currentZoomMenu
            )
            self.zoomRepresentativeItem = representative

            navigationItem.trailingItemGroups = [
                .fixedGroup(
                    representativeItem: representative,
                    items: [sliderItem]
                )
            ]

        } else {
            let segmentItem = UIBarButtonItem(customView: segmented)
            navigationItem.leftBarButtonItems = [dismissItem, segmentItem]

            // iOS 15: Three zoom buttons
            let zIn = UIBarButtonItem(
                image: UIImage(systemName: "plus.magnifyingglass"),
                style: .plain,
                target: self,
                action: #selector(zoomInTapped)
            )
            zIn.title = L10n.Detail.zoomIn
            zIn.isEnabled = false

            let zReset = UIBarButtonItem(
                image: UIImage(systemName: "1.magnifyingglass"),
                style: .plain,
                target: self,
                action: #selector(resetZoomTapped)
            )
            zReset.title = zoom.displayString
            zReset.isEnabled = false

            let zOut = UIBarButtonItem(
                image: UIImage(systemName: "minus.magnifyingglass"),
                style: .plain,
                target: self,
                action: #selector(zoomOutTapped)
            )
            zOut.title = L10n.Detail.zoomOut
            zOut.isEnabled = false

            self.zoomInButton = zIn
            self.zoomResetButton = zReset
            self.zoomOutButton = zOut

            navigationItem.rightBarButtonItems = [zIn, zReset, zOut]
        }
    }

    @objc private func dismissTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Appearance Mode

    @objc private func appearanceChanged(_ sender: UISegmentedControl) {
        let mode = AppearanceMode(rawValue: sender.selectedSegmentIndex) ?? .system
        setAppearanceMode(mode)
    }

    private func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        UserDefaults.shared.setAppearanceModeStamped(mode)
        applyAppearance()
        // In-place updates — no nav bar rebuild
        appearanceButton?.image = appearanceMode.icon
        appearanceButton?.menu = appearanceMode.menu { [weak self] m in self?.setAppearanceMode(m) }
        appearanceSegmentedControl?.selectedSegmentIndex = mode.rawValue
    }

    private func applyAppearance() {
        // In an Action Extension the window belongs to the host app,
        // so override on the navigation controller's view hierarchy instead.
        navigationController?.overrideUserInterfaceStyle = appearanceMode.userInterfaceStyle
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Re-apply appearance when window becomes available
        applyAppearance()

        // Capsule shape for page control backdrop (height-dependent)
        if let backdrop = pageControlBackdrop, backdrop.bounds.height > 0 {
            backdrop.layer.cornerRadius = backdrop.bounds.height / 2
        }

        guard let sv = scrollView, !pages.isEmpty else { return }

        let pageWidth = sv.bounds.width
        guard pageWidth > 0 else { return }

        // Update content size
        sv.contentSize = CGSize(width: pageWidth * CGFloat(pages.count), height: sv.bounds.height)

        // Update each page container's leading constraint
        for (index, constraint) in pageLeadingConstraints.enumerated() {
            constraint.constant = CGFloat(index) * pageWidth
        }

        // Restore current page offset
        sv.contentOffset = CGPoint(x: CGFloat(currentPageIndex) * pageWidth, y: 0)
    }

    // MARK: - Bookmark

    /// Keyboard shortcut handler — delegates to the current page's bookmark toggle.
    @objc private func bookmarkTapped() {
        guard currentPageIndex < pages.count else { return }
        let page = pages[currentPageIndex]
        handleBookmarkTapped(isCurrentlyBookmarked: page.isBookmarked, pageView: page)
    }

    /// Shared bookmark toggle logic (called from both keyboard shortcut and page callback).
    private func handleBookmarkTapped(isCurrentlyBookmarked: Bool, pageView: ArticlePageView) {
        guard let pageIndex = pages.firstIndex(where: { $0 === pageView }),
              pageIndex < results.count else { return }
        let result = results[pageIndex]

        if isCurrentlyBookmarked {
            // Removing → show confirmation alert
            let alert = UIAlertController(
                title: L10n.Bookmarks.removeBookmark,
                message: L10n.Bookmarks.removeBookmarkMessage(word: result.keyword, dictName: result.dictName),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
                guard let self else { return }
                BookmarkService.shared.toggleBookmark(
                    word: result.keyword, dictId: result.dictId
                )
                self.isBookmarked = false
                pageView.setBookmarked(false)
            })
            present(alert, animated: true)
        } else {
            // Adding → immediate
            isBookmarked = BookmarkService.shared.toggleBookmark(
                word: result.keyword, dictId: result.dictId
            )
            pageView.setBookmarked(isBookmarked)
        }
    }

    // MARK: - Lookup Count

    private func subscribeLookupCount() {
        guard currentPageIndex < results.count,
              currentPageIndex < pages.count else { return }
        let result = results[currentPageIndex]
        let page = pages[currentPageIndex]

        lookupCountCancellable = LookupHistoryService.shared
            .lookupCountPublisher(word: result.keyword, dictId: result.dictId)
            .receive(on: DispatchQueue.main)
            .sink { [weak page] count in
                page?.setLookupCount(count)
            }
    }

    // MARK: - Zoom

    /// Thin adapter: bridges shared ZoomLevel.menu factory to this VC's zoom methods.
    private var currentZoomMenu: UIMenu {
        zoom.menu(
            onZoomIn:  { [weak self] in self?.zoomIn() },
            onReset:   { [weak self] in self?.resetZoom() },
            onZoomOut: { [weak self] in self?.zoomOut() }
        )
    }

    @objc private func zoomInTapped() { zoomIn() }
    @objc private func zoomOutTapped() { zoomOut() }

    private func zoomIn() {
        guard !pages.isEmpty else { return }
        zoom.zoomIn()
        didChangeZoom()
    }

    private func zoomOut() {
        guard !pages.isEmpty else { return }
        zoom.zoomOut()
        didChangeZoom()
    }

    private func resetZoom() {
        guard !pages.isEmpty else { return }
        zoom.reset()
        didChangeZoom()
    }

    /// Shared post-change pipeline: apply to web views, refresh UI, and
    /// persist for next session (last step no-ops when the user has the
    /// Remember Zoom Level toggle off).  Uses the `compact` key to match
    /// the seed in the instance initializer.
    private func didChangeZoom() {
        applyZoomToAllPages()
        refreshZoomUI()
        UserDefaults.shared.persistZoomLevelIfEnabled(zoom.current, compact: true)
    }

    private func refreshZoomUI() {
        if #available(iOS 16, *) {
            // In-place update: slider + representative
            if let idx = ZoomLevel.levels.firstIndex(of: zoom.current) {
                zoomSlider?.value = Float(idx)
            }
            zoomRepresentativeItem?.title = L10n.Detail.currentLevel(zoom.displayString)
        } else {
            updateZoomButtonStates()
        }
    }

    private func updateZoomButtonStates() {
        zoomInButton?.isEnabled = zoom.canZoomIn
        zoomResetButton?.isEnabled = !zoom.isDefault
        zoomResetButton?.title = zoom.displayString
        zoomOutButton?.isEnabled = zoom.canZoomOut
    }

    private func applyZoomToAllPages() {
        for page in pages {
            page.setZoomLevel(zoom.current)
        }
    }

    // MARK: - Zoom Slider

    private func makeZoomSliderContainer() -> UIView {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = Float(ZoomLevel.levels.count - 1)
        slider.value = Float(ZoomLevel.levels.firstIndex(of: zoom.current) ?? 2)
        slider.isContinuous = true
        slider.isEnabled = false  // Enabled when first article arrives (setupPager)
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
        guard !pages.isEmpty else { return }
        let index = Int(sender.value.rounded())
        sender.value = Float(index)
        let newLevel = ZoomLevel.levels[index]
        guard newLevel != zoom.current else { return }
        zoom = ZoomLevel(newLevel)
        didChangeZoom()
    }

    // MARK: - Loading UI

    private func configureLoadingUI() {
        showStatusView(
            symbolName: "books.vertical",
            message: L10n.ActionExtension.loading,
            showSpinner: true
        )
    }

    /// Updates the loading status to show the word and dictionary name with a book icon.
    private func updateLoadingLabel(word: String, dictName: String) {
        // Replace the "Loading dictionaries…" status with per-dict status
        showStatusView(
            symbolName: "character.book.closed",
            message: String(format: L10n.ActionExtension.loadingWithName, word, dictName),
            showSpinner: true
        )
    }

    private func removeStatusView() {
        statusContainerView?.removeFromSuperview()
        statusContainerView = nil
        removeSuggestionsTableView()
    }

    /// Reusable status view: SF Symbol icon + message + optional spinner + optional action button.
    private func showStatusView(
        symbolName: String,
        message: String,
        showSpinner: Bool,
        actionTitle: String? = nil,
        actionSymbol: String? = nil,
        filledButton: Bool = false,
        actionHandler: (() -> Void)? = nil
    ) {
        removeStatusView()

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        // Stack: icon → message (→ spinner) (→ button)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        container.addSubview(stack)

        // SF Symbol
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 40, weight: .light)
        let iconView = UIImageView(image: UIImage(systemName: symbolName, withConfiguration: iconConfig))
        iconView.tintColor = .tertiaryLabel
        iconView.contentMode = .scaleAspectFit
        stack.addArrangedSubview(iconView)

        // Message label
        let label = UILabel()
        label.tag = 1001
        label.text = message
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .callout)
        label.textAlignment = .center
        label.numberOfLines = 0
        stack.addArrangedSubview(label)

        // Spinner (if loading)
        if showSpinner {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            stack.addArrangedSubview(spinner)
        }

        // Action button (if provided)
        if let actionTitle {
            // Extra spacing before button
            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
            stack.addArrangedSubview(spacer)

            let button = UIButton(type: .system)

            if filledButton {
                if #available(iOS 15.0, *) {
                    var config = UIButton.Configuration.filled()
                    config.title = actionTitle
                    config.cornerStyle = .capsule
                    config.buttonSize = .large
                    if let actionSymbol {
                        config.image = UIImage(systemName: actionSymbol)
                        config.imagePlacement = .trailing
                        config.imagePadding = 6
                    }
                    button.configuration = config
                } else {
                    button.setTitle(actionTitle, for: .normal)
                    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
                    button.backgroundColor = view.tintColor
                    button.setTitleColor(.white, for: .normal)
                    button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
                    button.layer.cornerRadius = 22
                    button.clipsToBounds = true
                }
            } else {
                button.setTitle(actionTitle, for: .normal)
                button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            }

            if let handler = actionHandler {
                let action = UIAction { _ in handler() }
                button.addAction(action, for: .touchUpInside)
            }
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
        ])

        self.statusContainerView = container
    }

    // MARK: - Text Extraction

    private func extractSelectedText(completion: @escaping @MainActor (String?) -> Void) {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = extensionItem.attachments?.first else {
            completion(nil)
            return
        }

        let textType = "public.plain-text"
        if provider.hasItemConformingToTypeIdentifier(textType) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { item, _ in
                let text = item as? String
                DispatchQueue.main.async { completion(text) }
            }
            return
        }

        completion(nil)
    }

    // MARK: - Dictionary Loading & Lookup (Streaming)

    private func loadDictionaryAndLookup(word: String) {
        print("📖 loadDictionaryAndLookup: word='\(word)'")

        Task.detached { [weak self] in
            guard let self else { return }

            // 1. Query CoreData: default group entries (user sort order) + metadata
            let context = await CoreDataStack.shared.viewContext

            let records: [(dictId: String, displayName: String)] = await context.perform {
                do {
                    let entryRequest = GroupEntryRecord.fetchRequest()
                    entryRequest.predicate = NSPredicate(format: "groupId == %@", "all")
                    entryRequest.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
                    let entries = try context.fetch(entryRequest)

                    if entries.isEmpty {
                        let metaRequest = DictionaryMetadataRecord.fetchRequest()
                        metaRequest.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: true)]
                        let metas = try context.fetch(metaRequest)
                        return metas.map { (dictId: $0.dictId, displayName: $0.displayName) }
                    }

                    let metaRequest = DictionaryMetadataRecord.fetchRequest()
                    let allMeta = try context.fetch(metaRequest)
                    let metaByDictId = Dictionary(uniqueKeysWithValues: allMeta.map { ($0.dictId, $0.displayName) })

                    return entries.compactMap { entry -> (dictId: String, displayName: String)? in
                        guard let name = metaByDictId[entry.dictId] else { return nil }
                        return (dictId: entry.dictId, displayName: name)
                    }
                } catch {
                    return []
                }
            }

            guard !records.isEmpty else {
                await MainActor.run { self.showNoDictionaries() }
                return
            }

            // Update loading UI
            await MainActor.run {
                self.updateLoadingLabel(word: word, dictName: records[0].displayName)
            }

            // 2. Compute lemma candidates (pure CPU, no I/O)
            let normalized = LemmaResolver.normalize(word)
            let strippedTokens = LemmaResolver.stripStopwords(normalized)
            var lemmaCandidateSet = Set<String>()
            for token in strippedTokens {
                lemmaCandidateSet.formUnion(LemmaResolver.nltaggerLemmas(token))
                lemmaCandidateSet.formUnion(EnglishInflectionRules.resolve(token))
            }
            lemmaCandidateSet.subtract([normalized])
            let lemmaCandidates = Array(lemmaCandidateSet)
            if !lemmaCandidates.isEmpty {
                print("📖 Lemma candidates for '\(word)': \(lemmaCandidates)")
            }

            await MainActor.run { self.collectedSuggestions = [] }

            // 3. Iterate through dictionaries sequentially.
            //    Rule: only one MDX reader alive at a time.
            //    Stop early when articles capacity is reached.
            let capacityLimit = await MainActor.run { self.articlesCapacityLimit }
            for (index, record) in records.enumerated() {
                // Check if we've reached the capacity limit
                let currentCount = await MainActor.run { self.results.count }
                guard currentCount < capacityLimit else {
                    print("📦 Reached articles capacity (\(capacityLimit)), stopping scan")
                    break
                }

                let dictId = record.dictId
                let dictDir = Self.dictionariesRoot.appendingPathComponent(dictId)
                let manifestURL = dictDir.appendingPathComponent("manifest.json")

                print("📖 Dict[\(index)] '\(record.displayName)' — loading MDX…")

                guard let manifestData = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder.isoDate.decode(DictManifestLite.self, from: manifestData) else {
                    print("📖 Dict[\(index)] '\(record.displayName)' — manifest read failed, skip")
                    continue
                }

                let mdxPath = dictDir.appendingPathComponent(manifest.mdx.fileName).path
                guard FileManager.default.fileExists(atPath: mdxPath) else {
                    print("📖 Dict[\(index)] '\(record.displayName)' — MDX file missing, skip")
                    continue
                }

                // Only show loading status if pager hasn't appeared yet
                if await MainActor.run(body: { self.scrollView == nil }) {
                    await MainActor.run {
                        self.updateLoadingLabel(word: word, dictName: record.displayName)
                    }
                }

                // ── Phase 1: MDX lookup (3-stage: exact → lemma → suggestions) ──
                // Load MDX index, lookup articles, collect HTML, then release.
                var articleHTMLs: [(keyword: String, html: String, resolvedFrom: String?)] = []
                do {
                    guard let reader = try? MDictReader(path: mdxPath) else {
                        print("📖 Dict[\(index)] '\(record.displayName)' — MDictReader init failed, skip")
                        continue
                    }

                    // Stage 1: Exact match
                    let candidates = reader.search(prefix: word, limit: 10)
                    let exactMatches = candidates.filter {
                        $0.caseInsensitiveCompare(word) == .orderedSame
                    }

                    for keyword in exactMatches {
                        if let entry = reader.lookup(keyword) {
                            articleHTMLs.append((keyword: keyword, html: entry.article.html, resolvedFrom: nil))
                        }
                    }

                    // Stage 2: Lemma candidates (only if exact match found nothing)
                    if articleHTMLs.isEmpty && !lemmaCandidates.isEmpty {
                        for lemma in lemmaCandidates {
                            let lemmaCands = reader.search(prefix: lemma, limit: 10)
                            let lemmaMatches = lemmaCands.filter {
                                $0.caseInsensitiveCompare(lemma) == .orderedSame
                            }
                            for keyword in lemmaMatches {
                                if let entry = reader.lookup(keyword) {
                                    articleHTMLs.append((keyword: keyword, html: entry.article.html, resolvedFrom: word))
                                }
                            }
                            if !articleHTMLs.isEmpty { break }
                        }
                        if !articleHTMLs.isEmpty {
                            print("📖 Dict[\(index)] '\(record.displayName)' — found via lemma")
                        }
                    }

                    // Stage 3: Spelling suggestions (only if exact + lemma both failed)
                    if articleHTMLs.isEmpty {
                        let scored = reader.suggestions(for: word, limit: 5)
                        if !scored.isEmpty {
                            await MainActor.run {
                                self.collectedSuggestions.append(contentsOf: scored)
                            }
                        }
                        print("📖 Dict[\(index)] '\(record.displayName)' — not found (\(scored.count) suggestions)")
                    }
                    // reader deinit here → MDX index freed
                }

                // ── Phase 2: MDD only (MDX already freed) ─────────────────
                // Extract MDD resources BEFORE streaming HTML to WKWebView,
                // so the scheme handler can serve them when the WebView requests them.
                if !manifest.mdd.isEmpty && !articleHTMLs.isEmpty {
                    // Collect all resource paths from all articles for this dict
                    var allResourcePaths = Set<String>()
                    for article in articleHTMLs {
                        allResourcePaths.formUnion(
                            HTMLResourceRewriter.extractResourcePaths(from: article.html)
                        )
                    }

                    print("📖 Dict[\(index)] MDD Phase 2: \(allResourcePaths.count) resource paths extracted from HTML")
                    for p in allResourcePaths.sorted().prefix(20) {
                        print("📖   path: '\(p)'")
                    }

                    if !allResourcePaths.isEmpty {
                        // Create MDD parsers (MDX is already released)
                        let mddDir = dictDir.appendingPathComponent("mdd", isDirectory: true)
                        print("📖 Dict[\(index)] MDD dir: \(mddDir.path)")
                        print("📖 Dict[\(index)] manifest.mdd count: \(manifest.mdd.count)")
                        for entry in manifest.mdd {
                            let mddPath = mddDir.appendingPathComponent(entry.fileName).path
                            let exists = FileManager.default.fileExists(atPath: mddPath)
                            print("📖   MDD file: '\(entry.fileName)' exists=\(exists)")
                        }

                        let mddParsers: [MDDParser] = manifest.mdd.compactMap { entry in
                            let path = mddDir.appendingPathComponent(entry.fileName).path
                            return try? MDDParser(path: path)
                        }

                        print("📖 Dict[\(index)] MDDParsers created: \(mddParsers.count)")
                        for (pi, parser) in mddParsers.enumerated() {
                            print("📖   parser[\(pi)] resourceCount=\(parser.resourceCount)")
                        }

                        if !mddParsers.isEmpty {
                            let count = MDDResourceExtractor.extractAndCache(
                                resourcePaths: allResourcePaths,
                                mddParsers: mddParsers,
                                dictId: dictId
                            )
                            print("📖 Dict[\(index)] — extracted \(count) MDD resources (of \(allResourcePaths.count) paths)")
                        }
                        // mddParsers deinit here → MDD index freed
                    }
                }

                // ── Phase 3: Stream articles to UI ─────────────────────────
                // MDD resources are now cached; WKWebView can load them via scheme handler.
                for article in articleHTMLs {
                    print("📖 Dict[\(index)] '\(record.displayName)' — FOUND '\(article.keyword)'")
                    let result = ArticleResult(
                        dictId: dictId,
                        dictName: record.displayName,
                        keyword: article.keyword,
                        html: article.html,
                        resolvedFrom: article.resolvedFrom
                    )
                    await MainActor.run { self.appendArticle(result) }
                }
            }

            // 4. Scan complete
            let dictCount = records.count
            await MainActor.run {
                self.searchedDictCount = dictCount
                self.scanSpinner?.stopAnimating()
                self.scanSpinner?.isHidden = true
                if self.results.isEmpty {
                    if self.collectedSuggestions.isEmpty {
                        self.showNotFound()
                    } else {
                        self.showSuggestions()
                    }
                } else {
                    self.removeStatusView()
                }
            }
        }
    }

    // MARK: - Pager: Streaming Article Display

    /// Called on MainActor each time a new article result arrives from the scan.
    private func appendArticle(_ result: ArticleResult) {
        guard results.count < articlesCapacityLimit else { return }
        results.append(result)

        // Record lookup history (bumps "You have looked this word up N times")
        LookupHistoryService.shared.recordLookup(
            word: result.keyword,
            dictId: result.dictId,
            lookupContextDictId: nil,
            lookupContextGroupId: nil
        )

        if results.count == 1 {
            setupPager()
        } else {
            addPage(for: result)
            pageControl?.numberOfPages = results.count
            pageControl?.isHidden = false
            pageControlBackdrop?.isHidden = false
        }
    }

    /// Creates the pager container and the first page.
    private func setupPager() {
        removeStatusView()

        let result = results[0]

        // Enable zoom controls now that articles are available
        zoomSlider?.isEnabled = true
        zoomInButton?.isEnabled = zoom.canZoomIn
        zoomResetButton?.isEnabled = !zoom.isDefault
        zoomOutButton?.isEnabled = zoom.canZoomOut

        // Create shared WKWebView configuration with scheme handler.
        // MDD resources are pre-extracted to Caches/MDD/ during scan; scheme handler serves from disk.
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let handler = ActionExtensionSchemeHandler(
            dictionariesRoot: Self.dictionariesRoot,
            mddCacheRoot: MDDResourceExtractor.cacheRootURL
        )
        config.setURLSchemeHandler(handler, forURLScheme: ActionExtensionSchemeHandler.scheme)
        self.webViewConfiguration = config

        // Scroll View (paging) — from safe area top (headers are per-page now)
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.isPagingEnabled = true
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.bounces = true
        sv.delegate = self
        view.addSubview(sv)
        self.scrollView = sv

        // Floating page control with translucent backdrop (centered bottom, overlays scroll view)
        let effect: UIVisualEffect
        if #available(iOS 26, *) {
            effect = UIGlassEffect(style: .regular)
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        let backdrop = UIVisualEffectView(effect: effect)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.clipsToBounds = true
        backdrop.isHidden = true  // shown together with page control
        view.addSubview(backdrop)
        self.pageControlBackdrop = backdrop

        let pc = UIPageControl()
        pc.translatesAutoresizingMaskIntoConstraints = false
        pc.numberOfPages = 1
        pc.currentPage = 0
        pc.isHidden = true
        pc.pageIndicatorTintColor = .tertiaryLabel
        pc.currentPageIndicatorTintColor = .label
        pc.addTarget(self, action: #selector(pageControlValueChanged(_:)), for: .valueChanged)
        backdrop.contentView.addSubview(pc)
        self.pageControl = pc

        // Floating scan spinner (bottom-right, overlays scroll view)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        self.scanSpinner = spinner

        NSLayoutConstraint.activate([
            // Pager — from safe area top to bottom (headers are inside each page)
            sv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            sv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            // Page control backdrop — floating, centered at bottom
            backdrop.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            // Page control — fills backdrop content view
            pc.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor, constant: 4),
            pc.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor, constant: -4),
            pc.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor, constant: 4),
            pc.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor, constant: -4),

            // Scan spinner — floating, bottom-right, vertically aligned with page control
            spinner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            spinner.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
        ])

        // Update bookmark/lookup count for first result
        updateCurrentPageState()

        // Add first page
        addPage(for: result)
    }

    /// Create an ArticlePageView for the given article result.
    private func makeArticlePageView(for result: ArticleResult) -> ArticlePageView {
        guard let config = webViewConfiguration else { fatalError("webViewConfiguration must be set before making pages") }

        let pageConfig = ArticlePageView.Configuration.actionExtension(webViewConfig: config)
        let pageView = ArticlePageView(configuration: pageConfig)
        pageView.translatesAutoresizingMaskIntoConstraints = false

        let bookmarked = BookmarkService.shared.isBookmarked(word: result.keyword, dictId: result.dictId)
        let displayWord: String
        if let original = result.resolvedFrom {
            displayWord = "\(original) → \(result.keyword)"
        } else {
            displayWord = result.keyword
        }
        pageView.configure(word: displayWord, dictName: result.dictName,
                          dictId: result.dictId, isBookmarked: bookmarked)

        // Wire callbacks (capture pageView weakly to avoid retain cycles)
        pageView.onBookmarkTapped = { [weak self, weak pageView] isCurrentlyBookmarked in
            guard let self, let pageView else { return }
            self.handleBookmarkTapped(isCurrentlyBookmarked: isCurrentlyBookmarked, pageView: pageView)
        }

        pageView.onEntryLinkTapped = { [weak self, weak pageView] word, _ in
            guard let self, let pageView else { return }
            // Fragment is dropped at this boundary — the Action Extension
            // can't navigate articles in-place; tapping a cross-ref just
            // prompts the user to open the main app, where in-app cross-ref
            // navigation handles fragments end-to-end.  If we ever wire the
            // extension to deep-link into the main app with the cross-ref
            // target, we should preserve the fragment in that URL.
            self.confirmOpenInApp(word: word, from: pageView)
        }

        pageView.onSoundLinkTapped = { [weak self, weak pageView] url in
            guard let self, let pageView else { return }
            self.playAudio(url: url, from: pageView)
        }

        pageView.onEnhanceDarkModeStrengthChanged = { [weak pageView] newStrength in
            DictMetadataService.shared.updateEnhanceDarkModeStrength(dictId: result.dictId, strength: newStrength)
            pageView?.setDarkModeEnhance(strength: newStrength)
        }
        pageView.onJumpSearch = { [weak self, weak pageView] text in
            guard let self, let pageView else { return }
            guard let pageIndex = self.pages.firstIndex(where: { $0 === pageView }),
                  pageIndex < self.results.count else { return }
            let dictId = self.results[pageIndex].dictId
            let dictName = self.results[pageIndex].dictName
            self.performJumpSearch(word: text, dictId: dictId, dictName: dictName)
        }

        return pageView
    }

    /// Updates bookmark state and lookup count subscription for the current page.
    private func updateCurrentPageState() {
        guard currentPageIndex < results.count,
              currentPageIndex < pages.count else { return }
        let result = results[currentPageIndex]
        let page = pages[currentPageIndex]

        // Bookmark state
        isBookmarked = BookmarkService.shared.isBookmarked(word: result.keyword, dictId: result.dictId)
        page.setBookmarked(isBookmarked)

        // Lookup count subscription (re-binds on each page change)
        subscribeLookupCount()
    }

    /// Adds a new page (ArticlePageView) for the given article result.
    private func addPage(for result: ArticleResult) {
        guard let sv = scrollView else { return }

        let pageView = makeArticlePageView(for: result)
        sv.addSubview(pageView)

        let pageIndex = pages.count
        let leadingConstraint = pageView.leadingAnchor.constraint(
            equalTo: sv.leadingAnchor,
            constant: CGFloat(pageIndex) * sv.bounds.width
        )

        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: sv.topAnchor),
            pageView.widthAnchor.constraint(equalTo: sv.widthAnchor),
            pageView.heightAnchor.constraint(equalTo: sv.heightAnchor),
            leadingConstraint,
        ])

        pages.append(pageView)
        pageLeadingConstraints.append(leadingConstraint)

        sv.contentSize = CGSize(
            width: sv.bounds.width * CGFloat(pages.count),
            height: sv.bounds.height
        )

        // Apply display settings before loading content (ArticlePageView auto-applies on didFinish)
        if !zoom.isDefault { pageView.setZoomLevel(zoom.current) }
        if let meta = DictMetadataService.shared.find(dictId: result.dictId) {
            if meta.enhanceDarkMode {
                let strength = EnhanceDarkModeStrength(rawValue: meta.enhanceDarkModeStrength) ?? .standard
                pageView.setDarkModeEnhance(strength: strength)
            }
        }

        let renderedHTML = ArticleHTMLRenderer.renderArticle(
            html: result.html,
            dictId: result.dictId,
            traitCollection: traitCollection
        )
        pageView.loadHTMLContent(renderedHTML)
    }

    /// Insert a jump-searched article at the front (index 0) of the pager.
    private func insertArticleAtFront(_ result: ArticleResult) {
        guard let sv = scrollView else { return }

        // 1. Insert into data arrays at index 0
        results.insert(result, at: 0)

        // 2. Shift all existing pages right by one page width
        let pageWidth = sv.bounds.width
        for constraint in pageLeadingConstraints {
            constraint.constant += pageWidth
        }

        // 3. Create & insert new page at index 0
        let pageView = makeArticlePageView(for: result)
        sv.addSubview(pageView)

        let leadingConstraint = pageView.leadingAnchor.constraint(
            equalTo: sv.leadingAnchor, constant: 0
        )
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: sv.topAnchor),
            pageView.widthAnchor.constraint(equalTo: sv.widthAnchor),
            pageView.heightAnchor.constraint(equalTo: sv.heightAnchor),
            leadingConstraint,
        ])

        pages.insert(pageView, at: 0)
        pageLeadingConstraints.insert(leadingConstraint, at: 0)

        // 4. Update content size & page control
        sv.contentSize = CGSize(
            width: pageWidth * CGFloat(pages.count),
            height: sv.bounds.height
        )
        pageControl?.numberOfPages = results.count
        pageControl?.isHidden = results.count <= 1
        pageControlBackdrop?.isHidden = results.count <= 1

        // 5. Keep current view stable: shift contentOffset right by one page
        sv.contentOffset.x += pageWidth

        // 6. Display settings + render
        if !zoom.isDefault { pageView.setZoomLevel(zoom.current) }
        if let meta = DictMetadataService.shared.find(dictId: result.dictId) {
            if meta.enhanceDarkMode {
                let strength = EnhanceDarkModeStrength(rawValue: meta.enhanceDarkModeStrength) ?? .standard
                pageView.setDarkModeEnhance(strength: strength)
            }
        }
        let renderedHTML = ArticleHTMLRenderer.renderArticle(
            html: result.html, dictId: result.dictId,
            traitCollection: traitCollection
        )
        pageView.loadHTMLContent(renderedHTML)

        // 7. Record lookup history
        LookupHistoryService.shared.recordLookup(
            word: result.keyword, dictId: result.dictId,
            lookupContextDictId: nil, lookupContextGroupId: nil
        )

        // 8. Animate scroll to page 0
        navigateToPage(0, animated: true)
    }

    @objc private func pageControlValueChanged(_ sender: UIPageControl) {
        navigateToPage(sender.currentPage, animated: true)
    }

    // MARK: - Jump Search

    /// Look up the selected text in the same dictionary within the extension.
    /// Found → insert at front of pager. Not found → open main app.
    private func performJumpSearch(word: String, dictId: String, dictName: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task.detached { [weak self] in
            guard let self else { return }

            // 1. Open dictionary (same pattern as loadDictionaryAndLookup)
            let dictDir = Self.dictionariesRoot.appendingPathComponent(dictId)
            let manifestURL = dictDir.appendingPathComponent("manifest.json")

            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder.isoDate.decode(DictManifestLite.self, from: manifestData) else {
                await MainActor.run { self.openInApp(word: trimmed) }
                return
            }

            let mdxPath = dictDir.appendingPathComponent(manifest.mdx.fileName).path
            guard FileManager.default.fileExists(atPath: mdxPath),
                  let reader = try? MDictReader(path: mdxPath) else {
                await MainActor.run { self.openInApp(word: trimmed) }
                return
            }

            // 2. Exact match lookup, with lemma fallback
            let candidates = reader.search(prefix: trimmed, limit: 10)
            let exactMatches = candidates.filter {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }

            var foundKeyword: String?
            var foundHTML: String?
            var resolvedFrom: String?

            if let keyword = exactMatches.first, let entry = reader.lookup(keyword) {
                foundKeyword = keyword
                foundHTML = entry.article.html
            } else {
                // Lemma fallback
                let normalized = LemmaResolver.normalize(trimmed)
                let tokens = LemmaResolver.stripStopwords(normalized)
                var lemmaCands = Set<String>()
                for token in tokens {
                    lemmaCands.formUnion(LemmaResolver.nltaggerLemmas(token))
                    lemmaCands.formUnion(EnglishInflectionRules.resolve(token))
                }
                lemmaCands.subtract([normalized])

                for lemma in lemmaCands {
                    let lCands = reader.search(prefix: lemma, limit: 10)
                    let lMatches = lCands.filter { $0.caseInsensitiveCompare(lemma) == .orderedSame }
                    if let keyword = lMatches.first, let entry = reader.lookup(keyword) {
                        foundKeyword = keyword
                        foundHTML = entry.article.html
                        resolvedFrom = trimmed
                        break
                    }
                }
            }

            guard let keyword = foundKeyword, let html = foundHTML else {
                await MainActor.run { self.openInApp(word: trimmed) }
                return
            }
            // reader deinit → MDX index freed

            // 3. MDD resource extraction (if needed)
            if !manifest.mdd.isEmpty {
                let resourcePaths = HTMLResourceRewriter.extractResourcePaths(from: html)
                if !resourcePaths.isEmpty {
                    let mddDir = dictDir.appendingPathComponent("mdd", isDirectory: true)
                    let mddParsers: [MDDParser] = manifest.mdd.compactMap { mddEntry in
                        let path = mddDir.appendingPathComponent(mddEntry.fileName).path
                        return try? MDDParser(path: path)
                    }
                    if !mddParsers.isEmpty {
                        MDDResourceExtractor.extractAndCache(
                            resourcePaths: resourcePaths,
                            mddParsers: mddParsers,
                            dictId: dictId
                        )
                    }
                    // mddParsers deinit → MDD index freed
                }
            }

            // 4. Insert at front + navigate
            let result = ArticleResult(
                dictId: dictId, dictName: dictName,
                keyword: keyword, html: html,
                resolvedFrom: resolvedFrom
            )
            await MainActor.run {
                self.insertArticleAtFront(result)
            }
        }
    }

    // MARK: - Status Display

    /// Shows "no results" with a filled button to open the main app.
    private func showNotFound() {
        let symbolName: String
        if #available(iOS 16.0, *) {
            symbolName = "questionmark.bubble"
        } else {
            symbolName = "questionmark.circle"
        }

        let message = String(format: L10n.ActionExtension.noResults, selectedText, searchedDictCount)

        showStatusView(
            symbolName: symbolName,
            message: message,
            showSpinner: false,
            actionTitle: L10n.ActionExtension.lookItUpInApp,
            actionSymbol: "arrow.forward",
            filledButton: true,
            actionHandler: { [weak self] in self?.openInApp(word: self?.selectedText ?? "") }
        )
    }

    /// Shows spelling suggestions in a UITableView matching WordListVC style.
    /// Section 0: CTA "Look it up in app" cell + footer "No exact match for 'X'."
    /// Section 1: "Did you mean…" header + suggestion cells with disclosure indicator.
    private func showSuggestions() {
        removeStatusView()

        // Deduplicate: keep best (lowest distance) per lowercased word
        var best: [String: ScoredSuggestion] = [:]
        for s in collectedSuggestions {
            let key = s.word.lowercased()
            if let existing = best[key] {
                if s.distance < existing.distance { best[key] = s }
            } else {
                best[key] = s
            }
        }
        displaySuggestions = Array(
            best.values
                .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.word < $1.word }
                .prefix(8)
        )

        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "SuggestionCell")
        tv.keyboardDismissMode = .onDrag
        view.addSubview(tv)

        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        self.suggestionsTableView = tv
    }

    private func removeSuggestionsTableView() {
        suggestionsTableView?.removeFromSuperview()
        suggestionsTableView = nil
        displaySuggestions = []
    }

    /// Shows "no dictionaries" with a filled button matching not-found style.
    private func showNoDictionaries() {
        let symbolName: String
        if #available(iOS 16.0, *) {
            symbolName = "questionmark.bubble"
        } else {
            symbolName = "questionmark.circle"
        }

        showStatusView(
            symbolName: symbolName,
            message: L10n.ActionExtension.noDictionaries,
            showSpinner: false,
            actionTitle: L10n.ActionExtension.setupDictionaries,
            actionSymbol: "arrow.forward",
            filledButton: true,
            actionHandler: { [weak self] in self?.openInApp(word: self?.selectedText ?? "") }
        )
    }

    // MARK: - Audio Playback

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            print("⚠️ Audio session setup failed: \(error)")
        }
    }

    /// Play audio from a sound:// URL tapped in a WKWebView page.
    /// - Parameters:
    ///   - url: The `sound://` URL intercepted from WKNavigationDelegate
    ///   - pageView: The ArticlePageView that triggered the navigation
    private func playAudio(url: URL, from pageView: ArticlePageView) {
        guard let mdictURL = MDictURL(url), mdictURL.isAudio else { return }

        // Determine which dictionary this page belongs to
        guard let pageIndex = pages.firstIndex(where: { $0 === pageView }),
              pageIndex < results.count else { return }
        let dictId = results[pageIndex].dictId

        let resourcePath = mdictURL.resourcePath          // e.g. "uk/word.mp3"
        let pathVariations = mdictURL.pathVariations       // [as-is, /prefixed, \backslash]

        // Try loading audio data from multiple sources
        if let audioData = loadAudioData(resourcePath: resourcePath,
                                         pathVariations: pathVariations,
                                         dictId: dictId) {
            do {
                audioPlayer?.stop()
                audioPlayer = try AVAudioPlayer(data: audioData)
                audioPlayer?.prepareToPlay()
                audioPlayer?.play()
                print("🔊 Playing '\(resourcePath)' from dict '\(dictId)'")
            } catch {
                print("⚠️ Audio playback failed: \(error)")
            }
        } else {
            print("⚠️ Audio not found: '\(resourcePath)' in dict '\(dictId)'")
        }
    }

    /// Load audio data from available sources.
    ///
    /// 1. MDD cache on disk (pre-extracted during Phase 2 or previous runs)
    /// 2. Dictionary directory (loose audio files)
    /// 3. On-demand MDD extraction (creates temporary MDDParser, extracts, caches)
    private func loadAudioData(resourcePath: String,
                               pathVariations: [String],
                               dictId: String) -> Data? {
        let dictDir = Self.dictionariesRoot.appendingPathComponent(dictId)
        let cacheDir = MDDResourceExtractor.cacheRootURL.appendingPathComponent(dictId)

        // ── Tier 1: MDD cache on disk ──────────────────────────────
        for variation in pathVariations {
            let clean = variation.hasPrefix("/") ? String(variation.dropFirst()) : variation
            let cachedURL = cacheDir.appendingPathComponent(clean)
            if let data = try? Data(contentsOf: cachedURL) {
                print("🔊 tier1 (cache) HIT: '\(clean)'")
                return data
            }
        }

        // ── Tier 2: Loose files in dictionary directory ────────────
        for variation in pathVariations {
            let clean = variation.hasPrefix("/") ? String(variation.dropFirst()) : variation
            let fileURL = dictDir.appendingPathComponent(clean)
            if let data = try? Data(contentsOf: fileURL) {
                print("🔊 tier2 (dictDir) HIT: '\(clean)'")
                return data
            }
        }

        // ── Tier 3: On-demand MDD extraction ──────────────────────
        // Parse manifest to find MDD files, create parsers, look up audio.
        let manifestURL = dictDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder.isoDate.decode(DictManifestLite.self, from: manifestData),
              !manifest.mdd.isEmpty else {
            return nil
        }

        let mddDir = dictDir.appendingPathComponent("mdd", isDirectory: true)
        let mddParsers: [MDDParser] = manifest.mdd.compactMap { entry in
            let path = mddDir.appendingPathComponent(entry.fileName).path
            return try? MDDParser(path: path)
        }
        guard !mddParsers.isEmpty else { return nil }

        // Try all path variations against all MDD parsers
        for parser in mddParsers {
            for variation in pathVariations {
                if let data = parser.lookup(variation) {
                    // Cache to disk for future requests
                    let clean = resourcePath.hasPrefix("/") ? String(resourcePath.dropFirst()) : resourcePath
                    let destURL = cacheDir.appendingPathComponent(clean)
                    let parentDir = destURL.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    try? data.write(to: destURL, options: .atomic)
                    print("🔊 tier3 (MDD on-demand) HIT: '\(variation)' → cached '\(clean)'")
                    return data
                }
            }
        }
        // mddParsers deinit here → MDD index freed

        return nil
    }

    // MARK: - Open Containing App

    /// Presents an alert asking the user to confirm opening an entry link in the main app.
    private func confirmOpenInApp(word: String, from pageView: ArticlePageView) {
        let result: ArticleResult? = {
            guard let idx = pages.firstIndex(where: { $0 === pageView }), idx < results.count else { return nil }
            return results[idx]
        }()
        let title = String(format: L10n.ActionExtension.browseEntryTitle, word)
        let message = result.map { String(format: L10n.ActionExtension.browseEntryMessage, $0.dictName) }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ActionExtension.openInApp, style: .default) { [weak self] _ in
            self?.openInApp(word: word, dictId: result?.dictId, dictName: result?.dictName)
        })
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        present(alert, animated: true)
    }

    /// Opens the main app with a lookup URL for the given word.
    /// When dictId is provided, the main app opens the article directly instead of searching.
    private func openInApp(word: String, dictId: String? = nil, dictName: String? = nil) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encodedWord = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        var urlString = "openmdict://lookup?word=\(encodedWord)"
        if let dictId, let encodedId = dictId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "&dictId=\(encodedId)"
        }
        if let dictName, let encodedName = dictName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "&dictName=\(encodedName)"
        }
        guard let url = URL(string: urlString) else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        openContainingApp(url)
        extensionContext?.completeRequest(returningItems: nil)
    }

    @discardableResult
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = r.next
        }
        return false
    }

}

// MARK: - UITableViewDataSource (Suggestions)

extension ActionViewController: UITableViewDataSource {

    /// Section 0: CTA (1 cell). Section 1: Suggestions.
    func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : displaySuggestions.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? L10n.ActionExtension.didYouMean : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? String(format: L10n.ActionExtension.noExactMatch, selectedText) : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SuggestionCell", for: indexPath)
        var c = cell.defaultContentConfiguration()

        if indexPath.section == 0 {
            // CTA: "Look it up in app" — clipboard-style cell
            c.image = UIImage(systemName: "arrow.up.right.square")
            c.imageProperties.tintColor = .tintColor
            c.text = L10n.ActionExtension.lookItUpInApp
            c.textProperties.color = .tintColor
            cell.accessoryType = .none
        } else {
            // Suggestion cell — matches WordListVC's .suggestion style
            let suggestion = displaySuggestions[indexPath.row]
            c.text = suggestion.word
            if #available(iOS 18.0, *) {
                c.image = UIImage(systemName: "questionmark.text.page")
            } else {
                c.image = UIImage(systemName: "lightbulb")
            }
            c.imageProperties.tintColor = .secondaryLabel
            cell.accessoryType = .disclosureIndicator
        }

        cell.contentConfiguration = c
        return cell
    }
}

// MARK: - UITableViewDelegate (Suggestions)

extension ActionViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 0 {
            openInApp(word: selectedText)
        } else {
            let suggestion = displaySuggestions[indexPath.row]
            openInApp(word: suggestion.word)
        }
    }
}

// MARK: - UIScrollViewDelegate

extension ActionViewController: UIScrollViewDelegate {

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        guard page != currentPageIndex, page >= 0, page < results.count else { return }
        currentPageIndex = page
        pageControl?.currentPage = page
        updateCurrentPageState()
    }
}


// MARK: - DictManifestLite

private nonisolated struct DictManifestLite: Decodable {
    let id: String
    let mdx: MDXEntry
    let mdd: [ResourceEntry]

    struct MDXEntry: Decodable {
        let fileName: String
    }

    struct ResourceEntry: Decodable {
        let fileName: String
    }
}

// MARK: - JSONDecoder Helpers

private nonisolated extension JSONDecoder {
    static let isoDate: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
