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
//  - No MDD resources loaded (pure HTML text rendering)
//  - All link clicks open the main app
//

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

    /// Spinner shown next to page control while scan is in progress.
    private var scanSpinner: UIActivityIndicatorView?

    /// Shared WKWebView configuration (no scheme handler — pure HTML).
    private var webViewConfiguration: WKWebViewConfiguration?

    // MARK: - Nav Bar Items

    private var appearanceButton: UIBarButtonItem?
    private var zoomButton: UIBarButtonItem?

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
    private var zoomLevel = ZoomLevel()

    /// Appearance mode (light/dark/auto).
    private var appearanceMode: AppearanceMode = UserDefaults.standard.appearanceMode

    /// Lookup count Combine subscription.
    private var lookupCountCancellable: AnyCancellable?

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
        // Left: books.vertical → open main app "all dictionaries" with the current word
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "books.vertical"),
            style: .plain,
            target: self,
            action: #selector(openAllDictsTapped)
        )

        // Right: Appearance + Zoom (disabled until results arrive)
        let appearance = UIBarButtonItem(
            image: appearanceIcon,
            style: .plain,
            target: self,
            action: nil
        )
        appearance.menu = buildAppearanceMenu()
        self.appearanceButton = appearance

        let zoom = UIBarButtonItem(
            image: UIImage(systemName: "textformat.size"),
            style: .plain,
            target: self,
            action: nil
        )
        zoom.isEnabled = false
        zoom.menu = buildZoomMenu()
        self.zoomButton = zoom

        navigationItem.rightBarButtonItems = [zoom, appearance]

        title = "OpenMDict"
    }

    @objc private func openAllDictsTapped() {
        openInApp(word: selectedText)
    }

    // MARK: - Appearance Mode

    private var appearanceIcon: UIImage {
        switch appearanceMode {
        case .light: return UIImage(systemName: "sun.max")!
        case .system: return UIImage(systemName: "circle.lefthalf.filled")!
        case .dark:   return UIImage(systemName: "moon")!
        }
    }

    private func buildAppearanceMenu() -> UIMenu {
        UIMenu(title: L10n.Detail.appearance, children: [
            UIAction(
                title: L10n.Detail.light,
                image: UIImage(systemName: "sun.max"),
                state: appearanceMode == .light ? .on : .off
            ) { [weak self] _ in self?.setAppearanceMode(.light) },
            UIAction(
                title: L10n.Detail.auto,
                image: UIImage(systemName: "circle.lefthalf.filled"),
                state: appearanceMode == .system ? .on : .off
            ) { [weak self] _ in self?.setAppearanceMode(.system) },
            UIAction(
                title: L10n.Detail.dark,
                image: UIImage(systemName: "moon"),
                state: appearanceMode == .dark ? .on : .off
            ) { [weak self] _ in self?.setAppearanceMode(.dark) },
        ])
    }

    private func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        UserDefaults.standard.appearanceMode = mode
        applyAppearance()
        appearanceButton?.image = appearanceIcon
        appearanceButton?.menu = buildAppearanceMenu()
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
            word: selectedText, dictId: result.dictId, dictName: result.dictName
        )
        isBookmarked = nowBookmarked
        bookmarkButton.setNeedsUpdateConfiguration()
    }

    private func updateBookmarkState() {
        guard !results.isEmpty else { return }
        let result = results[currentPageIndex]
        isBookmarked = BookmarkService.shared.isBookmarked(word: selectedText, dictId: result.dictId)
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

    private func buildZoomMenu() -> UIMenu {
        let zoomIn = UIAction(
            title: L10n.Detail.zoomIn,
            image: UIImage(systemName: "plus.magnifyingglass"),
            attributes: zoomLevel.canZoomIn ? [] : .disabled
        ) { [weak self] _ in
            self?.performZoomIn()
        }

        let zoomOut = UIAction(
            title: L10n.Detail.zoomOut,
            image: UIImage(systemName: "minus.magnifyingglass"),
            attributes: zoomLevel.canZoomOut ? [] : .disabled
        ) { [weak self] _ in
            self?.performZoomOut()
        }

        let reset = UIAction(
            title: L10n.Detail.reset,
            image: UIImage(systemName: "arrow.counterclockwise"),
            attributes: zoomLevel.isDefault ? .disabled : []
        ) { [weak self] _ in
            self?.performZoomReset()
        }

        return UIMenu(title: zoomLevel.displayString, children: [zoomIn, zoomOut, reset])
    }

    private func performZoomIn() {
        zoomLevel.zoomIn()
        applyZoomToAllPages()
        zoomButton?.menu = buildZoomMenu()
    }

    private func performZoomOut() {
        zoomLevel.zoomOut()
        applyZoomToAllPages()
        zoomButton?.menu = buildZoomMenu()
    }

    private func performZoomReset() {
        zoomLevel.reset()
        applyZoomToAllPages()
        zoomButton?.menu = buildZoomMenu()
    }

    private func applyZoomToAllPages() {
        let js = "document.body.style.fontSize = '\(zoomLevel.current)%';"
        for webView in pageWebViews {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func applyZoom(to webView: WKWebView) {
        guard !zoomLevel.isDefault else { return }
        let js = "document.body.style.fontSize = '\(zoomLevel.current)%';"
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

                guard FileManager.default.fileExists(atPath: mdxPath),
                      let reader = try? MDictReader(path: mdxPath) else {
                    print("📖 Dict[\(index)] '\(record.displayName)' — MDictReader init failed, skip")
                    continue
                }

                // Only show loading status if pager hasn't appeared yet
                if await MainActor.run(body: { self.scrollView == nil }) {
                    await MainActor.run {
                        self.updateLoadingLabel(word: word, dictName: record.displayName)
                    }
                }

                // Multi-entry discovery
                let candidates = reader.search(prefix: word, limit: 10)
                let exactMatches = candidates.filter {
                    $0.caseInsensitiveCompare(word) == .orderedSame
                }

                for keyword in exactMatches {
                    if let entry = reader.lookup(keyword) {
                        print("📖 Dict[\(index)] '\(record.displayName)' — FOUND '\(keyword)'")
                        let result = ArticleResult(
                            dictId: dictId,
                            dictName: record.displayName,
                            keyword: keyword,
                            html: entry.article.html
                        )
                        await MainActor.run { self.appendArticle(result) }
                    }
                }

                if exactMatches.isEmpty {
                    print("📖 Dict[\(index)] '\(record.displayName)' — not found, releasing reader")
                }
                // reader goes out of scope → deinit
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
        }
    }

    /// Creates the header + pager container and the first page.
    private func setupPager() {
        removeStatusView()

        let result = results[0]

        // Enable nav bar buttons
        zoomButton?.isEnabled = true

        // Setup header
        view.addSubview(headerView)
        headerView.addSubview(bookmarkButton)

        let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, lookupCountLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleStack)

        // Create shared WKWebView configuration (no scheme handler)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
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

        // Bottom bar: page control (center) + scan spinner (trailing)
        let bottomBar = UIView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        let pc = UIPageControl()
        pc.translatesAutoresizingMaskIntoConstraints = false
        pc.numberOfPages = 1
        pc.currentPage = 0
        pc.isHidden = true
        pc.pageIndicatorTintColor = .tertiaryLabel
        pc.currentPageIndicatorTintColor = .label
        pc.addTarget(self, action: #selector(pageControlValueChanged(_:)), for: .valueChanged)
        bottomBar.addSubview(pc)
        self.pageControl = pc

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.startAnimating()
        bottomBar.addSubview(spinner)
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

            // Pager
            sv.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // Bottom bar
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 30),

            // Page control centered
            pc.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            pc.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            // Scan spinner right next to page control dots
            spinner.leadingAnchor.constraint(equalTo: pc.trailingAnchor, constant: 2),
            spinner.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
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

    // MARK: - Open Containing App

    /// Opens the main app with a lookup URL for the given word.
    private func openInApp(word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "openmdict://lookup?word=\(encoded)") else {
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
                openInApp(word: mdictURL.resourcePath)
            }

        case "sound":
            decisionHandler(.cancel)
            // TODO: try MDD first, and decide to show a warning or silent consume as fallback
            openInApp(word: selectedText)

        case "http", "https":
            decisionHandler(.cancel)
            openInApp(word: selectedText)

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
