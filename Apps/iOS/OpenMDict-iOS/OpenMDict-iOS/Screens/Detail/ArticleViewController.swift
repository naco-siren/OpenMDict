//
//  ArticleViewController.swift
//  OpenMDict-iOS
//
//  Single article view for compact mode (iPhone / iPad narrow)
//  Passive View - no state, just renders what Container gives it
//

import UIKit

class ArticleViewController: UIViewController {
    
    // MARK: - UI
    
    private lazy var headerView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .secondarySystemGroupedBackground
        return v
    }()
    
    private lazy var titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 24, weight: .bold)
        l.numberOfLines = 0
        return l
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        return l
    }()
    
    private lazy var contentView: UIView = {
        // Placeholder for WKWebView
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .systemBackground
        
        let placeholder = UILabel()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = "📖\n\n(WKWebView content here)"
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 0
        placeholder.textColor = .tertiaryLabel
        v.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }()
    
    private lazy var emptyView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        let img = UIImageView(image: UIImage(systemName: "book.closed"))
        img.tintColor = .tertiaryLabel
        img.preferredSymbolConfiguration = .init(pointSize: 64)
        let lbl = UILabel()
        lbl.text = "Select a word to view"
        lbl.textColor = .secondaryLabel
        stack.addArrangedSubview(img)
        stack.addArrangedSubview(lbl)
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        setupUI()
        showEmpty()
    }
    
    private func setupUI() {
        view.addSubview(headerView)
        view.addSubview(contentView)
        view.addSubview(emptyView)
        
        headerView.addSubview(titleLabel)
        headerView.addSubview(subtitleLabel)
        
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -16),
            
            contentView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    // MARK: - Public API (called by Container)
    
    func configure(article: ArticleItem?) {
        if let article = article {
            showArticle(article)
        } else {
            showEmpty()
        }
    }
    
    private func showArticle(_ article: ArticleItem) {
        emptyView.isHidden = true
        headerView.isHidden = false
        contentView.isHidden = false
        
        titleLabel.text = article.title
        subtitleLabel.text = article.dictName
    }
    
    private func showEmpty() {
        emptyView.isHidden = false
        headerView.isHidden = true
        contentView.isHidden = true
    }
}
