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
    /// `fragment` carries the `#anchor` part of `entry://word#anchor` so the
    /// caller can scroll the target article into view at that DOM id after it
    /// loads.  nil when the URL has no fragment.
    var onEntryLinkTapped: ((_ word: String, _ fragment: String?) -> Void)?
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

    /// In-page anchor id (from `entry://word#anchor` cross-references) to
    /// scroll into view after the WebView finishes loading.  Set by
    /// `scrollToAnchor(_:)` when the page is mid-load; consumed in
    /// `webView(_:didFinish:)`.
    private var pendingScrollAnchorId: String?

    /// Most recently applied anchor id.  Dedupes repeat `scrollToAnchor`
    /// calls (cell recycling, configure() churn) so the user doesn't see
    /// the page jump-scroll on every re-render.
    private var lastAppliedAnchorId: String?

    /// True once `webView(_:didFinish:)` has fired for the current load.
    /// Reset to `false` in `loadHTMLContent(_:baseURL:)` and `prepareForReuse()`.
    /// Drives whether `scrollToAnchor(_:)` can apply immediately vs. has to
    /// stash a pending value for didFinish to consume.
    private var didFinishLoading = false

    // MARK: - Find Highlight (pure DOM, outside CSS filter)
    //
    // The dark mode CSS filter is scoped to #_omdict_content.
    // Find elements (#_omdict_find) are siblings — NOT filtered.
    // JS handles everything: dim overlay + positioned yellow spans
    // with copied font metrics.  Swift just calls JS and validates
    // the generation counter to discard stale async callbacks.

    /// Generation counter — stale JS callbacks are discarded.
    private var findGeneration: UInt = 0

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

    // MARK: - Colors

    /// Resolve a dynamic color at the **base** user-interface level.
    ///
    /// Pages hosted in an elevated context — the Action Extension sheet, or any
    /// modal presentation — would otherwise get the *elevated* dark-mode
    /// variant of the system background (e.g. `#2C2C2E` instead of `#1C1C1E`).
    /// The enhance-dark-mode filter maps a white article background to a fixed
    /// floor tone (`EnhanceDarkModeStrength.floor`, `#1C1C1C` at the standard
    /// tier) that is calibrated against the base-level color, so an elevated
    /// container shows through the 12 px body margin as a visibly lighter
    /// frame around the article. Pinning the level keeps the page looking the
    /// same wherever it is presented.
    private static func baseLevelColor(_ color: UIColor) -> UIColor {
        UIColor { traits in
            let base = UITraitCollection(traitsFrom: [
                traits, UITraitCollection(userInterfaceLevel: .base)
            ])
            return color.resolvedColor(with: base)
        }
    }

    // MARK: - Build UI

    private func buildUI(configuration: Configuration) {
        // Container
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = configuration.cornerRadius
        containerView.layer.masksToBounds = configuration.cornerRadius > 0
        containerView.backgroundColor = Self.baseLevelColor(configuration.backgroundColor)
        addSubview(containerView)

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = Self.baseLevelColor(configuration.headerBackgroundColor)
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
            btn.addTarget(self, action: #selector(enhanceButtonTapped(_:)), for: .touchUpInside)
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
        filtersInjected = false
        isGridLayout = false
        currentDictId = ""
        pendingHighlightKeyword = nil
        pendingScrollAnchorId = nil
        lastAppliedAnchorId = nil
        didFinishLoading = false
        clearFindHighlights()
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
    /// Whether the full set of SVG filters has been injected into the current page.
    private var filtersInjected = false

    /// Injects all 7 SVG filter pairs + CSS rules at once, and immediately
    /// activates the given tier.  Everything happens in a single
    /// `evaluateJavaScript` call so there is no race between injection and
    /// activation.  Subsequent tier switches only need `applyDarkModeTier(_:)`.
    private func injectAllDarkModeFilters(activating tier: EnhanceDarkModeStrength) {
        var svgFilters = ""
        var css = ""
        for t in EnhanceDarkModeStrength.allTiers {
            let tag = t.filterTag
            let fwd = t.svgTableValues
            let rev = t.svgReverseTableValues
            svgFilters += "<filter id=\"_gi_\(tag)\" color-interpolation-filters=\"sRGB\">"
                + "<feComponentTransfer>"
                + "<feFuncR type=\"table\" tableValues=\"\(fwd)\"/>"
                + "<feFuncG type=\"table\" tableValues=\"\(fwd)\"/>"
                + "<feFuncB type=\"table\" tableValues=\"\(fwd)\"/>"
                + "</feComponentTransfer></filter>"
                + "<filter id=\"_gi_r_\(tag)\" color-interpolation-filters=\"sRGB\">"
                + "<feComponentTransfer>"
                + "<feFuncR type=\"table\" tableValues=\"\(rev)\"/>"
                + "<feFuncG type=\"table\" tableValues=\"\(rev)\"/>"
                + "<feFuncB type=\"table\" tableValues=\"\(rev)\"/>"
                + "</feComponentTransfer></filter>"
            let revert = "filter:url(#_gi_r_\(tag)) hue-rotate(180deg)"
            let sel = "html[data-enhance=\"\(tag)\"] #_omdict_content"
            css += "\(sel){filter:url(#_gi_\(tag)) hue-rotate(180deg);background:#fff !important;color:#000 !important}"
                + "\(sel) img,\(sel) video,\(sel) svg:not(#_omdict_svg),\(sel) picture{\(revert)}"
                + "\(sel) .dir{display:inline-block;\(revert)}"
        }
        let activeTag = tier.filterTag
        let js = "(function(){"
            + "var c=document.getElementById('_omdict_content');"
            + "if(!c){c=document.createElement('div');c.id='_omdict_content';"
            + "while(document.body.firstChild)c.appendChild(document.body.firstChild);"
            + "document.body.insertBefore(c,document.body.firstChild);}"
            + "var svg=document.getElementById('_omdict_svg');"
            + "if(!svg){svg=document.createElementNS('http://www.w3.org/2000/svg','svg');"
            + "svg.id='_omdict_svg';"
            + "svg.setAttribute('style','position:absolute;width:0;height:0;overflow:hidden');"
            + "c.insertBefore(svg,c.firstChild);}"
            + "svg.innerHTML='\(svgFilters)';"
            + "var s=document.getElementById('_omdict_invert');"
            + "if(!s){s=document.createElement('style');s.id='_omdict_invert';document.head.appendChild(s);}"
            + "s.textContent='\(css)';"
            + "document.documentElement.setAttribute('data-enhance','\(activeTag)');"
            + "})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
        filtersInjected = true
    }

    /// Tiny JS call — just sets/removes a data attribute on <html>.
    private func applyDarkModeTier(_ strength: EnhanceDarkModeStrength?) {
        if let strength {
            webView.evaluateJavaScript(
                "document.documentElement.setAttribute('data-enhance','\(strength.filterTag)')",
                completionHandler: nil
            )
        } else {
            webView.evaluateJavaScript(
                "document.documentElement.removeAttribute('data-enhance')",
                completionHandler: nil
            )
        }
    }

    private func applyDarkModeFilter() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        if let strength = enhanceStrength, isDark {
            if !filtersInjected {
                // First time — inject all filters AND activate tier in one JS call.
                injectAllDarkModeFilters(activating: strength)
            } else {
                // Filters already present — just switch the data attribute.
                applyDarkModeTier(strength)
            }
        } else {
            let js = """
            (function(){
                document.documentElement.removeAttribute('data-enhance');
                var s = document.getElementById('_omdict_invert');
                if (s) s.remove();
                var svg = document.getElementById('_omdict_svg');
                if (svg) svg.remove();
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            filtersInjected = false
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
        didFinishLoading = false  // didFinish will set true after this load completes
        // Use `load(_:mimeType:characterEncodingName:baseURL:)` instead of
        // `loadHTMLString` to force UTF-8 decoding.  On iOS, loadHTMLString
        // does NOT reliably honor the `<meta charset>` declaration — it
        // interprets the bytes as Latin-1, which mojibake's UTF-8 sequences
        // (middle-dot keywords showed up in the DOM as `Â·` instead
        // of `·`, breaking cross-ref lookup).  The explicit-encoding load
        // API tells WebKit unambiguously to decode as UTF-8.
        let data = html.data(using: .utf8) ?? Data()
        webView.load(
            data,
            mimeType: "text/html",
            characterEncodingName: "utf-8",
            baseURL: baseURL ?? URL(string: "about:blank")!
        )
    }

    /// Scroll to an in-page anchor id (set from an `entry://word#anchor`
    /// cross-reference).  Handles both navigation phases transparently:
    ///   - WebView already finished loading → applies JS immediately.
    ///   - WebView still loading → stashes; `didFinish` consumes.
    /// Passing nil clears any pending scroll without affecting the current
    /// scroll position.  Idempotent: re-calling with the same id is a no-op
    /// (avoids re-scroll on cell recycle).
    func scrollToAnchor(_ anchorId: String?) {
        guard let anchorId, !anchorId.isEmpty else {
            pendingScrollAnchorId = nil
            return
        }
        guard anchorId != lastAppliedAnchorId else { return }

        if didFinishLoading {
            applyScrollAnchorJS(anchorId)
            lastAppliedAnchorId = anchorId
        } else {
            pendingScrollAnchorId = anchorId
        }
    }

    /// JSONEncoder gives us a safely-escaped JS string literal — anchor ids
    /// from MDX articles can contain `#`, dots, quotes, slashes, etc., so
    /// we never want to hand-roll string concatenation here.
    private func applyScrollAnchorJS(_ anchorId: String) {
        guard let data = try? JSONEncoder().encode(anchorId),
              let jsArg = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function(id) {
          var el = document.getElementById(id);
          if (el) el.scrollIntoView({behavior: 'smooth', block: 'start'});
        })(\(jsArg));
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
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
        clearFindHighlights()

        guard let keyword, !keyword.isEmpty else { return }

        findGeneration &+= 1
        let gen = findGeneration

        let escaped = keyword.replacingOccurrences(of: "'", with: "\\'")
        let js = "highlightKeyword('\(escaped)')"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            // Discard stale callback (user typed faster than JS responded)
            guard let self, self.findGeneration == gen else { return }
            // JS handles everything — dim + highlights are in the DOM.
            // Result is rect JSON but we don't need it on the Swift side.
            _ = result
        }
    }

    /// Remove all find-in-page DOM elements (dim + highlights + invisible marks).
    private func clearFindHighlights() {
        findGeneration &+= 1  // invalidate any in-flight JS callbacks
        webView?.evaluateJavaScript("highlightKeyword('')", completionHandler: nil)
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

    @objc private func enhanceButtonTapped(_ sender: UIButton) {
        guard let parentVC = sequence(first: self as UIResponder, next: { $0.next })
                .compactMap({ $0 as? UIViewController }).first else { return }

        let sliderVC = EnhanceDarkModeSliderVC(
            current: enhanceStrength,
            onPreview: { [weak self] strength in
                // Real-time preview while dragging — apply filter without persisting.
                // On iOS 17 this updates the WebView in real time; on iOS 16/18/26,
                // WKWebView defers evaluateJavaScript during UITrackingRunLoopMode,
                // so the visual update happens on finger lift (sliderEnded fallback).
                guard let self else { return }
                self.enhanceStrength = strength
                let desired: UIUserInterfaceStyle = strength != nil ? .light : .unspecified
                if self.webView.overrideUserInterfaceStyle != desired {
                    self.webView.overrideUserInterfaceStyle = desired
                }
                self.applyDarkModeFilter()
                self.updateEnhanceDarkModeButtonAppearance()
            },
            onCommit: { [weak self] strength in
                // Persist final value on popover dismiss.
                self?.onEnhanceDarkModeStrengthChanged?(strength)
            }
        )

        // Wrap in UINavigationController for a centered title bar.
        let nav = UINavigationController(rootViewController: sliderVC)
        nav.modalPresentationStyle = .popover
        nav.preferredContentSize = sliderVC.fittingSize
        if let popover = nav.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = sliderVC
        }
        parentVC.present(nav, animated: true)
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
            // Always parse via absoluteString + UTF-8 percent-decode — see
            // `parseEntryNavigation` for the iOS `URL.host` Latin-1 mojibake
            // gotcha.  HTML-side UTF-8 enforcement happens in
            // `loadHTMLContent` (explicit characterEncodingName:"utf-8");
            // both fixes together fix the `entry://bank · n.` round-trip.
            let (targetWord, fragment) = Self.parseEntryNavigation(url)
            if !targetWord.isEmpty {
                onEntryLinkTapped?(targetWord, fragment)
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
            } else if scheme == AppIdentifiers.ResourceScheme.scheme,
                      url.fragment != nil,
                      url.host == webView.url?.host {
                // Same-document in-page anchor jump (e.g. <a href="#sense2">).
                // The article now loads under an `mdict://<dictId>/` base URL
                // (so `@font-face` fonts are same-origin), which makes such
                // relative links resolve to the mdict scheme instead of
                // about:blank. Allow them so WebKit scrolls within the page
                // rather than cancelling the navigation.
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoading = true

        // Apply zoom to this page if non-default
        if currentZoomLevel != ZoomLevel.defaultLevel {
            let js = "document.body.style.fontSize = '\(currentZoomLevel)%';"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // Apply dark mode filter if enabled for this dictionary.
        // Reset filtersInjected so the full SVG+CSS payload is re-injected
        // into this freshly loaded page.
        filtersInjected = false
        if enhanceStrength != nil {
            applyDarkModeFilter()
        }

        // Apply pending highlight keyword (set before WebView finished loading)
        if let keyword = pendingHighlightKeyword, !keyword.isEmpty {
            highlightKeyword(keyword)
        }

        // Apply pending anchor scroll (set by scrollToAnchor before this load
        // completed — e.g. cross-reference click navigating to a fresh article).
        if let anchorId = pendingScrollAnchorId {
            pendingScrollAnchorId = nil
            applyScrollAnchorJS(anchorId)
            lastAppliedAnchorId = anchorId
        }
    }

    /// Extract (word, fragment) from an `entry://` URL.
    ///
    /// Parses via `absoluteString` + `removingPercentEncoding` instead of
    /// `URL.host` for two reasons:
    ///
    /// 1. **Lenient grammar**: `URL(string:)` rejects unencoded spaces, so a
    ///    raw `<a href="entry://bank · n.">` that slipped through unencoded
    ///    would have `URL.host == nil`.  The absoluteString path doesn't
    ///    care about URL grammar — it just works on whatever bytes WebKit
    ///    handed us.
    /// 2. **UTF-8 percent-decoding**: `removingPercentEncoding` is explicitly
    ///    UTF-8, which is what we want for MDX keys that legitimately
    ///    contain non-ASCII chars (a `·` middle-dot homograph
    ///    disambiguator is the trigger case).
    ///
    /// Returns ("", nil) when there's nothing parseable after `entry://`.
    static func parseEntryNavigation(_ url: URL) -> (word: String, fragment: String?) {
        let raw = url.absoluteString
        let stripped: String = {
            if raw.lowercased().hasPrefix("entry://") {
                return String(raw.dropFirst("entry://".count))
            }
            return raw
        }()
        let decoded = stripped.removingPercentEncoding ?? stripped
        if let hashIdx = decoded.firstIndex(of: "#") {
            let word = String(decoded[..<hashIdx])
            let frag = String(decoded[decoded.index(after: hashIdx)...])
            return (word, frag.isEmpty ? nil : frag)
        }
        return (decoded, nil)
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

// MARK: - Enhance Dark Mode Slider Popover (PoC)

/// Compact popover with `.insetGrouped` table for per-dict enhance dark mode.
///
/// Layout (always two sections, stateless height):
///   ╭─ Dark Enhancements ─────────────────╮
///   │  Enabled                       [ON]  │
///   ╰──────────────────────────────────────╯
///   ╭──────────────────────────────────────╮
///   │  Adjustment              « Bright »  │
///   │  Dim ━━━━━━━━━━━●━━━━━━━━━ Bright    │
///   ╰──────────────────────────────────────╯
///
/// When disabled, the slider and adjustment label are dimmed (`isEnabled = false`)
/// but remain visible so the popover height never changes.
/// Real-time preview via `onPreview` during drag; persists via `onCommit` on dismiss.
final class EnhanceDarkModeSliderVC: UITableViewController, UIPopoverPresentationControllerDelegate {

    private let initialStrength: EnhanceDarkModeStrength?
    private var currentStrength: EnhanceDarkModeStrength?
    private let onPreview: (EnhanceDarkModeStrength?) -> Void
    private let onCommit: (EnhanceDarkModeStrength?) -> Void

    // --- Reusable controls (stored to read/write state) ---
    private let enabledSwitch = UISwitch()
    private weak var adjustmentDetailLabel: UILabel?
    private let slider = UISlider()
    /// Stored for dimming when switch is off.
    private weak var adjustmentTextLabel: UILabel?
    private weak var dimLabel: UILabel?
    private weak var brightLabel: UILabel?

    private enum Section: Int, CaseIterable {
        case toggle = 0
        case adjustment = 1
    }
    private enum AdjustmentRow: Int, CaseIterable {
        case label = 0
        case slider = 1
    }

    private var isOn: Bool { currentStrength != nil }

    private static let popoverWidth: CGFloat = 300
    // Hardcoded — contentSize is unreliable before popover presentation.
    // navBar(44) + s0 header(12) + switch row(44) + s0 footer(~28 for description)
    // + s1 header(8) + label row(44) + slider row(44) + s1 footer(8) = 232.
    // Liquid Glass (iOS 26+) needs +16 for taller nav bar chrome.
    private static let popoverHeight: CGFloat = {
        if #available(iOS 26, *) { return 248 }
        return 232
    }()

    init(current: EnhanceDarkModeStrength?,
         onPreview: @escaping (EnhanceDarkModeStrength?) -> Void,
         onCommit: @escaping (EnhanceDarkModeStrength?) -> Void) {
        self.initialStrength = current
        self.currentStrength = current
        self.onPreview = onPreview
        self.onCommit = onCommit
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingSize: CGSize {
        CGSize(width: Self.popoverWidth, height: Self.popoverHeight)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.Detail.enhanceDarkModeTitle

        tableView.isScrollEnabled = false
        tableView.cellLayoutMarginsFollowReadableWidth = false

        // --- Configure controls once ---
        enabledSwitch.isOn = isOn
        enabledSwitch.addTarget(self, action: #selector(switchToggled(_:)), for: .valueChanged)

        slider.minimumValue = 0
        slider.maximumValue = Float(EnhanceDarkModeStrength.allTiers.count - 1)
        if let s = currentStrength, let idx = EnhanceDarkModeStrength.allTiers.firstIndex(of: s) {
            slider.value = Float(idx)
        } else {
            slider.value = Float(EnhanceDarkModeStrength.allTiers.firstIndex(of: .standard) ?? 3)
        }
        slider.isEnabled = isOn
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded(_:)), for: [.touchUpInside, .touchUpOutside])
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count  // always 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .toggle:     return 1
        case .adjustment: return AdjustmentRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .toggle:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = L10n.Detail.enhanceDarkModeEnabled
            cell.accessoryView = enabledSwitch
            cell.selectionStyle = .none
            return cell

        case .adjustment:
            switch AdjustmentRow(rawValue: indexPath.row)! {
            case .label:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = L10n.Detail.enhanceDarkModeAdjustment
                cell.selectionStyle = .none
                adjustmentTextLabel = cell.textLabel
                adjustmentDetailLabel = cell.detailTextLabel
                updateAdjustmentLabel()
                updateSliderEnabledAppearance()
                return cell

            case .slider:
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.selectionStyle = .none

                let dim = UILabel()
                dim.text = L10n.Detail.enhanceDim
                dim.font = .preferredFont(forTextStyle: .caption1)
                dim.textColor = .tertiaryLabel
                dim.setContentHuggingPriority(.required, for: .horizontal)
                self.dimLabel = dim

                let bright = UILabel()
                bright.text = L10n.Detail.enhanceBright
                bright.font = .preferredFont(forTextStyle: .caption1)
                bright.textColor = .tertiaryLabel
                bright.setContentHuggingPriority(.required, for: .horizontal)
                self.brightLabel = bright

                let stack = UIStackView(arrangedSubviews: [dim, slider, bright])
                stack.axis = .horizontal
                stack.spacing = 8
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false

                cell.contentView.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 6),
                    stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -6),
                    stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                    stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                ])
                updateSliderEnabledAppearance()
                return cell
            }
        }
    }

    // MARK: - Section spacing (compact popover, minimize "chin")

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 12 : 8
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        section == 0 ? UITableView.automaticDimension : 8
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { UIView() }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard section == 0 else { return UIView() }
        // Section 0 footer: explains the purpose of the enhancement.
        let footer = UITableViewHeaderFooterView()
        var config = footer.defaultContentConfiguration()
        config.text = L10n.Detail.enhanceDarkModeDescription
        config.textProperties.font = .preferredFont(forTextStyle: .caption1)
        config.textProperties.color = .secondaryLabel
        config.textProperties.transform = .none  // suppress insetGrouped default uppercase
        footer.contentConfiguration = config
        return footer
    }

    // MARK: - Tier display names

    private func tierDisplayName(for strength: EnhanceDarkModeStrength) -> String {
        switch strength {
        case .dimmest:  return L10n.Detail.enhanceDimmest
        case .dimmer:   return L10n.Detail.enhanceDimmer
        case .dim:      return L10n.Detail.enhanceDim
        case .standard: return L10n.Detail.enhanceStandard
        case .bright:   return L10n.Detail.enhanceBright
        case .brighter: return L10n.Detail.enhanceBrighter
        case .brightest: return L10n.Detail.enhanceBrightest
        }
    }

    // MARK: - Actions

    @objc private func switchToggled(_ sender: UISwitch) {
        if sender.isOn {
            // Slider position is the source of truth — it never moves on toggle.
            let idx = Int(slider.value.rounded())
            let clamped = min(max(idx, 0), EnhanceDarkModeStrength.allTiers.count - 1)
            currentStrength = EnhanceDarkModeStrength.allTiers[clamped]
        } else {
            currentStrength = nil
        }
        updateAdjustmentLabel()
        updateSliderEnabledAppearance()
        onPreview(currentStrength)
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        let idx = Int(sender.value.rounded())
        let clamped = min(max(idx, 0), EnhanceDarkModeStrength.allTiers.count - 1)
        let strength = EnhanceDarkModeStrength.allTiers[clamped]
        guard strength != currentStrength else { return }
        currentStrength = strength
        updateAdjustmentLabel()
        onPreview(strength)
    }

    @objc private func sliderEnded(_ sender: UISlider) {
        let idx = Int(sender.value.rounded())
        let clamped = Float(min(max(idx, 0), EnhanceDarkModeStrength.allTiers.count - 1))
        UIView.animate(withDuration: 0.15) {
            sender.setValue(clamped, animated: true)
        }
    }

    private func updateAdjustmentLabel() {
        let idx = Int(slider.value.rounded())
        let clamped = min(max(idx, 0), EnhanceDarkModeStrength.allTiers.count - 1)
        adjustmentDetailLabel?.text = tierDisplayName(for: EnhanceDarkModeStrength.allTiers[clamped])
    }

    /// Dim/undim the adjustment section based on the enabled switch.
    private func updateSliderEnabledAppearance() {
        let enabled = isOn
        slider.isEnabled = enabled
        let textColor: UIColor = enabled ? .label : .tertiaryLabel
        let detailColor: UIColor = enabled ? .secondaryLabel : .tertiaryLabel
        adjustmentTextLabel?.textColor = textColor
        adjustmentDetailLabel?.textColor = detailColor
        dimLabel?.textColor = enabled ? .tertiaryLabel : .quaternaryLabel
        brightLabel?.textColor = enabled ? .tertiaryLabel : .quaternaryLabel
    }

    // MARK: - Popover delegate

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if currentStrength != initialStrength {
            onCommit(currentStrength)
        }
    }
}
