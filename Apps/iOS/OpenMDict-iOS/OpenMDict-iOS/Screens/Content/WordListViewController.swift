//
//  WordListViewController.swift
//  OpenMDict-iOS
//
//  Word search list - subscribes to DictionaryService.$searchResults
//  All search logic is handled by the reactive pipeline in DictionaryService
//

import UIKit
import Combine
import OpenMDictKit

class WordListViewController: UIViewController {
    
    // MARK: - State
    
    var onWordSelected: ((WordDisplayItem) -> Void)?
    
    /// Per-scene search session (injected by MainSplitVC)
    var searchSession: SearchSession?
    
    private var currentTitle = "Search"
    private var cancellables = Set<AnyCancellable>()
    
    /// Current displayed words (bound to DictionaryService.searchResults)
    private var displayedWords: [WordDisplayItem] = []
    
    private var isSearching: Bool {
        !(searchController.searchBar.text?.isEmpty ?? true)
    }
    
    // MARK: - UI
    
    private lazy var searchController: UISearchController = {
        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
        sc.obscuresBackgroundDuringPresentation = false
        sc.searchBar.placeholder = "Search words..."
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
        l.text = "Type to search"
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        return l
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.backButtonTitle = "Word Search"
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.largeTitleDisplayMode = .never
        
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        view.backgroundColor = .systemBackground
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        
        subscribeToSearchResults()
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
                self.tableView.reloadData()
                self.updateEmptyState()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Context Setting (called by MainSplitVC)
    
    func loadWords(for group: MDicts) {
        currentTitle = group.name
        updateTitleView()
        
        // Update search context - triggers reactive pipeline if query exists
        searchSession?.setContext(group: group)
        updateEmptyState()
    }
    
    func loadWords(for dict: MDict) {
        currentTitle = dict.metadata?.title ?? dict.id
        updateTitleView()
        
        // Update search context - triggers reactive pipeline if query exists
        searchSession?.setContext(dict: dict)
        updateEmptyState()
    }
    
    // MARK: - UI Updates
    
    private func updateEmptyState() {
        let isEmpty = displayedWords.isEmpty
        emptyLabel.isHidden = !isEmpty
        tableView.isHidden = isEmpty
        
        let context = searchSession?.currentContext ?? .none
        if case .none = context {
            emptyLabel.text = "Select a dictionary or group"
        } else if isSearching && displayedWords.isEmpty {
            emptyLabel.text = "No results for '\(searchController.searchBar.text ?? "")'"
        } else {
            emptyLabel.text = "Type to search"
        }
    }
    
    private func updateTitleView() {
        let context = searchSession?.currentContext ?? .none
        let iconName: String
        
        switch context {
        case .group(let group):
            iconName = group.isDefault ? "books.vertical.fill" : "books.vertical"
        case .dictionary:
            iconName = "book.fill"
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
        label.text = currentTitle
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
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayedWords.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var c = cell.defaultContentConfiguration()
        let wordItem = displayedWords[indexPath.row]
        c.text = wordItem.word

        // Show dictionary name as secondary text when displaying a group
        if case .group = searchSession?.currentContext {
            c.secondaryText = wordItem.dictName
            c.secondaryTextProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = c
        return cell
    }
}

// MARK: - UITableViewDelegate

extension WordListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onWordSelected?(displayedWords[indexPath.row])
    }
    
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
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
                UIAction(title: "Open", image: UIImage(systemName: "doc.text")) { _ in
                    self.onWordSelected?(word)
                },
                UIAction(title: "Open in New Window", image: UIImage(systemName: "square.split.2x1")) { [weak self] _ in
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
    }
}
