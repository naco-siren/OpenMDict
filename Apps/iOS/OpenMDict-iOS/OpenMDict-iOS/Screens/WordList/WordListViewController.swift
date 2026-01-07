//
//  WordListViewController.swift
//  OpenMDict-iOS
//
//  Supplementary column: word list with search
//

import UIKit

class WordListViewController: UIViewController {
    
    // MARK: - Callback
    
    var onWordSelected: ((WordItem) -> Void)?
    
    // MARK: - Data
    
    private var currentDict: DictionaryItem?
    private var words: [WordItem] = []
    private var filteredWords: [WordItem] = []
    
    private var isSearching: Bool {
        searchController.isActive && !(searchController.searchBar.text?.isEmpty ?? true)
    }
    
    private var displayedWords: [WordItem] {
        isSearching ? filteredWords : words
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
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "WordCell")
        tv.keyboardDismissMode = .onDrag
        return tv
    }()
    
    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Select a dictionary"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Words"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        
        setupUI()
        updateEmptyState()
    }
    
    private func setupUI() {
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
    }
    
    // MARK: - Public API
    
    func loadWords(for dict: DictionaryItem) {
        currentDict = dict
        title = dict.name
        
        words = generateMockWords(for: dict.id)
        filteredWords = []
        
        tableView.reloadData()
        updateEmptyState()
    }
    
    private func generateMockWords(for dictId: String) -> [WordItem] {
        let prefixes = ["app", "ban", "car", "dog", "egg", "fox", "get", "hat", "ice", "jam",
                        "key", "let", "map", "new", "old", "pen", "quo", "run", "set", "top"]
        return prefixes.flatMap { prefix in
            WordItem.mockWords(for: prefix, dictId: dictId)
        }
    }
    
    private func updateEmptyState() {
        let isEmpty = currentDict == nil || words.isEmpty
        emptyLabel.isHidden = !isEmpty
        tableView.isHidden = isEmpty
        
        if currentDict == nil {
            emptyLabel.text = "Select a dictionary"
        } else if words.isEmpty {
            emptyLabel.text = "No words found"
        }
    }
}

// MARK: - UITableViewDataSource

extension WordListViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayedWords.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "WordCell", for: indexPath)
        let word = displayedWords[indexPath.row]
        
        var content = cell.defaultContentConfiguration()
        content.text = word.word
        cell.contentConfiguration = content
        
        return cell
    }
}

// MARK: - UITableViewDelegate

extension WordListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let word = displayedWords[indexPath.row]
        onWordSelected?(word)
    }
    
    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let word = displayedWords[indexPath.row]
        
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let openAction = UIAction(title: "Open", image: UIImage(systemName: "doc.text")) { _ in
                self?.onWordSelected?(word)
            }
            
            let newWindowAction = UIAction(title: "Open in New Window", image: UIImage(systemName: "square.split.2x1")) { [weak self] _ in
                guard let dict = self?.currentDict else { return }
                let article = ArticleItem(title: word.word, dictName: dict.name)
                SceneDelegate.openNewWindow(for: article)
            }
            
            return UIMenu(children: [openAction, newWindowAction])
        }
    }
}

// MARK: - UISearchResultsUpdating

extension WordListViewController: UISearchResultsUpdating {
    
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.lowercased() ?? ""
        
        if query.isEmpty {
            filteredWords = []
        } else {
            filteredWords = words.filter { $0.word.lowercased().hasPrefix(query) }
        }
        
        tableView.reloadData()
    }
}
