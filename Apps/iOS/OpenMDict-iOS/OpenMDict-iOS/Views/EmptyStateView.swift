//
//  EmptyStateView.swift
//  OpenMDict-iOS
//
//  Lightweight UIKit equivalent of iOS 17's `ContentUnavailableView`.
//  Project deployment target is iOS 15.6, so we can't lean on the native
//  one; before this view existed, ~4 VCs all hand-rolled their own
//  vertical-stack-of-[icon + title + subtitle (+ button)] under various
//  property names.
//
//  Layout (top to bottom):
//
//    [ icon                ]      large SF Symbol; hidden when nil
//    [ spinner + title row ]      spinner hidesWhenStopped → collapses
//    [ message             ]      multi-line body copy; hidden when nil
//    [ action button       ]      hidden when title is nil
//
//  Everything is built in `init` and reconfigured via `configure(_:)`,
//  so the same instance can switch between e.g. a "loading…" state and a
//  "no internet" error state without re-layout churn.
//
//  Three factory presets cover the patterns we have today:
//
//    .placeholder(icon:title:message:)
//        Empty / no-selection / neutral "nothing to show" states.
//        60pt thin tertiaryLabel icon, title2 secondaryLabel title,
//        subheadline tertiaryLabel message. Matches the existing DIY
//        empty-state look used by GroupDictionaryEditor /
//        DictResourceEditor / DictInfo.
//
//    .loading(icon:title:message:)
//        In-progress states. 40pt regular icon, semibold 17 title beside
//        a spinner, regular 15 secondaryLabel message. Matches
//        WordListVC's "Searching…" empty state.
//
//    .error(_:retry:)
//        Binds to an `ODRError`. Orange-tinted icon, error's
//        localized title / message, "Retry" button wired to the closure.
//
//  Callers needing more control can build a `Configuration` directly —
//  every field has a sensible default and is mutable.
//

import UIKit

@MainActor
final class EmptyStateView: UIView {

    // MARK: - Configuration

    struct Configuration {
        // Icon
        var iconSystemName: String?
        var iconTint: UIColor = .tertiaryLabel
        var iconPointSize: CGFloat = 60
        var iconWeight: UIImage.SymbolWeight = .thin

        // Title (+ optional spinner on the same row)
        var title: String?
        var titleColor: UIColor = .secondaryLabel
        var titleFont: UIFont = .preferredFont(forTextStyle: .title2)
        var showsSpinner: Bool = false

        // Message body
        var message: String?
        var messageColor: UIColor = .tertiaryLabel
        var messageFont: UIFont = .preferredFont(forTextStyle: .subheadline)

        // Action button
        var actionTitle: String?
        var actionImageSystemName: String?
        var actionHandler: (() -> Void)?

        // Layout spacing
        var stackSpacing: CGFloat = 16
        var spacingAfterIcon: CGFloat = 24
    }

    // MARK: - Subviews

    private let containerStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .center
        return s
    }()

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private let titleRow: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.alignment = .center
        s.spacing = 8
        return s
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        // hidesWhenStopped lets the stack auto-collapse the slot when
        // we're not in a loading state — no separate isHidden bookkeeping.
        s.hidesWhenStopped = true
        s.color = .secondaryLabel
        return s
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()

    private let messageLabel: UILabel = {
        let l = UILabel()
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()

    private let actionButton: UIButton = {
        // `.system` so tinting + accessibility traits come for free.
        let b = UIButton(type: .system)
        b.titleLabel?.font = .preferredFont(forTextStyle: .body)
        return b
    }()

    /// Held so we can invoke it from `actionButton`'s target without
    /// retaining `self` in the closure.
    private var actionHandler: (() -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayout()
        actionButton.addTarget(self, action: #selector(actionButtonTapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func setupLayout() {
        titleRow.addArrangedSubview(spinner)
        titleRow.addArrangedSubview(titleLabel)

        containerStack.addArrangedSubview(iconView)
        containerStack.addArrangedSubview(titleRow)
        containerStack.addArrangedSubview(messageLabel)
        containerStack.addArrangedSubview(actionButton)

        addSubview(containerStack)
        NSLayoutConstraint.activate([
            containerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            containerStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            containerStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            containerStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
        ])
    }

    // MARK: - Public API

    /// Apply a configuration. Idempotent + reentrant — the same view
    /// instance can flip between configurations (e.g. loading → error)
    /// without recreating subviews.
    func configure(_ configuration: Configuration) {
        // Icon
        if let name = configuration.iconSystemName {
            iconView.image = UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: configuration.iconPointSize,
                    weight: configuration.iconWeight
                )
            )
            iconView.tintColor = configuration.iconTint
            iconView.isHidden = false
        } else {
            iconView.isHidden = true
            iconView.image = nil
        }

        // Spinner
        if configuration.showsSpinner {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }

        // Title
        titleLabel.text = configuration.title
        titleLabel.textColor = configuration.titleColor
        titleLabel.font = configuration.titleFont
        // titleRow visibility is governed by whether ANY child has content:
        // title text OR spinner running. With spinner hidesWhenStopped and
        // titleLabel hidden when empty, the row degrades naturally.
        titleLabel.isHidden = (configuration.title?.isEmpty ?? true)

        // Message
        messageLabel.text = configuration.message
        messageLabel.textColor = configuration.messageColor
        messageLabel.font = configuration.messageFont
        messageLabel.isHidden = (configuration.message?.isEmpty ?? true)

        // Action button
        if let actionTitle = configuration.actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            if let imageName = configuration.actionImageSystemName {
                actionButton.setImage(UIImage(systemName: imageName), for: .normal)
            } else {
                actionButton.setImage(nil, for: .normal)
            }
            actionButton.isHidden = false
            actionHandler = configuration.actionHandler
        } else {
            actionButton.isHidden = true
            actionHandler = nil
        }

        // Spacing
        containerStack.spacing = configuration.stackSpacing
        containerStack.setCustomSpacing(configuration.spacingAfterIcon, after: iconView)
    }

    // MARK: - Actions

    @objc private func actionButtonTapped() {
        actionHandler?()
    }
}

// MARK: - Configuration Presets

extension EmptyStateView.Configuration {

    /// "Nothing to show / no selection" presentation. Large thin icon,
    /// title2 + subheadline copy in tertiary tones. Matches the existing
    /// DIY look used by GroupDictionaryEditor / DictResourceEditor /
    /// DictInfo. Caller can post-mutate any field before passing to
    /// `configure(_:)`.
    static func placeholder(
        icon: String?,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        actionImage: String? = nil,
        actionHandler: (() -> Void)? = nil
    ) -> Self {
        var c = Self()
        c.iconSystemName = icon
        c.title = title
        c.message = message
        c.actionTitle = actionTitle
        c.actionImageSystemName = actionImage
        c.actionHandler = actionHandler
        return c
    }

    /// Compact in-list status presentation. Smaller icon (40pt regular),
    /// semibold 17 title with optional inline spinner, regular 15
    /// secondary-color message. Designed for empty/loading/no-results
    /// states embedded inside a scrollable list (vs the larger
    /// `.placeholder` which is the full-VC zero-state look).
    static func compact(
        icon: String?,
        title: String,
        message: String? = nil,
        showsSpinner: Bool = false,
        actionTitle: String? = nil,
        actionHandler: (() -> Void)? = nil
    ) -> Self {
        var c = Self()
        c.iconSystemName = icon
        c.iconPointSize = 40
        c.iconWeight = .regular
        c.iconTint = .secondaryLabel
        c.title = title
        c.titleFont = .systemFont(ofSize: 17, weight: .semibold)
        c.titleColor = .label
        c.showsSpinner = showsSpinner
        c.message = message
        c.messageFont = .systemFont(ofSize: 15)
        c.messageColor = .secondaryLabel
        c.stackSpacing = 8
        c.spacingAfterIcon = 12
        c.actionTitle = actionTitle
        c.actionHandler = actionHandler
        return c
    }

    /// In-progress "loading…" presentation — `.compact` + spinner.
    /// Kept as a named preset so callsites read declaratively ("this
    /// is a loading state") instead of `compact(..., showsSpinner: true)`.
    static func loading(
        icon: String?,
        title: String,
        message: String? = nil
    ) -> Self {
        compact(icon: icon, title: title, message: message, showsSpinner: true)
    }

    /// Error presentation bound directly to an `ODRError`. Orange tint
    /// + Retry button. Caller supplies the retry closure.
    static func error(
        _ odrError: ODRError,
        retryTitle: String,
        retry: @escaping () -> Void
    ) -> Self {
        var c = Self()
        c.iconSystemName = odrError.sfSymbol
        c.iconTint = .systemOrange
        c.title = odrError.localizedTitle
        c.message = odrError.localizedMessage
        c.actionTitle = retryTitle
        c.actionImageSystemName = "arrow.clockwise"
        c.actionHandler = retry
        return c
    }
}
