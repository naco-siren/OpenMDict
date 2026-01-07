//
//  ArticleStripViewController.swift
//  OpenMDict-iOS
//
//  Secondary column: horizontal article strip (IDE-style tabs)
//
//  Key features:
//  - Horizontal scrolling article tabs
//  - Push from left animation
//  - Drag to reorder
//  - Drag to new window
//

import UIKit

class ArticleStripViewController: UIViewController {
    
    // MARK: - Configuration
    
    private let tabWidthRatio: CGFloat = 0.35
    private let minTabWidth: CGFloat = 320
    private let tabSpacing: CGFloat = 1
    private let maxTabs: Int = 10
    
    // MARK: - State
    
    private(set) var articles: [ArticleItem] = []
    private var tabControllers: [String: ArticleTabViewController] = [:]
    
    var currentArticle: ArticleItem? {
        articles.first
    }
    
    // MARK: - UI
    
    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = true
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceHorizontal = true
        sv.delegate = self
        return sv
    }()
    
    private lazy var stackView: UIStackView = {
        let sv = UIStackView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.axis = .horizontal
        sv.alignment = .fill
        sv.distribution = .fill
        sv.spacing = tabSpacing
        return sv
    }()
    
    private lazy var emptyView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let imageView = UIImageView(image: UIImage(systemName: "book.closed"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = .init(pointSize: 64)
        
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Select a word to view"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .headline)
        
        view.addSubview(imageView)
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
        ])
        
        return view
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateEmptyState()
    }
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }
    
    // MARK: - Tab Width
    
    private var tabWidth: CGFloat {
        max(minTabWidth, view.bounds.width * tabWidthRatio)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        let width = tabWidth
        for case let tabVC as ArticleTabViewController in children {
            tabVC.updateWidth(width)
        }
    }
    
    // MARK: - Public API
    
    func preloadArticle(_ article: ArticleItem) {
        articles.insert(article, at: 0)
    }
    
    func pushArticle(_ article: ArticleItem, animated: Bool) {
        // Check if already exists
        if let existingIndex = articles.firstIndex(where: { $0.id == article.id }) {
            scrollToTab(at: existingIndex, animated: animated)
            return
        }
        
        let tabVC = createTabController(for: article)
        articles.insert(article, at: 0)
        
        addChild(tabVC)
        
        if animated {
            tabVC.view.alpha = 0
            tabVC.view.transform = CGAffineTransform(translationX: -tabWidth, y: 0)
            stackView.insertArrangedSubview(tabVC.view, at: 0)
            
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
                tabVC.view.alpha = 1
                tabVC.view.transform = .identity
                self.scrollView.contentOffset = .zero
            } completion: { _ in
                tabVC.didMove(toParent: self)
                self.trimExcessTabs()
            }
        } else {
            stackView.insertArrangedSubview(tabVC.view, at: 0)
            tabVC.didMove(toParent: self)
            trimExcessTabs()
        }
        
        updateEmptyState()
    }
    
    func closeArticle(_ article: ArticleItem, animated: Bool = true) {
        guard let index = articles.firstIndex(of: article),
              let tabVC = tabControllers[article.id] else {
            return
        }
        
        articles.remove(at: index)
        tabControllers.removeValue(forKey: article.id)
        
        if animated {
            UIView.animate(withDuration: 0.25) {
                tabVC.view.alpha = 0
                tabVC.view.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            } completion: { _ in
                tabVC.willMove(toParent: nil)
                tabVC.view.removeFromSuperview()
                tabVC.removeFromParent()
                self.updateEmptyState()
            }
        } else {
            tabVC.willMove(toParent: nil)
            tabVC.view.removeFromSuperview()
            tabVC.removeFromParent()
            updateEmptyState()
        }
    }
    
    func moveTab(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex != destIndex,
              sourceIndex >= 0, sourceIndex < articles.count,
              destIndex >= 0, destIndex < articles.count else {
            return
        }
        
        let article = articles.remove(at: sourceIndex)
        articles.insert(article, at: destIndex)
        
        if let tabVC = tabControllers[article.id] {
            stackView.removeArrangedSubview(tabVC.view)
            stackView.insertArrangedSubview(tabVC.view, at: destIndex)
        }
    }
    
    // MARK: - Private Helpers
    
    private func createTabController(for article: ArticleItem) -> ArticleTabViewController {
        let tabVC = ArticleTabViewController(article: article)
        tabVC.view.translatesAutoresizingMaskIntoConstraints = false
        tabVC.view.widthAnchor.constraint(equalToConstant: tabWidth).isActive = true
        
        tabVC.onClose = { [weak self] in
            self?.closeArticle(article, animated: true)
        }
        
        tabVC.onOpenInNewWindow = {
            SceneDelegate.openNewWindow(for: article)
        }
        
        tabControllers[article.id] = tabVC
        return tabVC
    }
    
    private func scrollToTab(at index: Int, animated: Bool) {
        let x = CGFloat(index) * (tabWidth + tabSpacing)
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }
    
    private func trimExcessTabs() {
        while articles.count > maxTabs {
            if let last = articles.last {
                closeArticle(last, animated: false)
            }
        }
    }
    
    private func updateEmptyState() {
        let isEmpty = articles.isEmpty
        emptyView.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }
}

// MARK: - UIScrollViewDelegate

extension ArticleStripViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Could add parallax effects or other scroll-based UI updates here
    }
}
