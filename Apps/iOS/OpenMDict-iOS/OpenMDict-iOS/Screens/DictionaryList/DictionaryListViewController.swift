//
//  DictionaryListViewController.swift
//  OpenMDict-iOS
//
//  Primary column: dictionary list
//

import UIKit

class DictionaryListViewController: UIViewController {
    
    // MARK: - Callback
    
    var onDictionarySelected: ((DictionaryItem) -> Void)?
    
    // MARK: - Data
    
    private var dictionaries: [DictionaryItem] = DictionaryItem.mockData
    private var selectedId: String?
    
    // MARK: - UI
    
    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.dataSource = self
        tv.register(DictionaryCell.self, forCellReuseIdentifier: DictionaryCell.reuseId)
        return tv
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Dictionaries"
        navigationController?.navigationBar.prefersLargeTitles = true
        
        setupUI()
        
        // Auto-select first dictionary
        if let first = dictionaries.first {
            selectedId = first.id
            onDictionarySelected?(first)
        }
    }
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

// MARK: - UITableViewDataSource

extension DictionaryListViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        dictionaries.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: DictionaryCell.reuseId, for: indexPath) as! DictionaryCell
        let dict = dictionaries[indexPath.row]
        cell.configure(with: dict, isSelected: dict.id == selectedId)
        return cell
    }
}

// MARK: - UITableViewDelegate

extension DictionaryListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let dict = dictionaries[indexPath.row]
        selectedId = dict.id
        tableView.reloadData()
        onDictionarySelected?(dict)
    }
}

// MARK: - Dictionary Cell

private class DictionaryCell: UITableViewCell {
    
    static let reuseId = "DictionaryCell"
    
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private let statusDot = UIView()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 4
        contentView.addSubview(statusDot)
        
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .preferredFont(forTextStyle: .body)
        contentView.addSubview(nameLabel)
        
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .secondaryLabel
        contentView.addSubview(countLabel)
        
        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusDot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            
            nameLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            countLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            countLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }
    
    func configure(with dict: DictionaryItem, isSelected: Bool) {
        nameLabel.text = dict.name
        countLabel.text = "\(dict.entryCount.formatted()) entries"
        statusDot.backgroundColor = dict.isLoaded ? .systemGreen : .systemGray4
        backgroundColor = isSelected ? .systemGray5 : .secondarySystemGroupedBackground
    }
}
