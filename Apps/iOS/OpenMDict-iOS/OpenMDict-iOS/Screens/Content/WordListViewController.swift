//
//  WordListViewController.swift
//  OpenMDict-iOS
//
//  Dual-mode word list:
//  - Search mode (isSearching == true): shows lookup results from reactive pipeline
//  - History mode (isSearching == false): shows recent lookups grouped by date
//
//  All search logic is handled by the reactive pipeline in DictionaryService.
//  History data is fetched from LookupHistoryService.
//

import UIKit
import Combine
import OpenMDictKit

class WordListViewController: UIViewController {

    // MARK: - State

    var onWordSelected: ((WordDisplayItem) -> Void)?

    /// Per-scene search session (injected by MainSplitVC)
    var searchSession: SearchSession?

    private var cancellables = Set<AnyCancellable>()

    /// Current displayed words (bound to DictionaryService.searchResults)
    private var displayedWords: [WordDisplayItem] = []

    /// History records grouped by date (used only in history mode)
    private var historyGroups: [HistorySection] = []

    private var isSearching: Bool {
        !(searchController.searchBar.text?.isEmpty ?? true)
    }

    // MARK: - UI

    private lazy var searchController: UISearchController = {
        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
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

    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = L10n.WordList.typeToSearch
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        return l
    }()

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
        view.addSubview(emptyLabel)
        view.addInteraction(UIDropInteraction(delegate: self))
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        subscribeToSearchResults()
        subscribeToHistoryChanges()
        loadHistory()
        updateEmptyState()
        updateTitleView()

    }

    // MARK: - Reactive Binding

    private func subscribeToSearchResults() {
        searchSession?.$results
            .receive(on: DispatchQueue.main)
            .sink { [weak self] results in
                guard let self else { return }
                self.displayedWords = results
                if self.isSearching {
                    self.tableView.reloadData()
                }
                self.updateEmptyState()
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
        historyGroups = rawGroups.map { section in
            HistorySection(title: section.title, records: section.records.map { item in
                let metadata = DictMetadataService.shared.find(dictId: item.dictId)
                return HistoryItem(
                    objectID: item.objectID,
                    word: item.word,
                    dictId: item.dictId,
                    dictName: metadata?.displayName ?? item.dictId,
                    isDictAvailable: metadata != nil,
                    lastLookedUpAt: item.lastLookedUpAt
                )
            })
        }
        if !isSearching {
            tableView.reloadData()
            updateEmptyState()
        }
    }

    // MARK: - Context Setting (called by MainSplitVC)

    func loadWords(for group: MDicts) {
        // Update search context - triggers reactive pipeline if query exists
        searchSession?.setContext(group: group)
        loadHistory()  // Reload history filtered by new context
        updateTitleView()
        updateEmptyState()
    }

    func loadWords(for dict: MDict) {
        // Update search context - triggers reactive pipeline if query exists
        searchSession?.setContext(dict: dict)
        loadHistory()  // Reload history filtered by new context
        updateTitleView()
        updateEmptyState()
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
            guard let self else { return }
            searchController.searchBar.text = text
            searchController.searchBar.delegate?.searchBar?(
                searchController.searchBar, textDidChange: text
            )
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
        if isSearching {
            // Search mode
            let isEmpty = displayedWords.isEmpty
            emptyLabel.isHidden = !isEmpty
            tableView.isHidden = isEmpty

            let context = searchSession?.currentContext ?? .none
            if case .none = context {
                emptyLabel.text = L10n.WordList.selectDictionaryOrGroup
            } else if displayedWords.isEmpty {
                emptyLabel.text = L10n.WordList.noResults(query: searchController.searchBar.text ?? "")
            } else {
                emptyLabel.text = L10n.WordList.typeToSearch
            }
        } else {
            // History mode
            let isEmpty = historyGroups.isEmpty
            emptyLabel.isHidden = !isEmpty
            tableView.isHidden = isEmpty
            emptyLabel.text = L10n.History.emptyState
        }
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
            return
        }

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
        isSearching ? 1 : historyGroups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isSearching {
            return displayedWords.count
        } else {
            guard section < historyGroups.count else { return 0 }
            return historyGroups[section].records.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if isSearching {
            return nil
        } else {
            guard section < historyGroups.count else { return nil }
            return historyGroups[section].title
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var c = cell.defaultContentConfiguration()

        if isSearching {
            // Search mode
            let wordItem = displayedWords[indexPath.row]
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
        } else {
            // History mode
            guard indexPath.section < historyGroups.count,
                  indexPath.row < historyGroups[indexPath.section].records.count else {
                cell.contentConfiguration = c
                return cell
            }
            let record = historyGroups[indexPath.section].records[indexPath.row]
            c.text = record.word
            // Show dict name unless the context is a single dictionary
            if case .dictionary = searchSession?.currentContext {
                // Single-dict context: all records are from the same dict, skip dictName
            } else {
                c.secondaryText = record.dictName
                c.secondaryTextProperties.color = .secondaryLabel
            }
            c.image = UIImage(systemName: "clock")
            c.imageProperties.tintColor = .secondaryLabel
        }

        cell.contentConfiguration = c
        return cell
    }

    // Swipe-to-delete (history mode only)

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !isSearching
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, !isSearching else { return }
        guard indexPath.section < historyGroups.count,
              indexPath.row < historyGroups[indexPath.section].records.count else { return }
        let record = historyGroups[indexPath.section].records[indexPath.row]
        guard let objectID = record.objectID else { return }
        LookupHistoryService.shared.deleteRecord(objectID: objectID)
        // loadHistory() will be triggered via $revision subscription
    }
}

// MARK: - UITableViewDelegate

extension WordListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if isSearching {
            onWordSelected?(displayedWords[indexPath.row])
        } else {
            guard indexPath.section < historyGroups.count,
                  indexPath.row < historyGroups[indexPath.section].records.count else { return }
            let record = historyGroups[indexPath.section].records[indexPath.row]
            let wordItem = WordDisplayItem(
                word: record.word,
                dictId: record.dictId,
                dictName: record.dictName
            )
            onWordSelected?(wordItem)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        // Context menu only for search mode
        guard isSearching else { return nil }

        let word = displayedWords[indexPath.row]
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

            return UIMenu(children: [
                UIAction(title: L10n.Articles.open, image: UIImage(systemName: "doc.text")) { _ in
                    self.onWordSelected?(word)
                },
                UIAction(title: L10n.Articles.openInNewWindow, image: UIImage(systemName: "square.split.2x1")) { [weak self] _ in
                    let session = self?.view.window?.windowScene?.session
                    SceneDelegate.openNewWindow(for: article, sourceSession: session)
                },
            ])
        }
    }
}

// MARK: - UISearchResultsUpdating

extension WordListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        // Just update the query - reactive pipeline handles the rest!
        searchSession?.updateQuery(query)

        // When transitioning between modes, reload the table
        tableView.reloadData()
        updateEmptyState()

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
