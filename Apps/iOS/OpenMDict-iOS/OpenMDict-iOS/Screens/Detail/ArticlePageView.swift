//
//  ArticlePageView.swift
//  OpenMDict-iOS
//
//  Unified per-article UIView: header row (bookmark, title, subtitle, lookup count,
//  optional toolbar buttons) + WKWebView.
//
//  Shared by three consumers:
//    - ArticleViewController (compact pager pages)
//    - ArticleCell (regular collection view cells)
//    - ActionViewController (Action Extension pager pages)
//
//  Features are toggled at construction time via an OptionSet, so each consumer
//  declares exactly which capabilities it needs. "一鱼三吃"
//

import UIKit
import WebKit

// MARK: - ArticlePageView

class ArticlePageView: UIView {

    // MARK: - Features OptionSet

    struct Features: OptionSet, Sendable {
        let rawValue: Int

        // ── Visible views (bits 1–7, layout order) ──
        static let pendingOverlay   = Features(rawValue: 1 << 1)  // ArticlePlaceholderView overlay

        // ── Toolbar actions (bits 8–15, header leading → trailing) ──
        static let bookmark         = Features(rawValue: 1 << 8)  // Leading bookmark button
        static let lookupCount      = Features(rawValue: 1 << 9)  // Lookup count label in title stack
        static let findInPage       = Features(rawValue: 1 << 10) // Find button + WKFindInteraction (iOS 16+)
        static let newWindowButton  = Features(rawValue: 1 << 11) // Trailing "open in new scene" button
        static let closeButton      = Features(rawValue: 1 << 12) // Trailing close button
        static let enhanceDarkMode  = Features(rawValue: 1 << 13) // Per-dict dark mode toggle

        // ── Special triggers (bits 16–23) ──
        static let dragInteraction  = Features(rawValue: 1 << 16) // UIDragInteraction on header
        static let jumpSearch       = Features(rawValue: 1 << 17) // UIMenuController "Jump Search"

        // Presets
        static let compactPager:    Features = [.pendingOverlay, .bookmark, .lookupCount,
                                                .findInPage, .enhanceDarkMode, .closeButton,
                                                .jumpSearch]
        static let regularCell:     Features = [.pendingOverlay, .bookmark, .lookupCount,
                                                .findInPage, .enhanceDarkMode,
                                                .newWindowButton, .closeButton,
                                                .dragInteraction, .jumpSearch]
        static let actionExtension: Features = [.bookmark, .lookupCount,
                                                .enhanceDarkMode, .jumpSearch]
    }

    // MARK: - Configuration

    struct Configuration {
        let features: Features
        let webViewConfiguration: WKWebViewConfiguration
        var headerHeight: CGFloat = 64
        var cornerRadius: CGFloat = 0
        var backgroundColor: UIColor = .secondarySystemGroupedBackground
        var headerBackgroundColor: UIColor = .tertiarySystemFill
        var titleFont: UIFont = .systemFont(ofSize: 17, weight: .semibold)
        var subtitleFont: UIFont = .systemFont(ofSize: 11)
    }

    // MARK: - Callbacks

    /// Always available — dispatched from WKNavigationDelegate.
    var onEntryLinkTapped: ((_ word: String) -> Void)?
    var onSoundLinkTapped: ((_ url: URL) -> Void)?

    /// Feature-gated callbacks (only meaningful when the corresponding feature is enabled).
    var onBookmarkTapped: ((_ isCurrentlyBookmarked: Bool) -> Void)?    // .bookmark
    var onFindTapped: (() -> Void)?                                      // .findInPage
    var onNewWindowTapped: (() -> Void)?                                 // .newWindowButton
    var onCloseTapped: (() -> Void)?                                     // .closeButton
    var onEnhanceDarkModeStrengthChanged: ((_ newStrength: EnhanceDarkModeStrength?) -> Void)? // .enhanceDarkMode
    var onDragItemRequested: (() -> UIDragItem?)?                        // .dragInteraction
    var onJumpSearch: ((_ selectedText: String) -> Void)?                // .jumpSearch

    // MARK: - Public State (read-only)

    private(set) var isBookmarked: Bool = false
    private(set) var currentDictId: String = ""

    /// Keyword to highlight after WebView finishes loading.
    /// Set by highlightKeyword(); applied in webView(_:didFinish:).
    private var pendingHighlightKeyword: String?

    // MARK: - Views

    private let containerView = UIView()
    let headerView = UIView()
    private var bookmarkButton: UIButton?
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    private var lookupCountLabel: UILabel?
    private var infoRowView: UIView?
    private(set) var webView: WKWebView!

    // Trailing toolbar buttons (optional)
    private var enhanceDarkModeButton: UIButton?
    private var findButton: UIButton?
    private var newWindowButton: UIButton?
    private var closeButton: UIButton?

    // MARK: - Private State

    private let features: Features
    private var currentZoomLevel: Int = ZoomLevel.defaultLevel
    private var enhanceStrength: EnhanceDarkModeStrength?
    private var isGridLayout: Bool = false
    private static let pendingOverlayTag = 9876
    /// Uniform size for all header toolbar buttons (bookmark, find, new-window, close).
    private static let headerButtonSize: CGFloat = 44

    // MARK: - Init

    init(configuration: Configuration) {
        self.features = configuration.features
        super.init(frame: .zero)
        buildUI(configuration: configuration)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build UI

    private func buildUI(configuration: Configuration) {
        // Container
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = configuration.cornerRadius
        containerView.layer.masksToBounds = configuration.cornerRadius > 0
        containerView.backgroundColor = configuration.backgroundColor
        addSubview(containerView)

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = configuration.headerBackgroundColor
        containerView.addSubview(headerView)

        // Bookmark button (leading) — added to headerStack below, not headerView directly
        if features.contains(.bookmark) {
            let btn = Self.makeHeaderButton(systemName: "bookmark")
            btn.addTarget(self, action: #selector(bookmarkButtonTapped), for: .touchUpInside)
            bookmarkButton = btn
        }

        // Title stack
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = configuration.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = configuration.subtitleFont
        subtitleLabel.textColor = .secondaryLabel

        let titleStackViews: [UIView] = [titleLabel, subtitleLabel]

        // Lookup count label is created here but added to a separate info row below
        if features.contains(.lookupCount) {
            let lbl = UILabel()
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.font = .italicSystemFont(ofSize: 11)
            lbl.isHidden = true
            lookupCountLabel = lbl
        }

        let titleStack = UIStackView(arrangedSubviews: titleStackViews)
        titleStack.axis = .vertical
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        // Trailing toolbar (optional)
        var toolbarButtons: [UIView] = []

        if features.contains(.enhanceDarkMode) {
            let btn = Self.makeHeaderButton(systemName: "moon.stars")
            // Single-tap shows strength picker menu (None | Dimmest…Brightest).
            let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                completion(self.enhanceDarkModeStrengthActions())
            }
            btn.menu = UIMenu(title: L10n.DictInfo.enhanceDarkMode, children: [deferred])
            btn.showsMenuAsPrimaryAction = true
            enhanceDarkModeButton = btn
            toolbarButtons.append(btn)
        }

        if features.contains(.findInPage) {
            if #available(iOS 16, *) {
                let btn = Self.makeHeaderButton(systemName: "magnifyingglass")
                btn.addTarget(self, action: #selector(findButtonTapped), for: .touchUpInside)
                findButton = btn
                toolbarButtons.append(btn)
            }
        }

        if features.contains(.newWindowButton) {
            let btn = Self.makeHeaderButton(systemName: "rectangle.badge.plus")
            btn.addTarget(self, action: #selector(newWindowButtonTapped), for: .touchUpInside)
            newWindowButton = btn
            toolbarButtons.append(btn)
        }

        if features.contains(.closeButton) {
            let btn = Self.makeHeaderButton(systemName: "xmark.circle.fill")
            btn.configurationUpdateHandler = { button in
                var config = button.configuration
                config?.baseForegroundColor = button.isHighlighted ? .systemRed : .secondaryLabel
                button.configuration = config
            }
            btn.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
            closeButton = btn
            toolbarButtons.append(btn)
        }

        // Drag interaction on header
        if features.contains(.dragInteraction) {
            let drag = UIDragInteraction(delegate: self)
            headerView.addInteraction(drag)
            headerView.isUserInteractionEnabled = true
        }

        // WebView
        let wv = WKWebView(frame: .zero, configuration: configuration.webViewConfiguration)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = self
        if features.contains(.findInPage) {
            if #available(iOS 16.0, *) {
                wv.isFindInteractionEnabled = true
            }
        }
        containerView.addSubview(wv)
        webView = wv

        // ── Header Row Layout ──
        // Compose-style:
        //   { 8, Bookmark, 8, Column{Title,Dict,Count}, 8, Spacer, 8, Find, 8, NewWin, 8, Close, 8 }
        // Implemented as a single horizontal UIStackView(spacing: 8, margins: 8).
        // Title column keeps default compression resistance (750) so it displays
        // at full intrinsic width; the spacer fills whatever space remains.

        // Flexible spacer between title column and trailing buttons
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // Assemble header items in order
        var headerItems: [UIView] = []
        if let btn = bookmarkButton { headerItems.append(btn) }
        headerItems.append(titleStack)
        headerItems.append(spacer)
        headerItems.append(contentsOf: toolbarButtons)

        let headerStack = UIStackView(arrangedSubviews: headerItems)
        headerStack.axis = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.isLayoutMarginsRelativeArrangement = true
        headerStack.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        headerView.addSubview(headerStack)

        // Info row (lookup count) — thin strip below header, hidden by default
        if features.contains(.lookupCount), let lbl = lookupCountLabel {
            let infoRow = UIView()
            infoRow.translatesAutoresizingMaskIntoConstraints = false
            infoRow.backgroundColor = .quaternarySystemFill
            infoRow.isHidden = true
            containerView.addSubview(infoRow)

            infoRow.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: infoRow.leadingAnchor, constant: 60),
                lbl.trailingAnchor.constraint(lessThanOrEqualTo: infoRow.trailingAnchor, constant: -16),
                lbl.centerYAnchor.constraint(equalTo: infoRow.centerYAnchor),
            ])

            infoRowView = infoRow
        }

        // Constraints
        let webViewTopAnchor = infoRowView?.bottomAnchor ?? headerView.bottomAnchor

        NSLayoutConstraint.activate([
            // Self → containerView
            containerView.topAnchor.constraint(equalTo: self.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: self.bottomAnchor),

            // Header
            headerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: configuration.headerHeight),

            // Header stack fills headerView
            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),

            // WebView
            webView.topAnchor.constraint(equalTo: webViewTopAnchor),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // Info row constraints (if present)
        if let infoRow = infoRowView {
            NSLayoutConstraint.activate([
                infoRow.topAnchor.constraint(equalTo: headerView.bottomAnchor),
                infoRow.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                infoRow.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                infoRow.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
    }

    // MARK: - Public: Configure

    func configure(word: String, dictName: String, dictId: String, isBookmarked: Bool) {
        titleLabel.text = word
        subtitleLabel.text = dictName
        currentDictId = dictId
        self.isBookmarked = isBookmarked
        updateBookmarkAppearance()
    }

    func prepareForReuse() {
        onEntryLinkTapped = nil
        onSoundLinkTapped = nil
        onBookmarkTapped = nil
        onFindTapped = nil
        onNewWindowTapped = nil
        onCloseTapped = nil
        onDragItemRequested = nil
        onJumpSearch = nil
        onEnhanceDarkModeStrengthChanged = nil
        isBookmarked = false
        enhanceStrength = nil
        isGridLayout = false
        currentDictId = ""
        pendingHighlightKeyword = nil
        updateBookmarkAppearance()
        updateEnhanceDarkModeButtonAppearance()
        lookupCountLabel?.isHidden = true
        infoRowView?.isHidden = true
        removePendingOverlay()
    }

    // MARK: - Public: State

    func setBookmarked(_ flag: Bool) {
        isBookmarked = flag
        updateBookmarkAppearance()
    }

    func setLookupCount(_ count: Int) {
        guard let label = lookupCountLabel else { return }
        if count > 0, UserDefaults.shared.showLookupCount {
            label.text = L10n.Articles.lookupCount(count)
            label.textColor = lookupCountColor(for: count)
            label.isHidden = false
            infoRowView?.isHidden = false
        } else {
            label.isHidden = true
            infoRowView?.isHidden = true
        }
    }

    func setZoomLevel(_ level: Int) {
        currentZoomLevel = level
        let js = "document.body.style.fontSize = '\(level)%';"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func setGridLayout(_ grid: Bool) {
        isGridLayout = grid
        updateEnhanceDarkModeButtonVisibility()
    }

    func setDarkModeEnhance(strength: EnhanceDarkModeStrength?) {
        enhanceStrength = strength
        webView.overrideUserInterfaceStyle = strength != nil ? .light : .unspecified
        applyDarkModeFilter()
        updateEnhanceDarkModeButtonAppearance()
        updateEnhanceDarkModeButtonVisibility()
    }

    /// Inject or remove a **gamma-aware invert** filter on the HTML element.
    ///
    /// Uses an inline SVG `feComponentTransfer` with a precomputed lookup table
    /// so that the inversion is **perceptually uniform** — background hierarchy
    /// levels stay visually distinguishable in the dark end (where `invert(1)`
    /// flattens everything due to the sRGB gamma curve).
    ///
    /// Images/video/SVG get a double-application of the same filter to restore
    /// their original colors.  The `.dir` element (preset-dict language flags
    /// with emoji) is also double-inverted to keep emoji colors correct.
    ///
    /// Legacy `<font color>` attributes are stripped so text inherits the
    /// inverted body color.
    private func applyDarkModeFilter() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        if let strength = enhanceStrength, isDark {
            let table = strength.svgTableValues
            let js = """
            (function(){
                var svg = document.getElementById('_omdict_svg');
                if (!svg) {
                    svg = document.createElementNS('http://www.w3.org/2000/svg','svg');
                    svg.id = '_omdict_svg';
                    svg.setAttribute('style','position:absolute;width:0;height:0;overflow:hidden');
                    document.body.insertBefore(svg, document.body.firstChild);
                }
                svg.innerHTML = '<filter id="_gi" color-interpolation-filters="sRGB">'
                    + '<feComponentTransfer>'
                    + '<feFuncR type="table" tableValues="\(table)"/>'
                    + '<feFuncG type="table" tableValues="\(table)"/>'
                    + '<feFuncB type="table" tableValues="\(table)"/>'
                    + '</feComponentTransfer></filter>';

                var s = document.getElementById('_omdict_invert');
                if (!s) { s = document.createElement('style'); s.id = '_omdict_invert'; document.head.appendChild(s); }
                s.textContent = 'html{filter:url(#_gi) hue-rotate(180deg);background:#fff !important}'
                    + 'body{color:#000 !important}'
                    + 'img,video,svg:not(#_omdict_svg),picture{filter:url(#_gi) hue-rotate(180deg)}'
                    + '.dir{display:inline-block;filter:url(#_gi) hue-rotate(180deg)}';
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            let js = """
            (function(){
                var s = document.getElementById('_omdict_invert');
                if (s) s.remove();
                var svg = document.getElementById('_omdict_svg');
                if (svg) svg.remove();
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            if enhanceStrength != nil {
                applyDarkModeFilter()
            }
            updateEnhanceDarkModeButtonVisibility()
        }
    }

    // MARK: - Public: Content

    func loadHTMLContent(_ html: String, baseURL: URL? = nil) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func showPendingOverlay(word: String, dictName: String) {
        guard features.contains(.pendingOverlay) else { return }
        guard containerView.viewWithTag(Self.pendingOverlayTag) == nil else { return }
        let overlay = ArticlePlaceholderView.loading(word: word, dictName: dictName)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.tag = Self.pendingOverlayTag
        overlay.backgroundColor = containerView.backgroundColor == .clear
            ? .systemBackground
            : containerView.backgroundColor
        containerView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: webView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
    }

    func removePendingOverlay() {
        containerView.viewWithTag(Self.pendingOverlayTag)?.removeFromSuperview()
    }

    // MARK: - Public: Interaction

    func setWebViewInteractive(_ interactive: Bool) {
        webView.isUserInteractionEnabled = interactive
        containerView.alpha = interactive ? 1.0 : 0.95
    }

    /// Hide or show the Find in Page header button.
    /// Called by ArticleCell when layout switches to/from grid mode.
    func setFindInPageHidden(_ hidden: Bool) {
        findButton?.isHidden = hidden
    }

    func isPointInHeader(_ point: CGPoint) -> Bool {
        let pointInContainer = convert(point, to: containerView)
        return headerView.frame.contains(pointInContainer)
    }

    @available(iOS 16.0, *)
    func presentFind() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    @available(iOS 16.0, *)
    func dismissFind() {
        webView.findInteraction?.dismissFindNavigator()
    }

    var isFindNavigatorVisible: Bool {
        guard #available(iOS 16.0, *) else { return false }
        return webView.findInteraction?.isFindNavigatorVisible ?? false
    }

    func highlightKeyword(_ keyword: String?) {
        pendingHighlightKeyword = keyword
        let escaped = (keyword ?? "").replacingOccurrences(of: "'", with: "\\'")
        let js = "highlightKeyword('\(escaped)')"
        webView.evaluateJavaScript(js) { _, _ in }
    }

    // MARK: - Static: Jump Search Menu

    /// Register the "Jump Search" menu item globally.
    /// On iOS < 26: UIMenuItem (no icon support — API limitation).
    /// On iOS 26+: injected via buildMenu(with:) with SF Symbol icon instead.
    static func registerJumpSearchMenuItem() {
        if #available(iOS 26, *) {
            // Jump Search is provided via buildMenu(with:) override below
        } else {
            let item = UIMenuItem(title: L10n.Articles.jumpSearch, action: #selector(jumpSearchAction(_:)))
            UIMenuController.shared.menuItems = [item]
        }
    }

    // MARK: - Private: Header Button Factory

    /// Create a uniformly-sized header toolbar button (44×44 touch target).
    private static func makeHeaderButton(systemName: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)
        config.baseForegroundColor = .secondaryLabel
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: headerButtonSize),
            btn.heightAnchor.constraint(equalToConstant: headerButtonSize),
        ])
        return btn
    }

    // MARK: - Private: Bookmark Appearance

    private func updateBookmarkAppearance() {
        guard let btn = bookmarkButton else { return }
        var config = btn.configuration
        let imageName = isBookmarked ? "bookmark.fill" : "bookmark"
        config?.image = UIImage(systemName: imageName)
        config?.baseForegroundColor = isBookmarked ? nil : .secondaryLabel
        btn.configuration = config
    }

    // MARK: - Private: Lookup Count Color

    private func lookupCountColor(for count: Int) -> UIColor {
        switch count {
        case 15...:   return .systemRed
        case 10..<15: return .systemOrange
        case 6..<10:  return .systemBrown
        case 3..<6:   return .secondaryLabel
        default:      return .tertiaryLabel
        }
    }

    // MARK: - Private: Button Actions

    @objc private func bookmarkButtonTapped() {
        onBookmarkTapped?(isBookmarked)
    }

    @objc private func findButtonTapped() {
        onFindTapped?()  // Notify consumer (e.g. dismiss other finds)
        if #available(iOS 16.0, *) {
            presentFind()
        }
    }

    @objc private func newWindowButtonTapped() {
        onNewWindowTapped?()
    }

    @objc private func closeButtonTapped() {
        onCloseTapped?()
    }

    /// Build menu elements for the enhance dark mode strength picker.
    /// "None" sits alone at top; 7 tiers (dimmest…brightest) appear below a
    /// separator, achieved via `.displayInline` submenu.
    private func enhanceDarkModeStrengthActions() -> [UIMenuElement] {
        let current = enhanceStrength

        // "None" = turn off enhancement
        let noneAction = UIAction(
            title: L10n.Detail.enhanceDarkModeNone,
            state: current == nil ? .on : .off
        ) { [weak self] _ in
            guard let self, self.enhanceStrength != nil else { return }
            self.onEnhanceDarkModeStrengthChanged?(nil)
        }

        // 7 tiers: dimmest … brightest.
        // Icons: negative tiers use outline circles (N.circle),
        // standard uses ±, positive tiers use filled circles (N.circle.fill).
        let tierEntries: [(EnhanceDarkModeStrength, String, String)] = [
            (.dimmest,   L10n.Detail.enhanceDimmest,  "3.circle"),
            (.dimmer,    L10n.Detail.enhanceDimmer,    "2.circle"),
            (.dim,       L10n.Detail.enhanceDim,       "1.circle"),
            (.standard,  L10n.Detail.enhanceStandard,  "minus.forwardslash.plus"),
            (.bright,    L10n.Detail.enhanceBright,    "1.circle.fill"),
            (.brighter,  L10n.Detail.enhanceBrighter,  "2.circle.fill"),
            (.brightest, L10n.Detail.enhanceBrightest, "3.circle.fill"),
        ]
        let tierActions = tierEntries.map { tier, label, icon in
            UIAction(
                title: label,
                image: UIImage(systemName: icon),
                state: current == tier ? .on : .off
            ) { [weak self] _ in
                guard let self, self.enhanceStrength != tier else { return }
                self.onEnhanceDarkModeStrengthChanged?(tier)
            }
        }

        // Inline submenu renders as a separator between "None" and the tiers.
        let tiersGroup = UIMenu(title: "", options: .displayInline, children: tierActions)
        return [noneAction, tiersGroup]
    }

    private func updateEnhanceDarkModeButtonAppearance() {
        guard let btn = enhanceDarkModeButton else { return }
        var config = btn.configuration
        let isOn = enhanceStrength != nil
        config?.image = UIImage(systemName: isOn ? "moon.stars.fill" : "moon.stars")
        config?.baseForegroundColor = isOn ? .systemYellow : .secondaryLabel
        btn.configuration = config
    }

    func updateEnhanceDarkModeButtonVisibility() {
        guard let btn = enhanceDarkModeButton else { return }
        let isDark = traitCollection.userInterfaceStyle == .dark
        btn.isHidden = isGridLayout || !isDark || !UserDefaults.shared.showEnhanceDarkMode
    }
}

// MARK: - WKNavigationDelegate

extension ArticlePageView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "entry":
            let targetWord = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !targetWord.isEmpty {
                onEntryLinkTapped?(targetWord)
            }
            decisionHandler(.cancel)

        case "sound":
            onSoundLinkTapped?(url)
            decisionHandler(.cancel)

        case "about":
            decisionHandler(.allow)

        default:
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Apply zoom to this page if non-default
        if currentZoomLevel != ZoomLevel.defaultLevel {
            let js = "document.body.style.fontSize = '\(currentZoomLevel)%';"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // Apply dark mode filter if enabled for this dictionary
        if enhanceStrength != nil {
            applyDarkModeFilter()
        }

        // Apply pending highlight keyword (set before WebView finished loading)
        if let keyword = pendingHighlightKeyword, !keyword.isEmpty {
            let escaped = keyword.replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("highlightKeyword('\(escaped)')") { _, _ in }
        }
    }
}

// MARK: - UIDragInteractionDelegate

extension ArticlePageView: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let item = onDragItemRequested?() else { return [] }
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
        let params = UIDragPreviewParameters()
        params.visiblePath = UIBezierPath(roundedRect: containerView.bounds, cornerRadius: containerView.layer.cornerRadius)
        return UITargetedDragPreview(view: containerView, parameters: params)
    }
}

// MARK: - Jump Search (UIMenuController responder chain)

extension ArticlePageView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(jumpSearchAction(_:)) {
            // On iOS 26+, Jump Search is injected via buildMenu — suppress UIMenuItem path
            if #available(iOS 26, *) { return false }
            return features.contains(.jumpSearch) && onJumpSearch != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func jumpSearchAction(_ sender: Any?) {
        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            if let text = result as? String, !text.isEmpty {
                self?.onJumpSearch?(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: - iOS 26+ Context Menu (with icon)

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard #available(iOS 26, *),
              builder.system == .context,
              features.contains(.jumpSearch),
              onJumpSearch != nil else { return }
        let action = UIAction(
            title: L10n.Articles.jumpSearch,
            image: UIImage(systemName: "sparkle.magnifyingglass")
        ) { [weak self] _ in
            self?.jumpSearchAction(nil)
        }
        builder.insertChild(
            UIMenu(options: .displayInline, children: [action]),
            atEndOfMenu: .root
        )
    }
}

// MARK: - Configuration Presets

extension ArticlePageView.Configuration {
    /// Compact pager pages (ArticleViewController) — 64pt header, no rounded corners.
    /// On iPad (supportsMultipleScenes), includes the "Open in New Window" button;
    /// on iPhone, the button is omitted because multi-scene is not available.
    static func compactPager(webViewConfig: WKWebViewConfiguration) -> Self {
        .init(features: .compactPager, webViewConfiguration: webViewConfig)
    }

    /// Regular collection view cells (ArticleCell) — 46pt header, rounded corners.
    /// 46pt accommodates 2 lines (title + subtitle). Lookup count is in a separate info row.
    static func regularCell(webViewConfig: WKWebViewConfiguration) -> Self {
        .init(features: .regularCell, webViewConfiguration: webViewConfig,
              headerHeight: 46, cornerRadius: 12,
              titleFont: .systemFont(ofSize: 15, weight: .semibold),
              subtitleFont: .systemFont(ofSize: 12))
    }

    /// Action Extension pager pages (ActionViewController) — 64pt header, no toolbar buttons.
    static func actionExtension(webViewConfig: WKWebViewConfiguration) -> Self {
        .init(features: .actionExtension, webViewConfiguration: webViewConfig)
    }
}
