//
//  WordListViewController.swift
//  OpenMDict-iOS
//

import UIKit
import OpenMDict
import OpenMDictKit

class WordListViewController: UIViewController {
    
    // MARK: - Display Mode

    private enum DisplayMode {
        case group(MDicts)
        case dictionary(MDict)
    }

    private var displayMode: DisplayMode?
    var onWordSelected: ((WordDisplayItem) -> Void)?
    
    private var words: [WordDisplayItem] = []
    private var filteredWords: [WordDisplayItem] = []
    private var currentTitle = "Search"
    
    private var isSearching: Bool { searchController.isActive && !(searchController.searchBar.text?.isEmpty ?? true) }
    private var displayedWords: [WordDisplayItem] { isSearching ? filteredWords : words }
    
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
        updateEmptyState()
        updateTitleView()
    }
    
    func loadWords(for group: MDicts) {
        displayMode = .group(group)
        currentTitle = group.name
        // Clear - will populate via search
        words = []
        filteredWords = []
        tableView.reloadData()
        updateEmptyState()
        updateTitleView()
    }
    
    func loadWords(for dict: MDict) {
        displayMode = .dictionary(dict)
        currentTitle = dict.metadata?.title ?? dict.id
        // Clear - will populate via search
        words = []
        filteredWords = []
        tableView.reloadData()
        updateEmptyState()
        updateTitleView()
    }
    
    private func performSearch(_ query: String) {
        guard !query.isEmpty else {
            filteredWords = []
            tableView.reloadData()
            updateEmptyState()
            return
        }
        
        switch displayMode {
        case .group(let group):
            filteredWords = DictionaryService.shared.search(prefix: query, in: group, limit: 50)
        case .dictionary(let dict):
            filteredWords = DictionaryService.shared.search(prefix: query, in: dict, limit: 50)
        case .none:
            filteredWords = []
        }
        
        tableView.reloadData()
        updateEmptyState()
    }
    
    private func updateEmptyState() {
        let isEmpty = displayedWords.isEmpty
        emptyLabel.isHidden = !isEmpty
        tableView.isHidden = isEmpty
        
        if displayMode == nil {
            emptyLabel.text = "Select a dictionary or group"
        } else if isSearching && displayedWords.isEmpty {
            emptyLabel.text = "No results"
        } else {
            emptyLabel.text = "Type to search"
        }
    }
    
    private func updateTitleView() {
        let iconName: String
        switch displayMode {
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
        if case .group = displayMode {
            c.secondaryText = wordItem.dictName  // WordDisplayItem already has dictName!
            c.secondaryTextProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = c
        return cell
    }
}

extension WordListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onWordSelected?(displayedWords[indexPath.row])
    }
    
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let word = displayedWords[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let html = StubHTML.html(for: word.word, dictName: word.dictName)
                         
            return UIMenu(children: [
                UIAction(title: "Open", image: UIImage(systemName: "doc.text")) { _ in
                    self?.onWordSelected?(word)
                },
                UIAction(title: "Open in New Window", image: UIImage(systemName: "square.split.2x1")) { _ in
                    SceneDelegate.openNewWindow(for: ArticleDisplayItem(
                        word: word.word,
                        dictId: word.dictId,
                        dictName: word.dictName,
                        html: html
                    ))
                },
            ])
        }
    }
}

extension WordListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        performSearch(query)
    }
}
