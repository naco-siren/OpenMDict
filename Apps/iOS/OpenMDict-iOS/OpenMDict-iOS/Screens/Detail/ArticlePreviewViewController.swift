//
//  ArticlePreviewViewController.swift
//  OpenMDict-iOS
//
//  Compact preview for context menu (header only, no WebView)
//

import UIKit

class ArticlePreviewViewController: UIViewController {
    init(article: ArticleDisplayItem) {
        super.init(nibName: nil, bundle: nil)
        
        view.backgroundColor = .systemFill
        
        // Leading icon
        let iconName: String = if #available(iOS 17.0, *) { "book.pages" } else { "menucard" }
        let iconView = UIImageView(image: UIImage(systemName: iconName))
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = .init(pointSize: 16, weight: .regular)
        
        // Title & subtitle
        let titleLabel = UILabel()
        titleLabel.text = article.word
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        
        let subtitleLabel = UILabel()
        subtitleLabel.text = article.dictName
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        
        let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 2
        
        // Main horizontal stack: icon + titles
        let mainStack = UIStackView(arrangedSubviews: [iconView, titleStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 10
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            mainStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        
        // Size based on content width: icon(24) + spacing(10) + title + padding(32)
        let titleWidth = max(titleLabel.intrinsicContentSize.width, subtitleLabel.intrinsicContentSize.width)
        let width = min(400, 24 + 10 + titleWidth + 32)
        preferredContentSize = CGSize(width: width, height: 72)
    }
    
    required init?(coder: NSCoder) { fatalError() }
}
