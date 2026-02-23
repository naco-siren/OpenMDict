//
//  ArticlePlaceholderView.swift
//  OpenMDict-iOS
//
//  ContentUnavailableView-style placeholder for article display states.
//  Used by ArticleViewController (compact), ArticlesViewController (regular),
//  and ArticleCell (per-cell pending/not-found).
//

import UIKit

/// Lightweight UIView mimicking ContentUnavailableView (iOS 17+)
/// for article empty and loading states.
/// Background is transparent by default; callers set backgroundColor as needed.
class ArticlePlaceholderView: UIView {

    // MARK: - Factory Methods

    /// "Select a word" empty state — book icon + prompt text.
    static func empty() -> ArticlePlaceholderView {
        let view = ArticlePlaceholderView()
        view.configureEmpty()
        return view
    }

    /// Loading/pending state — icon + spinner/title row + descriptive message.
    ///
    /// Layout (ContentUnavailableView-style):
    /// ```
    /// Column {
    ///     Icon(cup.and.saucer)
    ///     Row { Spinner, Title("Loading 'word'…") }
    ///     Message("…will appear once dictName finishes loading.")
    /// }
    /// ```
    static func loading(word: String, dictName: String) -> ArticlePlaceholderView {
        let view = ArticlePlaceholderView()
        view.configureLoading(word: word, dictName: dictName)
        return view
    }

    // MARK: - Empty Layout

    private func configureEmpty() {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16

        let img = UIImageView(image: UIImage(systemName: "book.closed"))
        img.tintColor = .tertiaryLabel
        img.preferredSymbolConfiguration = .init(pointSize: 64)
        stack.addArrangedSubview(img)

        let lbl = UILabel()
        lbl.text = L10n.Articles.selectWord
        lbl.textColor = .secondaryLabel
        lbl.textAlignment = .center
        stack.addArrangedSubview(lbl)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Loading Layout

    private func configureLoading(word: String, dictName: String) {
        // Outer vertical stack
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        // Icon
        let icon = UIImageView(image: UIImage(systemName: "cup.and.saucer"))
        icon.tintColor = .tertiaryLabel
        icon.preferredSymbolConfiguration = .init(pointSize: 36)
        stack.addArrangedSubview(icon)

        // Spinner + Title row
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        row.addArrangedSubview(spinner)

        let titleLbl = UILabel()
        titleLbl.text = L10n.Articles.loadingWord(word)
        titleLbl.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLbl.textColor = .label
        titleLbl.numberOfLines = 0
        row.addArrangedSubview(titleLbl)

        stack.addArrangedSubview(row)

        // Message
        let msgLbl = UILabel()
        msgLbl.text = L10n.Articles.loadingMessage(dictName: dictName)
        msgLbl.font = .systemFont(ofSize: 13)
        msgLbl.textColor = .secondaryLabel
        msgLbl.textAlignment = .center
        msgLbl.numberOfLines = 0
        stack.addArrangedSubview(msgLbl)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
    }
}
