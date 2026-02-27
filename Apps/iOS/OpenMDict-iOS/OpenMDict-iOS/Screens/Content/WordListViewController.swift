//
//  WordListViewController.swift
//  OpenMDict-iOS
//
//  Three-state word list (enhanced search UX):
//  - Idle: search bar not active — shows date-grouped lookup history
//  - Active + empty query: search bar focused — shows clipboard + history
//  - Active + query: search bar has text — shows search results (+ suggestions if few)
//
//  All search logic is handled by the reactive pipeline in SearchSession.
//  History data is fetched from LookupHistoryService.
//

import UIKit
import Combine
import OpenMDictKit

class WordListViewController: UIViewController {

    // MARK: - Display State

    /// Three-state display model replacing the old boolean `isSearching`.
    private enum DisplayState: Equatable {
        case idle                    // search bar not active
        case activeEmpty             // search bar focused, no text
        case activeWithQuery(String) // search bar focused, has text
    }

    // MARK: - Section Model

    private enum SectionType {
        case clipboard
        case history(String)      // title = date string ("Today", "Yesterday", …)
        case searchResults
        case suggestions
    }

    private struct SectionData {
        let type: SectionType
        let rows: [RowItem]
    }

    private enum RowItem {
        case clipboardContent(String?)   // nil = clipboard empty → placeholder
        case historyRecord(HistoryItem)
        case searchResult(WordDisplayItem)
        case suggestion(String)
    }

    // MARK: - State

    var onWordSelected: ((WordDisplayItem) -> Void)?
    var onViewAllHistory: (() -> Void)?

    /// Per-scene search session (injected by MainSplitVC)
    var searchSession: SearchSession?

    private var cancellables = Set<AnyCancellable>()

    private var displayState: DisplayState = .idle
    private var sections: [SectionData] = []

    /// Current displayed words (bound to SearchSession.$results)
    private var displayedWords: [WordDisplayItem] = []

    /// Suggested words when search results are few (bound to SearchSession.$suggestions)
    private var suggestedWords: [String] = []

    /// History records grouped by date
    private var historyGroups: [HistorySection] = []

    /// Clipboard text read once when search becomes active
    private var clipboardText: String?

    // MARK: - UI

    private lazy var searchController: UISearchController = {
        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
        sc.delegate = self
        sc.obscuresBackgroundDuringPresentation = false
        sc.searchBar.placeholder = L10n.WordList.searchPlaceholder
        return sc
    }()

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tv.keyboardDismissMode = .onDrag
        return tv
    }()

    // MARK: Empty State View (ContentUnavailableView-like, iOS 15+)

    private lazy var emptyStateView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true

        container.addSubview(emptyStateStack)
        NSLayoutConstraint.activate([
            emptyStateStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyStateStack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 40),
            emptyStateStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
        ])

        return container
    }()

    private lazy var emptyStateStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            emptyStateIcon, emptyStateTitle, emptyStateMessage, emptyStateButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(12, after: emptyStateIcon)
        return stack
    }()

    private lazy var emptyStateIcon: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.tintColor = .secondaryLabel
        iv.contentMode = .scaleAspectFit
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40)
        return iv
    }()

    private lazy var emptyStateTitle: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()

    private lazy var emptyStateMessage: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 15, weight: .regular)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()

    private lazy var emptyStateButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
        b.addTarget(self, action: #selector(emptyStateButtonTapped), for: .touchUpInside)
        return b
    }()

    @objc private func emptyStateButtonTapped() {
        onViewAllHistory?()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.backButtonTitle = L10n.WordList.wordSearch
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.largeTitleDisplayMode = .never

        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        view.backgroundColor = .systemBackground
        view.addSubview(tableView)
        view.addSubview(emptyStateView)
        view.addInteraction(UIDropInteraction(delegate: self))
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        subscribeToSearchResults()
        subscribeToSuggestions()
        subscribeToHistoryChanges()
        loadHistory()
        rebuildSections()
        updateTitleView()
    }

    // MARK: - Display State Management

    private func updateDisplayState() {
        let isActive = searchController.isActive
        let query = (searchController.searchBar.text ?? "")
            .trimmingCharacters(in: .whitespaces)

        let newState: DisplayState
        if !isActive {
            newState = .idle
        } else if query.isEmpty {
            newState = .activeEmpty
        } else {
            newState = .activeWithQuery(query)
        }

        guard newState != displayState else { return }
        displayState = newState
        rebuildSections()
    }

    // MARK: - Section Assembly

    /// Rebuild `sections` from backing stores and reload the table view.
    /// This is the terminal convergence point for all reactive signals.
    private func rebuildSections() {
        var newSections: [SectionData] = []

        switch displayState {
        case .idle:
            // History only (date-grouped)
            for group in historyGroups {
                newSections.append(SectionData(
                    type: .history(group.title),
                    rows: group.records.map { .historyRecord($0) }
                ))
            }

        case .activeEmpty:
            // Clipboard (only shown when clipboard has searchable text)
            if let clipboardText {
                newSections.append(SectionData(
                    type: .clipboard,
                    rows: [.clipboardContent(clipboardText)]
                ))
            }
            // History
            for group in historyGroups {
                newSections.append(SectionData(
                    type: .history(group.title),
                    rows: group.records.map { .historyRecord($0) }
                ))
            }

        case .activeWithQuery:
            // Search results
            if !displayedWords.isEmpty {
                newSections.append(SectionData(
                    type: .searchResults,
                    rows: displayedWords.map { .searchResult($0) }
                ))
            }
            // Suggestions (only when few results)
            if !suggestedWords.isEmpty {
                newSections.append(SectionData(
                    type: .suggestions,
                    rows: suggestedWords.map { .suggestion($0) }
                ))
            }
        }

        sections = newSections
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: - Reactive Binding

    private func subscribeToSearchResults() {
        searchSession?.$results
            .receive(on: DispatchQueue.main)
            .sink { [weak self] results in
                guard let self else { return }
                self.displayedWords = results
                self.rebuildSections()
            }
            .store(in: &cancellables)
    }

    private func subscribeToSuggestions() {
        searchSession?.$suggestions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suggestions in
                guard let self else { return }
                self.suggestedWords = suggestions
                self.rebuildSections()
            }
            .store(in: &cancellables)
    }

    private func subscribeToHistoryChanges() {
        LookupHistoryService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadHistory()
            }
            .store(in: &cancellables)

        // React to dictionary metadata changes (e.g., dict renamed locally or on another device)
        DictMetadataService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadHistory()
            }
            .store(in: &cancellables)
    }

    // MARK: - History Data

    /// Lookup context tuple derived from current search context.
    /// Exactly one of the two values is non-nil.
    private var lookupContext: (dictId: String?, groupId: String?)? {
        guard let context = searchSession?.currentContext else { return nil }
        switch context {
        case .group(let group):
            return (nil, group.id)
        case .dictionary(let dict):
            return (dict.id, nil)
        case .none:
            return nil
        }
    }

    private func loadHistory() {
        let ctx = lookupContext
        let rawGroups = LookupHistoryService.shared.groupedHistory(
            lookupContextDictId: ctx?.dictId, lookupContextGroupId: ctx?.groupId
        )
        // Resolve dictName from DictMetadataService (authoritative).
        // Filter out records whose dictionary is not locally available — these
        // are synced from another device but the dict hasn't been downloaded yet.
        // They remain visible in the dedicated LookupHistoryListViewController
        // (with "dictionary unavailable" styling) but should not clutter the
        // group/dict WordListVC which only shows actionable history.
        let groups: [HistorySection] = rawGroups.compactMap { section in
            let filtered = section.records.compactMap { item -> HistoryItem? in
                guard let metadata = DictMetadataService.shared.find(dictId: item.dictId) else {
                    return nil  // dict not available locally — skip
                }
                return HistoryItem(
                    objectID: item.objectID,
                    word: item.word,
                    dictId: item.dictId,
                    dictName: metadata.displayName,
                    isDictAvailable: true,
                    lastLookedUpAt: item.lastLookedUpAt
                )
            }
            guard !filtered.isEmpty else { return nil }  // drop empty sections
            return HistorySection(title: section.title, records: filtered)
        }

        historyGroups = groups
        rebuildSections()
    }

    // MARK: - Clipboard

    private func refreshClipboard() {
        if #available(iOS 16.0, *) {
            guard UIPasteboard.general.hasStrings else {
                clipboardText = nil
                return
            }
        }
        let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        clipboardText = (text?.isEmpty ?? true) ? nil : text
    }

    /// Inject text into the search bar, triggering the reactive search pipeline.
    private func injectSearchText(_ text: String) {
        searchController.searchBar.text = text
        searchController.searchBar.delegate?.searchBar?(
            searchController.searchBar, textDidChange: text
        )
    }

    // MARK: - Context Setting (called by MainSplitVC)

    func loadWords(for group: MDicts) {
        // Update search context - triggers reactive pipeline if query exists
        searchSession?.setContext(group: group)
        loadHistory()  // Reload history filtered by new context
        updateTitleView()
    }

    func loadWords(for dict: MDict) {
        // Update search context - triggers reactive pipeline if query exists
        searchSession?.setContext(dict: dict)
        loadHistory()  // Reload history filtered by new context
        updateTitleView()
    }

    /// Activate the search bar and show keyboard (called from keyboard shortcut ⌘L)
    func focusSearchBar() {
        searchController.isActive = true
        searchController.searchBar.becomeFirstResponder()
    }

    /// Activate the search bar, inject initial text, and trigger search update.
    /// Used by pressesBegan auto-focus to forward the first typed character.
    func focusSearchBar(withInitialText text: String) {
        searchController.isActive = true
        searchController.searchBar.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in
            self?.injectSearchText(text)
        }
    }

    /// Whether the search bar currently has keyboard focus
    var isSearchBarFirstResponder: Bool {
        searchController.searchBar.isFirstResponder
    }

    /// Deactivate the search bar (used by Esc smart dismiss)
    func dismissSearchBar() {
        searchController.isActive = false
    }

    // MARK: - UI Updates

    private func updateEmptyState() {
        switch displayState {
        case .idle:
            let context = searchSession?.currentContext ?? .none
            if case .none = context {
                // No context selected — prompt user to pick a source
                configureEmptyState(
                    icon: "text.book.closed",
                    title: L10n.WordList.selectDictionaryOrGroup,
                    message: nil,
                    buttonTitle: nil
                )
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else if historyGroups.isEmpty {
                // Context selected but no history in this source
                configureEmptyState(
                    icon: "clock",
                    title: L10n.WordList.noHistoryInContext,
                    message: L10n.WordList.noHistoryInContextMessage,
                    buttonTitle: L10n.WordList.viewAllHistory
                )
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else {
                emptyStateView.isHidden = true
                tableView.isHidden = false
            }

        case .activeEmpty:
            // Always show table (clipboard + history)
            emptyStateView.isHidden = true
            tableView.isHidden = false

        case .activeWithQuery:
            let context = searchSession?.currentContext ?? .none
            if case .none = context {
                configureEmptyState(
                    icon: "text.book.closed",
                    title: L10n.WordList.selectDictionaryOrGroup,
                    message: nil,
                    buttonTitle: nil
                )
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else if displayedWords.isEmpty && suggestedWords.isEmpty {
                configureEmptyState(
                    icon: "magnifyingglass",
                    title: L10n.WordList.noResults(
                        query: searchController.searchBar.text ?? ""),
                    message: nil,
                    buttonTitle: nil
                )
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else {
                emptyStateView.isHidden = true
                tableView.isHidden = false
            }
        }
    }

    /// Configure the empty state view with the given content.
    /// Pass `nil` for `message` or `buttonTitle` to hide those elements.
    private func configureEmptyState(
        icon: String,
        title: String,
        message: String?,
        buttonTitle: String?
    ) {
        emptyStateIcon.image = UIImage(systemName: icon)
        emptyStateTitle.text = title
        emptyStateMessage.text = message
        emptyStateMessage.isHidden = (message == nil)
        emptyStateButton.setTitle(buttonTitle, for: .normal)
        emptyStateButton.isHidden = (buttonTitle == nil)
    }

    private func updateTitleView() {
        let context = searchSession?.currentContext ?? .none
        let iconName: String
        let titleText: String

        switch context {
        case .group(let group):
            iconName = group.isDefault ? "books.vertical.fill" : "folder"
            titleText = group.name
        case .dictionary(let dict):
            iconName = "book.fill"
            titleText = dict.preferredTitle
        case .none:
            title = nil
            navigationItem.title = nil
            navigationItem.titleView = nil
            // Do NOT clear leftBarButtonItem here — in compact tab mode it
            // holds the sidebar toggle button set by CompactTabBarController.
            return
        }

        // Static titleView (icon + label).
        // In compact tab mode, leftBarButtonItem is set externally by CompactTabBarController.
        let imageView = UIImageView(image: UIImage(systemName: iconName))
        imageView.tintColor = .label
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = titleText
        label.font = .systemFont(ofSize: 17, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center

        navigationItem.title = nil
        navigationItem.titleView = stack
    }

}

// MARK: - UITableViewDataSource

extension WordListViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard section < sections.count else { return 0 }
        return sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section < sections.count else { return nil }
        switch sections[section].type {
        case .clipboard:       return L10n.WordList.clipboardHeader
        case .history(let t):  return t
        case .searchResults:   return L10n.WordList.searchResultsHeader
        case .suggestions:     return L10n.WordList.suggestionsHeader
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var c = cell.defaultContentConfiguration()

        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else {
            cell.contentConfiguration = c
            return cell
        }

        let row = sections[indexPath.section].rows[indexPath.row]

        switch row {
        case .clipboardContent(let text):
            c.image = UIImage(systemName: "doc.on.clipboard")
            c.imageProperties.tintColor = .secondaryLabel
            if let text {
                // Truncate long clipboard text for display
                let truncated = text.count > 60
                    ? String(text.prefix(60)) + "\u{2026}"
                    : text
                c.text = truncated
                c.secondaryText = L10n.WordList.clipboardPasteToSearch
                c.secondaryTextProperties.color = .secondaryLabel
            } else {
                c.text = L10n.WordList.clipboardEmpty
                c.textProperties.color = .tertiaryLabel
            }

        case .historyRecord(let record):
            c.text = record.word
            c.image = UIImage(systemName: "clock")
            c.imageProperties.tintColor = .secondaryLabel
            // Show dict name unless the context is a single dictionary
            if case .dictionary = searchSession?.currentContext {
                // Single-dict context: all records are from the same dict, skip dictName
            } else {
                c.secondaryText = record.dictName
                c.secondaryTextProperties.color = .secondaryLabel
            }

        case .searchResult(let wordItem):
            c.text = wordItem.word
            let iconName: String
            if #available(iOS 17.0, *) {
                iconName = "book.pages"
            } else {
                iconName = "menucard"
            }
            c.image = UIImage(systemName: iconName)
            c.imageProperties.tintColor = .secondaryLabel
            // Show dictionary name as secondary text when displaying a group
            if case .group = searchSession?.currentContext {
                c.secondaryText = wordItem.dictName
                c.secondaryTextProperties.color = .secondaryLabel
            }

        case .suggestion(let word):
            c.text = word
            c.image = UIImage(systemName: "lightbulb")
            c.imageProperties.tintColor = .secondaryLabel
        }

        cell.contentConfiguration = c
        return cell
    }

    // Swipe-to-delete (history mode only)

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else { return false }
        if case .historyRecord = sections[indexPath.section].rows[indexPath.row] {
            return true
        }
        return false
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete,
              indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else { return }
        if case .historyRecord(let record) = sections[indexPath.section].rows[indexPath.row] {
            guard let objectID = record.objectID else { return }
            LookupHistoryService.shared.deleteRecord(objectID: objectID)
            // loadHistory() will be triggered via $revision subscription
        }
    }
}

// MARK: - UITableViewDelegate

extension WordListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else { return }

        let row = sections[indexPath.section].rows[indexPath.row]

        switch row {
        case .clipboardContent(let text):
            guard let text else { return }  // placeholder cell — non-interactive
            injectSearchText(text)

        case .historyRecord(let record):
            let wordItem = WordDisplayItem(
                word: record.word,
                dictId: record.dictId,
                dictName: record.dictName
            )
            onWordSelected?(wordItem)

        case .searchResult(let wordItem):
            onWordSelected?(wordItem)

        case .suggestion(let word):
            injectSearchText(word)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else { return nil }

        // Context menu only for search result rows
        guard case .searchResult(let word) = sections[indexPath.section].rows[indexPath.row] else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }

            // Create article - try to load if dictionary is ready
            let dict = DictionaryService.shared.dict(id: word.dictId)
            var article = ArticleDisplayItem(
                word: word.word,
                dictId: word.dictId,
                dictName: word.dictName,
                contentState: .pending
            )
            if let dict = dict, let entry = dict.lookup(word.word) {
                article.contentState = .loaded(html: entry.article.html, css: nil)
            }

            var actions: [UIAction] = [
                UIAction(title: L10n.Articles.open, image: UIImage(systemName: "doc.text")) { _ in
                    self.onWordSelected?(word)
                },
            ]
            if UIApplication.shared.supportsMultipleScenes {
                actions.append(UIAction(title: L10n.Articles.openInNewWindow, image: UIImage(systemName: "square.split.2x1")) { [weak self] _ in
                    let session = self?.view.window?.windowScene?.session
                    SceneDelegate.openNewWindow(for: article, sourceSession: session)
                })
            }
            return UIMenu(children: actions)
        }
    }
}

// MARK: - UISearchResultsUpdating

extension WordListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        // Just update the query - reactive pipeline handles the rest!
        searchSession?.updateQuery(query)
        updateDisplayState()
    }
}

// MARK: - UISearchControllerDelegate

extension WordListViewController: UISearchControllerDelegate {
    func willPresentSearchController(_ searchController: UISearchController) {
        refreshClipboard()
        updateDisplayState()
    }

    func willDismissSearchController(_ searchController: UISearchController) {
        clipboardText = nil
        updateDisplayState()
    }
}

// MARK: - UIDropInteractionDelegate (iPad text drag → look up)

extension WordListViewController: UIDropInteractionDelegate {

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: NSString.self)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        session.loadObjects(ofClass: NSString.self) { [weak self] items in
            guard let text = (items.first as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            self?.focusSearchBar(withInitialText: text)
        }
    }
}
