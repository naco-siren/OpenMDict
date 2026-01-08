//
//  WordListViewController.swift
//  OpenMDict-iOS
//

import UIKit

class WordListViewController: UIViewController {
    
    var onWordSelected: ((WordItem) -> Void)?
    
    private var words: [WordItem] = []
    private var filteredWords: [WordItem] = []
    private var currentTitle = "Words"
    
    private var isSearching: Bool { searchController.isActive && !(searchController.searchBar.text?.isEmpty ?? true) }
    private var displayedWords: [WordItem] { isSearching ? filteredWords : words }
    
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
        l.text = "Select a dictionary or group"
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.isHidden = true
        return l
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = currentTitle
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
    }
    
    func loadWords(for group: DictionaryGroup) {
        currentTitle = group.name
        title = currentTitle
        words = group.dictionaryIds.flatMap { mockWords(for: $0) }
        var seen = Set<String>()
        words = words.filter { seen.insert($0.word).inserted }
        words.sort { $0.word < $1.word }
        filteredWords = []
        tableView.reloadData()
        updateEmptyState()
    }
    
    func loadWords(for dict: DictionaryItem) {
        currentTitle = dict.name
        title = currentTitle
        words = mockWords(for: dict.id)
        words.sort { $0.word < $1.word }
        filteredWords = []
        tableView.reloadData()
        updateEmptyState()
    }
    
    private func mockWords(for dictId: String) -> [WordItem] {
        ["app","ban","car","dog","egg","fox","get","hat","ice","jam","key","let","map","new","old","pen","quo","run","set","top"]
            .flatMap { WordItem.mockWords(for: $0, dictId: dictId) }
    }
    
    private func updateEmptyState() {
        emptyLabel.isHidden = !words.isEmpty
        tableView.isHidden = words.isEmpty
    }
}

extension WordListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayedWords.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var c = cell.defaultContentConfiguration()
        c.text = displayedWords[indexPath.row].word
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
            UIMenu(children: [
                UIAction(title: "Open", image: UIImage(systemName: "doc.text")) { _ in
                    self?.onWordSelected?(word)
                },
                UIAction(title: "Open in New Window", image: UIImage(systemName: "square.split.2x1")) { _ in
                    SceneDelegate.openNewWindow(for: ArticleItem(title: word.word, dictName: self?.currentTitle ?? ""))
                },
            ])
        }
    }
}

extension WordListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let q = searchController.searchBar.text?.lowercased() ?? ""
        filteredWords = q.isEmpty ? [] : words.filter { $0.word.lowercased().hasPrefix(q) }
        tableView.reloadData()
    }
}
