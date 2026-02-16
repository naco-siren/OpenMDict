//
//  ActionViewController.swift
//  OpenMDict-ActionExtension
//
//  Action Extension entry point. Presents a half-screen sheet showing
//  the first dictionary's definition for the user-selected text.
//
//  Lifecycle:
//  1. viewDidLoad  — set up nav bar + loading spinner + sheet detents
//  2. viewDidAppear — extract selected text from extensionContext,
//                     then Task.detached to load dictionary + lookup
//  3. On result     — create WKWebView, render article, display
//

import UIKit
import WebKit
import CoreData
import AVFoundation
import OpenMDict

class ActionViewController: UIViewController {

    // MARK: - UI

    private var webView: WKWebView?
    /// Container for loading/error states — removed when article is displayed.
    private var statusContainerView: UIView?

    // MARK: - State

    /// The word/phrase selected by the user.
    private var selectedText: String = ""

    /// Dictionary readers loaded for this session (dictId → reader).
    /// Retained for the lifetime of the extension to keep resources accessible.
    private var readers: [String: MDictReader] = [:]

    /// The dictId of the dictionary whose article is currently displayed.
    private var activeDictId: String?

    /// Number of dictionaries searched (for the "in your top N dictionaries" message).
    private var searchedDictCount: Int = 0

    /// Audio player for sound:// links.
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
        configureSheetPresentation()
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
        // Left: Done button
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneButtonTapped)
        )

        // Right: Open in App
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.ActionExtension.openInApp,
            style: .plain,
            target: self,
            action: #selector(openInAppTapped)
        )

        // Title will be updated once we know the dictionary name
        title = "OpenMDict"
    }

    @objc private func doneButtonTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func openInAppTapped() {
        let word = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty,
              let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "openmdict://lookup?word=\(encoded)") else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        openContainingApp(url)
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Loading UI

    private func configureLoadingUI() {
        showStatusView(
            symbolName: "character.book.closed",
            message: L10n.ActionExtension.loading,
            showSpinner: true
        )
    }

    /// Updates the loading label to show the word and dictionary name.
    private func updateLoadingLabel(word: String, dictName: String) {
        guard let container = statusContainerView,
              let label = container.viewWithTag(1001) as? UILabel else { return }
        label.text = String(format: L10n.ActionExtension.loadingWithName, word, dictName)
    }

    private func removeStatusView() {
        statusContainerView?.removeFromSuperview()
        statusContainerView = nil
    }

    /// Reusable status view: SF Symbol icon + message + optional spinner + optional action button.
    ///
    /// - Parameters:
    ///   - symbolName: SF Symbol name for the icon.
    ///   - message: Main message text (supports multiline via `\n`).
    ///   - showSpinner: Whether to show a loading spinner.
    ///   - actionTitle: Button title (if nil, no button is shown).
    ///   - actionSymbol: Optional SF Symbol for the button (shown as trailing icon).
    ///   - filledButton: If true, renders a tinted filled capsule button instead of a plain text button.
    ///   - actionHandler: Callback when button is tapped.
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
                // Filled capsule button with optional trailing icon
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

    // MARK: - Sheet Presentation

    private func configureSheetPresentation() {
        if let sheet = navigationController?.sheetPresentationController ?? sheetPresentationController {
            if #available(iOS 16.0, *) {
                sheet.detents = [.medium(), .large()]
            } else {
                sheet.detents = [.medium(), .large()]
            }
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
    }

    // MARK: - Text Extraction

    private func extractSelectedText(completion: @escaping @MainActor (String?) -> Void) {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = extensionItem.attachments?.first else {
            completion(nil)
            return
        }

        // Try plain text first
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

    // MARK: - Dictionary Loading & Lookup

    private func loadDictionaryAndLookup(word: String) {
        print("📖 loadDictionaryAndLookup: word='\(word)'")

        Task.detached { [weak self] in
            guard let self else { return }

            // 1. Query CoreData: default group entries (user sort order) + metadata
            let context = await CoreDataStack.shared.viewContext

            let records: [(dictId: String, displayName: String)] = await context.perform {
                do {
                    // Get default group's entries sorted by user order
                    let entryRequest = GroupEntryRecord.fetchRequest()
                    entryRequest.predicate = NSPredicate(format: "groupId == %@", "all")
                    entryRequest.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
                    let entries = try context.fetch(entryRequest)

                    if entries.isEmpty {
                        // Fallback: no group entries, use metadata sorted by importedAt
                        let metaRequest = DictionaryMetadataRecord.fetchRequest()
                        metaRequest.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: true)]
                        let metas = try context.fetch(metaRequest)
                        return metas.map { (dictId: $0.dictId, displayName: $0.displayName) }
                    }

                    // Fetch all metadata into a lookup table
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

            // Update loading UI with word and first dictionary name
            await MainActor.run {
                self.updateLoadingLabel(word: word, dictName: records[0].displayName)
            }

            // 2. Iterate through dictionaries sequentially (user sort order).
            //    Load MDX-only first (MDD deferred until match).
            //    ⚠️ Memory: MDXParser builds 3 keyword indices in memory (30–90 MB
            //    per dict). iOS malloc does NOT return freed pages to the OS, so
            //    sequential loading may OOM if too many large dicts are opened.
            //    Reader deinit behaviour is still under investigation.
            var foundHTML: String?
            var foundDictId: String?
            var foundDictName: String?

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

                // Update loading UI for this dictionary
                await MainActor.run {
                    self.updateLoadingLabel(word: word, dictName: record.displayName)
                }

                // Try lookup
                if let entry = reader.lookup(word) {
                    print("📖 Dict[\(index)] '\(record.displayName)' — FOUND")

                    // Load MDD now that we have a match
                    let mddPaths = manifest.mdd.map {
                        dictDir.appendingPathComponent("mdd/\($0.fileName)").path
                    }
                    reader.reloadResources(mddPaths: mddPaths)

                    foundHTML = entry.article.html
                    foundDictId = dictId
                    foundDictName = record.displayName

                    // Keep reader for resource serving (MDD, entry:// links)
                    await MainActor.run {
                        self.readers[dictId] = reader
                    }
                    break
                } else {
                    print("📖 Dict[\(index)] '\(record.displayName)' — not found, releasing reader")
                    // reader goes out of scope here → deinit
                }
            }

            // 3. Show result
            let dictCount = records.count
            await MainActor.run {
                self.searchedDictCount = dictCount
                self.removeStatusView()

                if let html = foundHTML, let dictId = foundDictId {
                    self.activeDictId = dictId
                    self.title = foundDictName
                    self.showArticle(html: html, dictId: dictId)
                } else {
                    self.showNotFound()
                }
            }
        }
    }

    // MARK: - Article Display

    private func showArticle(html: String, dictId: String) {
        let config = WKWebViewConfiguration()

        // Register mdict:// scheme handler
        let schemeHandler = ActionExtensionSchemeHandler(
            readers: readers,
            dictionariesRoot: Self.dictionariesRoot
        )
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ActionExtensionSchemeHandler.scheme)

        // Preferences
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = self
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        self.webView = webView

        // Render HTML via ArticleHTMLRenderer
        let renderedHTML = ArticleHTMLRenderer.renderArticle(
            html: html,
            dictId: dictId,
            traitCollection: traitCollection
        )

        webView.loadHTMLString(renderedHTML, baseURL: nil)
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
            actionTitle: L10n.ActionExtension.searchMoreInApp,
            actionSymbol: "arrow.forward",
            filledButton: true,
            actionHandler: { [weak self] in self?.openInAppTapped() }
        )
    }

    /// Shows "no dictionaries" with a button to open the main app.
    private func showNoDictionaries() {
        showStatusView(
            symbolName: "character.book.closed",
            message: L10n.ActionExtension.noDictionaries,
            showSpinner: false,
            actionTitle: L10n.ActionExtension.openInApp,
            actionHandler: { [weak self] in self?.openInAppTapped() }
        )
    }

    // MARK: - Open Containing App (Responder Chain Workaround)

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

// MARK: - WKNavigationDelegate

extension ActionViewController: WKNavigationDelegate {

    @preconcurrency
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "entry":
            // Cross-reference link — lookup the word within this Extension
            decisionHandler(.cancel)
            handleEntryLink(url)

        case "sound":
            // Pronunciation audio — play it
            decisionHandler(.cancel)
            handleSoundLink(url)

        case "http", "https":
            // External web links — block in Extension
            decisionHandler(.cancel)

        case "mdict":
            // Internal resource — let the scheme handler handle it
            decisionHandler(.allow)

        default:
            // Initial loadHTMLString or unknown — allow
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    // MARK: - entry:// Handling

    private func handleEntryLink(_ url: URL) {
        guard let mdictURL = MDictURL(url), mdictURL.isEntryLink else { return }

        let word = mdictURL.resourcePath
        guard !word.isEmpty else { return }

        // Update selected text (for "Open in App")
        selectedText = word

        // Look up in all loaded readers, or reload if needed
        Task.detached { [weak self] in
            guard let self else { return }

            var foundHTML: String?
            var foundDictId: String?

            // First try existing readers
            let currentReaders = await MainActor.run { self.readers }
            for (dictId, reader) in currentReaders {
                if let entry = reader.lookup(word) {
                    foundHTML = entry.article.html
                    foundDictId = dictId
                    break
                }
            }

            await MainActor.run {
                if let html = foundHTML, let dictId = foundDictId {
                    let renderedHTML = ArticleHTMLRenderer.renderArticle(
                        html: html,
                        dictId: dictId,
                        traitCollection: self.traitCollection
                    )
                    self.webView?.loadHTMLString(renderedHTML, baseURL: nil)
                }
                // If not found, keep showing current article
            }
        }
    }

    // MARK: - sound:// Handling

    private func handleSoundLink(_ url: URL) {
        guard let mdictURL = MDictURL(url), mdictURL.isAudio else { return }

        // Try to load audio data from any loaded reader
        var audioData: Data?

        for (_, reader) in readers {
            for path in mdictURL.pathVariations {
                if let data = reader.resource(for: path) {
                    audioData = data
                    break
                }
            }
            if audioData != nil { break }
        }

        guard let data = audioData else { return }

        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
        } catch {
            debugLog("Failed to play audio: \(error)")
        }
    }
}

// MARK: - DictManifestLite

/// Lightweight manifest decoder for the Action Extension.
/// Only decodes the fields we need (id, mdx.fileName, mdd[].fileName).
/// The full DictManifest is in OpenMDictKit, which the Extension does not link.
/// `nonisolated` because it's used from `Task.detached` (off main actor).
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

/// `nonisolated` because it's used from `Task.detached` (off main actor).
private nonisolated extension JSONDecoder {
    /// JSONDecoder pre-configured with ISO 8601 date strategy.
    static let isoDate: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
