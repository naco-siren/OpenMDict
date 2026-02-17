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
}

// MARK: - ActionViewController

class ActionViewController: UIViewController {

    // MARK: - Header UI (mirrors ArticleViewController layout)

    private static let headerHeight: CGFloat = 64

    private lazy var headerView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .secondarySystemGroupedBackground
        return v
    }()

    private var isBookmarked = false

    private lazy var bookmarkButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "bookmark")
        config.baseForegroundColor = .secondaryLabel
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            var cfg = button.configuration
            let imageName = self.isBookmarked ? "bookmark.fill" : "bookmark"
            cfg?.image = UIImage(systemName: imageName)
            cfg?.baseForegroundColor = self.isBookmarked ? nil : .secondaryLabel
            button.configuration = cfg
        }
        btn.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    private lazy var subtitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabel
        return l
    }()

    private lazy var lookupCountLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .italicSystemFont(ofSize: 11)
        l.textColor = .tertiaryLabel
        l.isHidden = true
        return l
    }()

    // MARK: - Pager UI

    /// Container for loading/error states — removed when pager is displayed.
    private var statusContainerView: UIView?

    /// Horizontal pager container.
    private var scrollView: UIScrollView?

    /// One WKWebView per article result.
    private var pageWebViews: [WKWebView] = []

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
    private var zoomInButton: UIBarButtonItem?       // iOS 15 individual zoom-in
    private var zoomOutButton: UIBarButtonItem?      // iOS 15 individual zoom-out

    // MARK: - State

    /// The word/phrase selected by the user.
    private var selectedText: String = ""

    /// All article results from scanning all dictionaries.
    private var results: [ArticleResult] = []

    /// Currently visible page index.
    private var currentPageIndex: Int = 0

    /// Number of dictionaries searched (for "in your top N dictionaries" message).
    private var searchedDictCount: Int = 0

    /// Zoom level for article text.
    private var zoom = ZoomLevel()

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

    // MARK: - Navigation Bar
    
    private func configureNavigationBar() {
        title = "OpenMDict"

        let dismissItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(dismissTapped)
        )

        // Appearance: representativeItem (collapsed fallback / iOS 15 plain button)
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
                    items: [
                        .init(customView: appearanceMode.segmentedControl(
                            target: self, action: #selector(appearanceChanged(_:))
                        ))
                    ]
                ),
            ]

            navigationItem.centerItemGroups = []

            navigationItem.trailingItemGroups = [
                .fixedGroup(
                    representativeItem: .init(
                        title: L10n.Detail.currentLevel(zoom.displayString),
                        image: .init(systemName: "textformat.size"),
                        menu: currentZoomMenu
                    ),
                    items: [
                        .init(title: L10n.Detail.zoomOut, image: .init(systemName: "minus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.zoomOut()
                        }),
                        .init(title: L10n.Detail.reset, image: .init(systemName: "1.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.resetZoom()
                        }),
                        .init(title: L10n.Detail.zoomIn, image: .init(systemName: "plus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                            self?.zoomIn()
                        }),
                    ]
                )
            ]

        } else {
            navigationItem.leftBarButtonItems = [dismissItem, appearance]

            // iOS 15: Two separate zoom buttons (no reset — too narrow)
            let zIn = UIBarButtonItem(
                image: UIImage(systemName: "plus.magnifyingglass"),
                style: .plain,
                target: self,
                action: #selector(zoomInTapped)
            )
            zIn.isEnabled = false

            let zOut = UIBarButtonItem(
                image: UIImage(systemName: "minus.magnifyingglass"),
                style: .plain,
                target: self,
                action: #selector(zoomOutTapped)
            )
            zOut.isEnabled = false

            self.zoomInButton = zIn
            self.zoomOutButton = zOut

            navigationItem.rightBarButtonItems = [zIn, zOut]
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
        // Update representativeItem's icon and menu for collapsed state
        appearanceButton?.image = appearanceMode.icon
        appearanceButton?.menu = appearanceMode.menu { [weak self] m in self?.setAppearanceMode(m) }
        // On iOS 16+ rebuild nav bar to update segmented control's selectedSegmentIndex
        if #available(iOS 16, *) {
            configureNavigationBar()
        }
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

        guard let sv = scrollView, !pageWebViews.isEmpty else { return }

        let pageWidth = sv.bounds.width
        let pageHeight = sv.bounds.height

        // Update content size
        sv.contentSize = CGSize(width: pageWidth * CGFloat(pageWebViews.count), height: pageHeight)

        // Update each page's leading constraint
        for (index, webView) in pageWebViews.enumerated() {
            for constraint in sv.constraints where constraint.firstItem as? WKWebView === webView
                && constraint.firstAttribute == .leading {
                constraint.constant = CGFloat(index) * pageWidth
            }
        }

        // Restore current page offset
        sv.contentOffset = CGPoint(x: CGFloat(currentPageIndex) * pageWidth, y: 0)
    }

    // MARK: - Bookmark

    @objc private func bookmarkTapped() {
        guard !results.isEmpty else { return }
        let result = results[currentPageIndex]
        let nowBookmarked = BookmarkService.shared.toggleBookmark(
            word: result.keyword, dictId: result.dictId, dictName: result.dictName
        )
        isBookmarked = nowBookmarked
        bookmarkButton.setNeedsUpdateConfiguration()
    }

    private func updateBookmarkState() {
        guard !results.isEmpty else { return }
        let result = results[currentPageIndex]
        isBookmarked = BookmarkService.shared.isBookmarked(word: result.keyword, dictId: result.dictId)
        bookmarkButton.setNeedsUpdateConfiguration()
    }

    // MARK: - Lookup Count

    private func subscribeLookupCount() {
        guard !results.isEmpty else { return }
        let result = results[currentPageIndex]

        lookupCountCancellable = LookupHistoryService.shared
            .lookupCountPublisher(word: result.keyword, dictId: result.dictId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                guard let self else { return }
                if count > 0 {
                    self.lookupCountLabel.text = L10n.Articles.lookupCount(count)
                    self.lookupCountLabel.textColor = self.lookupCountColor(for: count)
                    self.lookupCountLabel.isHidden = false
                } else {
                    self.lookupCountLabel.isHidden = true
                }
            }
    }

    private func lookupCountColor(for count: Int) -> UIColor {
        switch count {
        case 15...:   return .systemRed
        case 10..<15: return .systemOrange
        case 6..<10:  return .systemBrown
        case 3..<6:   return .secondaryLabel
        default:      return .tertiaryLabel
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
        zoom.zoomIn()
        applyZoomToAllPages()
        refreshZoomUI()
    }

    private func zoomOut() {
        zoom.zoomOut()
        applyZoomToAllPages()
        refreshZoomUI()
    }

    private func resetZoom() {
        zoom.reset()
        applyZoomToAllPages()
        refreshZoomUI()
    }

    private func refreshZoomUI() {
        if #available(iOS 16, *) {
            configureNavigationBar()
        } else {
            updateZoomButtonStates()
        }
    }

    private func updateZoomButtonStates() {
        zoomInButton?.isEnabled = zoom.canZoomIn
        zoomOutButton?.isEnabled = zoom.canZoomOut
    }

    private func applyZoomToAllPages() {
        let js = "document.body.style.fontSize = '\(zoom.current)%';"
        for webView in pageWebViews {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func applyZoom(to webView: WKWebView) {
        guard !zoom.isDefault else { return }
        let js = "document.body.style.fontSize = '\(zoom.current)%';"
        webView.evaluateJavaScript(js, completionHandler: nil)
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

            // 2. Iterate through dictionaries sequentially.
            //    Rule: only one MDX reader alive at a time.
            for (index, record) in records.enumerated() {
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

                // ── Phase 1: MDX only (no MDD loaded) ──────────────────────
                // Load MDX index, lookup articles, collect HTML, then release.
                var articleHTMLs: [(keyword: String, html: String)] = []
                do {
                    guard let reader = try? MDictReader(path: mdxPath) else {
                        print("📖 Dict[\(index)] '\(record.displayName)' — MDictReader init failed, skip")
                        continue
                    }

                    let candidates = reader.search(prefix: word, limit: 10)
                    let exactMatches = candidates.filter {
                        $0.caseInsensitiveCompare(word) == .orderedSame
                    }

                    for keyword in exactMatches {
                        if let entry = reader.lookup(keyword) {
                            articleHTMLs.append((keyword: keyword, html: entry.article.html))
                        }
                    }

                    if exactMatches.isEmpty {
                        print("📖 Dict[\(index)] '\(record.displayName)' — not found")
                    }
                    // reader deinit here → MDX index freed
                }

                // ── Phase 2: MDD only (MDX already freed) ─────────────────
                // Extract MDD resources BEFORE streaming HTML to WKWebView,
                // so the scheme handler can serve them when the WebView requests them.
                if !manifest.mdd.isEmpty && !articleHTMLs.isEmpty {
                    // Collect all resource paths from all articles for this dict
                    var allResourcePaths = Set<String>()
                    for (_, html) in articleHTMLs {
                        allResourcePaths.formUnion(
                            HTMLResourceRewriter.extractResourcePaths(from: html)
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
                for (keyword, html) in articleHTMLs {
                    print("📖 Dict[\(index)] '\(record.displayName)' — FOUND '\(keyword)'")
                    let result = ArticleResult(
                        dictId: dictId,
                        dictName: record.displayName,
                        keyword: keyword,
                        html: html
                    )
                    await MainActor.run { self.appendArticle(result) }
                }
            }

            // 3. Scan complete
            let dictCount = records.count
            await MainActor.run {
                self.searchedDictCount = dictCount
                self.scanSpinner?.stopAnimating()
                self.scanSpinner?.isHidden = true
                if self.results.isEmpty {
                    self.showNotFound()
                } else {
                    self.removeStatusView()
                }
            }
        }
    }

    // MARK: - Pager: Streaming Article Display

    /// Called on MainActor each time a new article result arrives from the scan.
    private func appendArticle(_ result: ArticleResult) {
        results.append(result)

        // Record lookup history (bumps "You have looked this word up N times")
        LookupHistoryService.shared.recordLookup(
            word: result.keyword,
            dictId: result.dictId,
            dictName: result.dictName,
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

    /// Creates the header + pager container and the first page.
    private func setupPager() {
        removeStatusView()

        let result = results[0]

        // Enable iOS 15 zoom buttons (iOS 16+ buttons are always enabled via fixedGroup)
        zoomInButton?.isEnabled = zoom.canZoomIn
        zoomOutButton?.isEnabled = zoom.canZoomOut

        // Setup header
        view.addSubview(headerView)
        headerView.addSubview(bookmarkButton)

        let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, lookupCountLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleStack)

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

        // Scroll View (paging)
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
            // Header
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            bookmarkButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 4),
            bookmarkButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            bookmarkButton.widthAnchor.constraint(equalToConstant: 40),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 40),

            titleStack.leadingAnchor.constraint(equalTo: bookmarkButton.trailingAnchor, constant: 4),
            titleStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -12),

            // Pager — extends to safe area bottom (page control floats on top)
            sv.topAnchor.constraint(equalTo: headerView.bottomAnchor),
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

        // Populate header for first result
        updateHeaderForCurrentPage()

        // Add first page
        addPage(for: result)
    }

    /// Updates header labels, bookmark state, and lookup count for the current page.
    private func updateHeaderForCurrentPage() {
        guard !results.isEmpty else { return }
        let result = results[currentPageIndex]

        titleLabel.text = result.keyword
        subtitleLabel.text = result.dictName

        updateBookmarkState()
        subscribeLookupCount()
    }

    /// Adds a new WKWebView page for the given article result.
    private func addPage(for result: ArticleResult) {
        guard let sv = scrollView, let config = webViewConfiguration else { return }

        let pageIndex = pageWebViews.count

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = self
        sv.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: sv.topAnchor),
            webView.widthAnchor.constraint(equalTo: sv.widthAnchor),
            webView.heightAnchor.constraint(equalTo: sv.heightAnchor),
            webView.leadingAnchor.constraint(equalTo: sv.leadingAnchor, constant: CGFloat(pageIndex) * sv.bounds.width),
        ])

        pageWebViews.append(webView)

        sv.contentSize = CGSize(
            width: sv.bounds.width * CGFloat(pageWebViews.count),
            height: sv.bounds.height
        )

        let renderedHTML = ArticleHTMLRenderer.renderArticle(
            html: result.html,
            dictId: result.dictId,
            traitCollection: traitCollection
        )
        webView.loadHTMLString(renderedHTML, baseURL: nil)
    }

    @objc private func pageControlValueChanged(_ sender: UIPageControl) {
        guard let sv = scrollView else { return }
        let page = sender.currentPage
        sv.setContentOffset(
            CGPoint(x: CGFloat(page) * sv.bounds.width, y: 0),
            animated: true
        )
        currentPageIndex = page
        updateHeaderForCurrentPage()
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
    ///   - webView: The WKWebView that triggered the navigation
    private func playAudio(url: URL, from webView: WKWebView) {
        guard let mdictURL = MDictURL(url), mdictURL.isAudio else { return }

        // Determine which dictionary this page belongs to
        guard let pageIndex = pageWebViews.firstIndex(of: webView),
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
    private func confirmOpenInApp(word: String, from webView: WKWebView) {
        let result: ArticleResult? = {
            guard let idx = pageWebViews.firstIndex(of: webView), idx < results.count else { return nil }
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

// MARK: - UIScrollViewDelegate

extension ActionViewController: UIScrollViewDelegate {

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        guard page != currentPageIndex, page >= 0, page < results.count else { return }
        currentPageIndex = page
        pageControl?.currentPage = page
        updateHeaderForCurrentPage()
    }
}

// MARK: - WKNavigationDelegate

extension ActionViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "entry":
            decisionHandler(.cancel)
            if let mdictURL = MDictURL(url), mdictURL.isEntryLink {
                confirmOpenInApp(word: mdictURL.resourcePath, from: webView)
            }

        case "sound":
            decisionHandler(.cancel)
            playAudio(url: url, from: webView)

        case "http", "https":
            decisionHandler(.cancel)

        default:
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyZoom(to: webView)
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
