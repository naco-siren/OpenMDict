//
//  AICoachViewController.swift
//  OpenMDict-iOS
//
//  M14: AI Coach facade — lists available study modes.
//  Checks AI availability on every viewWillAppear and shows a triage
//  placeholder if the model isn't ready (device, toggle, download).
//

import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26, *)
final class AICoachViewController: UIViewController {

    // MARK: - Types

    private nonisolated enum Section: Hashable, Sendable {
        case main
    }

    private nonisolated enum ListItem: Hashable, Sendable {
        case mode(StudyMode)
    }

    /// Quiz modes shown to the user. Flashcard is a POC-stage debug feature
    /// (AI generates prose directly, gated by both locale and content
    /// language with unstable quality) and is hidden in Release builds —
    /// see the `#if DEBUG` blocks below.
    private nonisolated enum StudyMode: Int, CaseIterable, Hashable, Sendable {
        case wordTinder
        case amongWurds
        case morphemeMaury
        case phraseFeud
        #if DEBUG
        case flashcard
        #endif

        /// Explicit override: synthesized `allCases` would silently shrink
        /// in Release; spelling it out makes the omission obvious at the
        /// callsite and survives future refactors that toggle the flag.
        static var allCases: [StudyMode] {
            #if DEBUG
            return [.wordTinder, .amongWurds, .morphemeMaury, .phraseFeud, .flashcard]
            #else
            return [.wordTinder, .amongWurds, .morphemeMaury, .phraseFeud]
            #endif
        }

        /// Leading icon for the cell. Word Tinder uses an SF symbol; Among
        /// wUrdS and Morpheme Maury use bespoke artwork (template-rendered
        /// PNGs in `Assets.xcassets`) — the imagesets are configured with
        /// `template-rendering-intent: template`, so `imageProperties.tintColor`
        /// applies to them like it does to SF symbols. Phrase Feud uses
        /// `square.grid.2x2.fill` — directly evokes the show's 2-column
        /// answer board.
        var image: UIImage? {
            switch self {
            case .wordTinder:     return UIImage(systemName: "flame")
            case .amongWurds:     return UIImage(named: "AmongWurds")
            case .morphemeMaury:  return UIImage(named: "MorphemeMaury")
            case .phraseFeud:     return UIImage(systemName: "square.grid.2x2.fill")
            #if DEBUG
            case .flashcard:      return UIImage(systemName: "rectangle.on.rectangle")
            #endif
            }
        }

        /// Per-mode tint applied to the leading icon (works for both SF
        /// symbols and template-rendered PNGs).
        var iconTint: UIColor {
            switch self {
            case .wordTinder:     return .systemPink
            case .amongWurds:     return .systemOrange
            case .morphemeMaury:  return .systemIndigo
            case .phraseFeud:     return .systemYellow  // Family Feud iconic gold
            #if DEBUG
            case .flashcard:      return .tintColor
            #endif
            }
        }

        var title: String {
            switch self {
            case .wordTinder:     return L10n.AICoach.wordTinder
            case .amongWurds:     return L10n.AICoach.amongWurds
            case .morphemeMaury:  return L10n.AICoach.morphemeMaury
            case .phraseFeud:     return L10n.AICoach.phraseFeud
            #if DEBUG
            case .flashcard:      return L10n.AICoach.flashcard
            #endif
            }
        }

        var description: String {
            switch self {
            case .wordTinder:     return L10n.AICoach.wordTinderDesc
            case .amongWurds:     return L10n.AICoach.amongWurdsDesc
            case .morphemeMaury:  return L10n.AICoach.morphemeMauryDesc
            case .phraseFeud:     return L10n.AICoach.phraseFeudDesc
            #if DEBUG
            case .flashcard:      return L10n.AICoach.flashcardDesc
            #endif
            }
        }
    }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, ListItem>!

    // Triage placeholder — top-to-bottom linear stack inside a UIScrollView.
    // Top section (ContentUnavailableView-style): icon + title + subtitle +
    // CTA button. Bottom section (insetGrouped-style "How to fix" info card)
    // is hideable; existing triage states (deviceNotEligible / etc.) keep it
    // hidden, the new language-mismatch states reveal it.
    private let triageView = UIView()
    private let triageScrollView = UIScrollView()
    private let triageOuterStack = UIStackView()  // vertical, fills scroll content

    // Top section (icon + title + subtitle + CTA button)
    private let triageTopStack = UIStackView()
    private let triageIcon = UIImageView()
    private let triageTitle = UILabel()
    private let triageSubtitle = UILabel()
    private let triageButton = UIButton(type: .system)

    // Up to two parallel "Solution N: ..." sections. Each is independently
    // hideable based on whether Apple Intelligence has any candidates for
    // that fix path. The header text is renumbered dynamically: if only one
    // solution is visible it shows "1", regardless of which one.
    //
    // Solution 1 — change app language via per-app language override.
    //   Step 1 row is TAPPABLE (chevron + tap gesture) and deep-links to
    //   the app's Settings page via openSettingsURLString. Step 2 has a
    //   subtitle listing languages compatible with the user's current
    //   device region, computed at runtime.
    private let triageSolution1Section = UIView()
    private let triageSolution1Header = UILabel()
    private let triageSolution1Card = UIView()
    private let triageSol1Step1Row = UIControl()  // tappable cell wrapper
    private let triageSol1Step1Icon = UIImageView()
    private let triageSol1Step1Label = UILabel()
    private let triageSol1Step1Chevron = UIImageView()
    private let triageSol1Step2Icon = UIImageView()
    private let triageSol1Step2Label = UILabel()
    private let triageSol1Step2Subtitle = UILabel()

    // Solution 2 — change device region. Step 1 is read-only (no public
    // deep-link API for this pane). Step 2 has a subtitle listing regions
    // compatible with the user's current language. The side-effect warning
    // row is folded INTO this card (rather than a separate "Notes" section)
    // because the caveat specifically applies to region changes.
    private let triageSolution2Section = UIView()
    private let triageSolution2Header = UILabel()
    private let triageSolution2Card = UIView()
    private let triageSol2Step1Icon = UIImageView()
    private let triageSol2Step1Label = UILabel()
    private let triageSol2Step2Icon = UIImageView()
    private let triageSol2Step2Label = UILabel()
    private let triageSol2Step2Subtitle = UILabel()
    private let triageSol2WarningIcon = UIImageView()
    private let triageSol2WarningLabel = UILabel()

    // Fallback message — shown when neither solution applies (e.g. ru-RU
    // where Apple Intelligence supports neither Russian nor the RU region).
    private let triageFallbackLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.AICoach.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground

        if navigationController?.presentingViewController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(dismissSelf)
            )
            navigationController?.isModalInPresentation = true
        }

        setupCollectionView()
        setupDataSource()
        setupTriagePlaceholder()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateAvailabilityState()
    }

    // MARK: - Actions

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    // MARK: - Availability Check

    private func updateAvailabilityState() {
        guard AICoach.isGenerationReady else {
            showTriage()
            return
        }
        // Locale check happens AFTER `isGenerationReady` because the model-
        // download / opt-in / hardware-eligibility states are blockers that
        // any user can fix; locale support depends on what languages Apple
        // ships in the model and is a different conversation. For ru/uk/
        // ar/hi users (entirely unsupported) and diaspora users (e.g.
        // zh-Hans-US, language family supported but BCP-47 tag not), this
        // shows a blocking screen with locale-specific guidance.
        guard AICoachService.isCurrentLocaleSupported() else {
            showLocaleMismatchTriage()
            return
        }
        hideTriage()
        applySnapshot()
    }

    // MARK: - Triage Placeholder

    private func setupTriagePlaceholder() {
        // Root container — fills the safe area and switches between hidden
        // (when the modes list is showing) and visible (when any triage state
        // is active).
        triageView.translatesAutoresizingMaskIntoConstraints = false
        triageView.isHidden = true
        triageView.backgroundColor = .systemGroupedBackground
        view.addSubview(triageView)

        // ScrollView wraps the whole thing so on small screens / with bumped-
        // up dynamic type the info card scrolls into view instead of clipping.
        triageScrollView.translatesAutoresizingMaskIntoConstraints = false
        triageScrollView.alwaysBounceVertical = true
        triageScrollView.contentInsetAdjustmentBehavior = .automatic
        triageView.addSubview(triageScrollView)

        // Outer linear stack — children laid out top-to-bottom. Pinning its
        // edges to scrollView's contentLayoutGuide makes the scrollView's
        // contentSize follow the stack's intrinsic size automatically, so
        // overflow becomes scrollable without any manual centering tricks.
        triageOuterStack.axis = .vertical
        triageOuterStack.alignment = .fill
        triageOuterStack.spacing = 36
        triageOuterStack.translatesAutoresizingMaskIntoConstraints = false
        triageScrollView.addSubview(triageOuterStack)

        // Top section (icon + title + subtitle + CTA button), centered
        // horizontally. Labels get an explicit width = parent stack width so
        // multi-line wrapping works under `alignment: .center` (which would
        // otherwise size them to single-line intrinsic content size).
        triageTopStack.axis = .vertical
        triageTopStack.alignment = .center
        triageTopStack.spacing = 10

        triageIcon.preferredSymbolConfiguration = .init(pointSize: 56, weight: .regular)
        triageIcon.tintColor = .secondaryLabel
        triageTopStack.addArrangedSubview(triageIcon)
        triageTopStack.setCustomSpacing(16, after: triageIcon)

        triageTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        triageTitle.textColor = .label
        triageTitle.textAlignment = .center
        triageTitle.numberOfLines = 0
        triageTopStack.addArrangedSubview(triageTitle)

        triageSubtitle.font = .preferredFont(forTextStyle: .callout)
        triageSubtitle.textColor = .secondaryLabel
        triageSubtitle.textAlignment = .center
        triageSubtitle.numberOfLines = 0
        triageTopStack.addArrangedSubview(triageSubtitle)
        triageTopStack.setCustomSpacing(20, after: triageSubtitle)

        // CTA button — tinted bordered, intrinsic size (compact), centered
        // by the parent stack's alignment.
        var btnConfig = UIButton.Configuration.borderedTinted()
        btnConfig.cornerStyle = .large
        btnConfig.buttonSize = .large
        triageButton.configuration = btnConfig
        triageButton.isHidden = true
        triageButton.addTarget(self, action: #selector(triageButtonTapped), for: .touchUpInside)
        triageTopStack.addArrangedSubview(triageButton)

        // Build the two solution cards + fallback message. All start hidden
        // and are revealed conditionally by `showLocaleMismatchTriage`.
        setupTriageSolution1Card()
        setupTriageSolution2Card()
        setupTriageFallback()
        triageSolution1Section.isHidden = true
        triageSolution2Section.isHidden = true
        triageFallbackLabel.isHidden = true

        triageOuterStack.addArrangedSubview(triageTopStack)
        triageOuterStack.addArrangedSubview(triageSolution1Section)
        triageOuterStack.addArrangedSubview(triageSolution2Section)
        triageOuterStack.addArrangedSubview(triageFallbackLabel)

        let frameGuide = triageScrollView.frameLayoutGuide
        let contentGuide = triageScrollView.contentLayoutGuide

        NSLayoutConstraint.activate([
            triageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            triageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            triageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            triageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            triageScrollView.topAnchor.constraint(equalTo: triageView.topAnchor),
            triageScrollView.leadingAnchor.constraint(equalTo: triageView.leadingAnchor),
            triageScrollView.trailingAnchor.constraint(equalTo: triageView.trailingAnchor),
            triageScrollView.bottomAnchor.constraint(equalTo: triageView.bottomAnchor),

            // Pin outerStack to the scroll content guide — this is what makes
            // contentSize == stack height. 64pt top breathing room matches
            // typical empty-state padding.
            triageOuterStack.topAnchor.constraint(equalTo: contentGuide.topAnchor, constant: 64),
            triageOuterStack.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor, constant: -32),
            triageOuterStack.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: 16),
            triageOuterStack.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -16),

            // Lock content width to frame width so labels wrap to visible width
            // instead of expanding the contentSize horizontally.
            triageOuterStack.widthAnchor.constraint(equalTo: frameGuide.widthAnchor, constant: -32),

            // Multi-line wrap: title and subtitle take the full stack width.
            triageTitle.widthAnchor.constraint(equalTo: triageTopStack.widthAnchor),
            triageSubtitle.widthAnchor.constraint(equalTo: triageTopStack.widthAnchor),
        ])
    }

    /// Builds Solution 1's card: change app language. Step 1 is a tappable
    /// row (chevron + tap gesture) that opens the app's Settings page via
    /// `openSettingsURLString` (the only public iOS API to deep-link into
    /// Settings.app, and conveniently the right destination for per-app
    /// language). Step 2 has a subtitle listing candidate languages.
    private func setupTriageSolution1Card() {
        let cardStack = makeSectionLayout(
            section: triageSolution1Section,
            header: triageSolution1Header,
            card: triageSolution1Card
        )
        // Step 1 is a tappable cell — wrapped in UIControl so we get the
        // standard touchDown/touchUpInside gesture handling + a highlight
        // on press, plus a trailing chevron for affordance.
        let row1 = makeTappableInfoRow(
            container: triageSol1Step1Row,
            icon: triageSol1Step1Icon,
            titleLabel: triageSol1Step1Label,
            chevron: triageSol1Step1Chevron,
            iconSymbol: "1.circle.fill",
            iconTint: .systemBlue
        )
        triageSol1Step1Row.addTarget(
            self,
            action: #selector(openAppSettings),
            for: .touchUpInside
        )
        let row2 = makeInfoRow(
            icon: triageSol1Step2Icon,
            titleLabel: triageSol1Step2Label,
            subtitleLabel: triageSol1Step2Subtitle,
            iconSymbol: "2.circle.fill",
            iconTint: .systemBlue
        )
        cardStack.addArrangedSubview(row1)
        cardStack.addArrangedSubview(makeRowSeparator())
        cardStack.addArrangedSubview(row2)
    }

    /// Builds Solution 2's card: change device region. Step 1 is read-only
    /// (no public API for that pane). The side-effect warning is folded in
    /// as a third row (with its own separator) rather than a separate
    /// "Notes" section — the caveat specifically applies to region changes,
    /// so it belongs inside this solution's card.
    private func setupTriageSolution2Card() {
        let cardStack = makeSectionLayout(
            section: triageSolution2Section,
            header: triageSolution2Header,
            card: triageSolution2Card
        )
        let row1 = makeInfoRow(
            icon: triageSol2Step1Icon,
            titleLabel: triageSol2Step1Label,
            subtitleLabel: nil,
            iconSymbol: "1.circle.fill",
            iconTint: .systemBlue
        )
        let row2 = makeInfoRow(
            icon: triageSol2Step2Icon,
            titleLabel: triageSol2Step2Label,
            subtitleLabel: triageSol2Step2Subtitle,
            iconSymbol: "2.circle.fill",
            iconTint: .systemBlue
        )
        let warningRow = makeInfoRow(
            icon: triageSol2WarningIcon,
            titleLabel: triageSol2WarningLabel,
            subtitleLabel: nil,
            iconSymbol: "exclamationmark.triangle.fill",
            iconTint: .systemOrange
        )
        cardStack.addArrangedSubview(row1)
        cardStack.addArrangedSubview(makeRowSeparator())
        cardStack.addArrangedSubview(row2)
        cardStack.addArrangedSubview(makeRowSeparator())
        cardStack.addArrangedSubview(warningRow)
    }

    /// Configures the fallback label shown when neither solution applies
    /// (rare — both `hasLanguageCandidatesForCurrentRegion` and
    /// `isAppleAILanguageSupported` are false, e.g. ru-RU).
    private func setupTriageFallback() {
        triageFallbackLabel.font = .preferredFont(forTextStyle: .body)
        triageFallbackLabel.textColor = .secondaryLabel
        triageFallbackLabel.numberOfLines = 0
        triageFallbackLabel.textAlignment = .center
        triageFallbackLabel.adjustsFontForContentSizeCategory = true
        triageFallbackLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Wires up the standard insetGrouped-section layout (header label
    /// above, rounded card below, vertical card stack inside) and returns
    /// the card stack so the caller can add their own rows + separators.
    private func makeSectionLayout(
        section: UIView,
        header: UILabel,
        card: UIView
    ) -> UIStackView {
        // Section header — uppercase footnote, like UICollectionView
        // grouped-section headers.
        header.font = .preferredFont(forTextStyle: .footnote)
        header.textColor = .secondaryLabel
        header.numberOfLines = 0
        header.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(header)

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(card)

        let cardStack = UIStackView()
        cardStack.axis = .vertical
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: section.topAnchor),
            header.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -16),

            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: section.bottomAnchor),

            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return cardStack
    }

    /// One row in an info card: leading icon + title (and optional subtitle
    /// stacked below). Padding mimics UITableViewCell.subtitle defaults.
    /// The icon is top-aligned (not vertically centered) so it lines up
    /// with the title row when the subtitle wraps to multiple lines.
    private func makeInfoRow(
        icon: UIImageView,
        titleLabel: UILabel,
        subtitleLabel: UILabel?,
        iconSymbol: String,
        iconTint: UIColor
    ) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false

        icon.image = UIImage(systemName: iconSymbol)
        icon.tintColor = iconTint
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)

        if let subtitleLabel {
            subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
            subtitleLabel.textColor = .secondaryLabel
            subtitleLabel.numberOfLines = 0
            subtitleLabel.adjustsFontForContentSizeCategory = true
            textStack.addArrangedSubview(subtitleLabel)
            textStack.setCustomSpacing(4, after: titleLabel)
        }

        row.addSubview(textStack)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
        ])

        return row
    }

    /// Hairline separator between info card rows, inset on the leading side
    /// to match UITableViewCell default style.
    private func makeRowSeparator() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 52),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
        return container
    }

    /// Tappable variant of `makeInfoRow` — leading icon, title, trailing
    /// chevron, no subtitle. The whole row is a UIControl so the caller can
    /// `addTarget` for `.touchUpInside`. Highlights on press for feedback.
    private func makeTappableInfoRow(
        container: UIControl,
        icon: UIImageView,
        titleLabel: UILabel,
        chevron: UIImageView,
        iconSymbol: String,
        iconTint: UIColor
    ) -> UIControl {
        container.translatesAutoresizingMaskIntoConstraints = false

        icon.image = UIImage(systemName: iconSymbol)
        icon.tintColor = iconTint
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Don't intercept taps — let the parent UIControl handle them.
        titleLabel.isUserInteractionEnabled = false
        container.addSubview(titleLabel)

        chevron.image = UIImage(systemName: "chevron.right")
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = .init(pointSize: 13, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isUserInteractionEnabled = false
        container.addSubview(chevron)

        // Press feedback: subtle background tint while held.
        container.addAction(UIAction { [weak container] _ in
            container?.backgroundColor = .systemFill
        }, for: [.touchDown, .touchDragEnter])
        container.addAction(UIAction { [weak container] _ in
            UIView.animate(withDuration: 0.18) {
                container?.backgroundColor = .clear
            }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])

        return container
    }

    @objc private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private enum TriageAction {
        case none
        case openSettings
        case learnMore
    }

    private var triageAction: TriageAction = .none

    private func showTriage() {
        collectionView.isHidden = true
        triageView.isHidden = false
        // Existing triage states are short and self-contained — they don't
        // need any of the locale-mismatch solution cards.
        triageSolution1Section.isHidden = true
        triageSolution2Section.isHidden = true
        triageFallbackLabel.isHidden = true

        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                triageIcon.image = UIImage(systemName: isPad
                    ? "ipad.gen2.landscape.slash" : "iphone.gen2.slash")
                triageTitle.text = L10n.AICoach.Triage.deviceTitle
                triageSubtitle.text = L10n.AICoach.Triage.deviceMessage
                triageButton.setTitle(L10n.AICoach.Triage.learnMore, for: .normal)
                triageButton.isHidden = false
                triageAction = .learnMore

            case .appleIntelligenceNotEnabled:
                triageIcon.image = UIImage(systemName: "apple.intelligence.badge.xmark")
                triageTitle.text = L10n.AICoach.Triage.notEnabledTitle
                triageSubtitle.text = L10n.AICoach.Triage.notEnabledMessage
                triageButton.setTitle(L10n.AICoach.openSettings, for: .normal)
                triageButton.isHidden = false
                triageAction = .openSettings

            case .modelNotReady:
                triageIcon.image = UIImage(systemName: "apple.intelligence.badge.xmark")
                triageTitle.text = L10n.AICoach.Triage.downloadingTitle
                triageSubtitle.text = L10n.AICoach.Triage.downloadingMessage
                triageButton.isHidden = true
                triageAction = .none

            @unknown default:
                triageIcon.image = UIImage(systemName: "questionmark.circle")
                triageTitle.text = L10n.AICoach.Triage.unknownTitle
                triageSubtitle.text = L10n.AICoach.Triage.unknownMessage
                triageButton.isHidden = true
                triageAction = .none
            }
        default:
            // Shouldn't reach here if isGenerationReady is false,
            // but handle defensively
            triageIcon.image = UIImage(systemName: "questionmark.circle")
            triageTitle.text = L10n.AICoach.Triage.unknownTitle
            triageSubtitle.text = L10n.AICoach.Triage.unknownMessage
            triageButton.isHidden = true
            triageAction = .none
        }
        #endif
    }

    /// Blocking screen shown when `Locale.current` isn't directly supported
    /// by Apple Intelligence. Presents up to two parallel solution sections:
    ///   1. Change app language (per-app override; low impact, has CTA)
    ///   2. Change device region (high impact, has side-effect warning)
    /// Each is independently hideable based on whether candidates exist for
    /// that path. Numbering is dynamic: if only Solution 2 applies, it's
    /// shown as "Solution 1: Change Region".
    ///
    /// Edge case: when neither solution applies (e.g. ru-RU where Apple
    /// supports neither Russian nor the RU region), the fallback label
    /// shows a generic message instead.
    private func showLocaleMismatchTriage() {
        collectionView.isHidden = true
        triageView.isHidden = false

        // Reuse the AI-feature-blocked icon — user already sees this for
        // the deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady
        // states, so it reads as "AI Coach unavailable" rather than
        // introducing a new concept.
        triageIcon.image = UIImage(systemName: "apple.intelligence.badge.xmark")

        // Top section — unified title + subtitle that frames the problem
        // around the variable (app language) given the prerequisite (region).
        triageTitle.text = L10n.AICoach.Triage.localeMismatchTitle
        let regionName = AICoachService.currentRegionDisplayName()
        let languageName = AICoachService.currentLanguageDisplayName()
        triageSubtitle.text = L10n.AICoach.Triage.localeMismatchSubtitle(
            region: regionName,
            language: languageName
        )

        let solution1Visible = AICoachService.hasLanguageCandidatesForCurrentRegion()
        let solution2Visible = AICoachService.isAppleAILanguageSupported()

        // Renumber based on which solutions are visible. If only one shows,
        // it's numbered "1" regardless of which one.
        var solutionNumber = 0

        if solution1Visible {
            solutionNumber += 1
            triageSolution1Header.text = L10n.AICoach.Triage.solutionHeader(
                number: solutionNumber,
                descriptor: L10n.AICoach.Triage.solutionChangeAppLanguage
            ).uppercased()
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "OpenMDict"
            triageSol1Step1Label.text = L10n.AICoach.Triage.solutionLanguageStep1(appName: appName)
            triageSol1Step2Label.text = L10n.AICoach.Triage.solutionLanguageStep2
            triageSol1Step2Subtitle.text = AICoachService.supportedLanguagesListForCurrentRegion()
            triageSolution1Section.isHidden = false
        } else {
            triageSolution1Section.isHidden = true
        }

        if solution2Visible {
            solutionNumber += 1
            triageSolution2Header.text = L10n.AICoach.Triage.solutionHeader(
                number: solutionNumber,
                descriptor: L10n.AICoach.Triage.solutionChangeRegion
            ).uppercased()
            triageSol2Step1Label.text = L10n.AICoach.Triage.solutionRegionStep1
            triageSol2Step2Label.text = L10n.AICoach.Triage.solutionRegionStep2
            triageSol2Step2Subtitle.text = AICoachService.supportedRegionsListForCurrentLanguage()
            triageSol2WarningLabel.text = L10n.AICoach.Triage.solutionRegionWarning
            triageSolution2Section.isHidden = false
        } else {
            triageSolution2Section.isHidden = true
        }

        // Fallback: neither path forward — show generic message instead.
        triageFallbackLabel.text = L10n.AICoach.Triage.fallbackMessage
        triageFallbackLabel.isHidden = (solutionNumber > 0)

        // No top-level CTA button — Solution 1's step 1 cell has its own
        // chevron-tappable affordance; Solution 2 has no public deep-link.
        triageButton.isHidden = true
        triageAction = .none
    }

    private func hideTriage() {
        triageView.isHidden = true
        collectionView.isHidden = false
    }

    @objc private func triageButtonTapped() {
        switch triageAction {
        case .none:
            break
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .learnMore:
            let url = Self.appleIntelligenceSupportURL()
            UIApplication.shared.open(url)
        }
    }

    /// Build localized Apple Support URL for AI device compatibility.
    /// Format: https://support.apple.com/{lang}-{region}/121115
    private static func appleIntelligenceSupportURL() -> URL {
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        let regionCode = Locale.current.region?.identifier.lowercased() ?? "us"
        let urlString = "https://support.apple.com/\(langCode)-\(regionCode)/121115"
        return URL(string: urlString) ?? URL(string: "https://support.apple.com/en-us/121115")!
    }

    // MARK: - Collection View

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfig.headerMode = .none
        let layout = UICollectionViewCompositionalLayout.list(using: listConfig)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    // MARK: - Data Source

    private func setupDataSource() {
        let modeReg = UICollectionView.CellRegistration<UICollectionViewListCell, StudyMode> {
            cell, _, mode in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = mode.title
            content.secondaryText = mode.description
            content.image = mode.image
            content.imageProperties.tintColor = mode.iconTint
            // App-Store-style "featured card" sizing — icons fill enough of
            // the leading column to show off bespoke artwork detail (the
            // hand-drawn curves in AmongWurds / MorphemeMaury would be
            // unreadable at the default ~22pt body-text size).
            content.imageProperties.preferredSymbolConfiguration =
                UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            // Hard cap on rendered size — keeps PNGs from blowing out and
            // bounds SF symbols from going beyond the column.
            content.imageProperties.maximumSize = CGSize(width: 56, height: 56)
            // Reserve a fixed-width column so text after the image starts at
            // the same x regardless of the icon's intrinsic aspect ratio.
            content.imageProperties.reservedLayoutSize = CGSize(width: 60, height: 60)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .mode(let mode):
                return collectionView.dequeueConfiguredReusableCell(using: modeReg, for: indexPath, item: mode)
            }
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, ListItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(StudyMode.allCases.map { .mode($0) }, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - UICollectionViewDelegate

@available(iOS 26, *)
extension AICoachViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .mode(let mode):
            let vc: UIViewController
            switch mode {
            case .wordTinder:
                vc = WordTinderViewController()
            case .amongWurds:
                vc = AmongWurdsViewController()
            case .morphemeMaury:
                vc = MorphemeMauryViewController()
            case .phraseFeud:
                vc = PhraseFeudViewController()
            #if DEBUG
            case .flashcard:
                vc = FlashcardPOCViewController()
            #endif
            }
            navigationController?.pushViewController(vc, animated: true)
        }
    }
}
