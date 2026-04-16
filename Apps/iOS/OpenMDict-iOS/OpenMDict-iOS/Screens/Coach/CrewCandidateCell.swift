//
//  CrewCandidateCell.swift
//  OpenMDict-iOS
//
//  M14: Custom collection view cell for Among wUrdS morphology quiz.
//  Colored card background (crew color) with centered word.
//  States: normal, markedSus, revealedCrewmate, revealedImposter,
//  revealedMurdered (= in-play murder — crewmate identity is revealed
//  as a side effect of death), revealedEjectedCrewmate/Imposter.
//
//  Word + subtitle live in a centered UIStackView so a hidden subtitle
//  truly collapses (no lingering offset).
//

import UIKit

@available(iOS 26, *)
final class CrewCandidateCell: UICollectionViewCell {

    // MARK: - Types

    nonisolated enum CellState: Hashable, Sendable {
        case skeleton                           // loading: dim gray placeholder, no text
        case skeletonLit                        // loading: crew-colored, pulsing, no text yet
        case normal
        case markedSus
        case revealedCrewmate                   // alive crewmate (teal)
        case revealedImposter                   // alive imposter (red)
        case revealedMurdered                   // killed crewmate — identity REVEALED
        case revealedEjectedCrewmate            // ejected + was crewmate
        case revealedEjectedImposter            // ejected + was imposter
    }

    // MARK: - UI

    private let cardView = UIView()
    private let wordLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let statusIcon = UIImageView()
    private let murderedStamp = StampView(text: "MURDERED", color: .systemRed, angle: -.pi / 12)
    private let ejectedStamp = StampView(text: "EJECTED", color: UIColor.systemBrown, angle: -.pi / 12)

    /// The background the VC paints behind the cell — cards pre-blend their
    /// tint over this so they're fully opaque (no see-through to the space
    /// debris layer behind the grid).
    private static let baseBg = UIColor(white: 0.06, alpha: 1)

    /// Mix a tint color over the fixed dark base and return a fully opaque
    /// UIColor. Replaces `tint.withAlphaComponent(a)` on translucent cards.
    private static func opaqueTint(_ tint: UIColor, alpha a: CGFloat) -> UIColor {
        var tR: CGFloat = 0, tG: CGFloat = 0, tB: CGFloat = 0, tA: CGFloat = 0
        var bR: CGFloat = 0, bG: CGFloat = 0, bB: CGFloat = 0, bA: CGFloat = 0
        tint.getRed(&tR, green: &tG, blue: &tB, alpha: &tA)
        baseBg.getRed(&bR, green: &bG, blue: &bB, alpha: &bA)
        return UIColor(
            red: a * tR + (1 - a) * bR,
            green: a * tG + (1 - a) * bG,
            blue: a * tB + (1 - a) * bB,
            alpha: 1.0
        )
    }

    static let reuseIdentifier = "CrewCandidateCell"

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupUI() {
        contentView.backgroundColor = .clear

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.layer.cornerRadius = 14
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true
        contentView.addSubview(cardView)

        wordLabel.font = .systemFont(ofSize: 20, weight: .bold)
        wordLabel.textColor = .white
        wordLabel.textAlignment = .center
        wordLabel.adjustsFontSizeToFitWidth = true
        wordLabel.minimumScaleFactor = 0.65
        wordLabel.numberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        subtitleLabel.textAlignment = .center

        // Vertical stack auto-collapses when subtitle is hidden,
        // so word stays true-centered without any manual offset math.
        textStack.axis = .vertical
        textStack.alignment = .center
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(wordLabel)
        textStack.addArrangedSubview(subtitleLabel)
        cardView.addSubview(textStack)

        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.preferredSymbolConfiguration = .init(pointSize: 14, weight: .semibold)
        statusIcon.isHidden = true
        cardView.addSubview(statusIcon)

        // Reveal stamps (Word Tinder style)
        for stamp in [murderedStamp, ejectedStamp] {
            stamp.translatesAutoresizingMaskIntoConstraints = false
            stamp.isHidden = true
            cardView.addSubview(stamp)
            NSLayoutConstraint.activate([
                stamp.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
                stamp.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            textStack.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            textStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            textStack.leadingAnchor.constraint(greaterThanOrEqualTo: cardView.leadingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -10),

            statusIcon.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 6),
            statusIcon.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -8),
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    // MARK: - Configure

    func configure(word: String, crewColor: UIColor, state: CellState) {
        wordLabel.text = word
        applyState(state, crewColor: crewColor)
    }

    private func applyState(_ state: CellState, crewColor: UIColor) {
        // Reset — subtitle truly collapses (stack view), stamps hidden,
        // card appearance neutral. NOTE: do not touch wordLabel.text here;
        // configure() sets it, and prepareForReuse clears it between dequeues.
        statusIcon.isHidden = true
        subtitleLabel.isHidden = true
        murderedStamp.isHidden = true
        ejectedStamp.isHidden = true
        cardView.layer.borderWidth = 0
        cardView.alpha = 1
        contentView.transform = .identity
        wordLabel.isHidden = false
        wordLabel.font = .systemFont(ofSize: 20, weight: .bold)
        wordLabel.textColor = .white

        switch state {
        case .skeleton:
            cardView.backgroundColor = UIColor(white: 0.12, alpha: 1)
            wordLabel.isHidden = true

        case .skeletonLit:
            cardView.backgroundColor = Self.opaqueTint(crewColor, alpha: 0.25)
            wordLabel.isHidden = true

        case .normal:
            cardView.backgroundColor = Self.opaqueTint(crewColor, alpha: 0.35)

        case .markedSus:
            cardView.backgroundColor = Self.opaqueTint(.systemRed, alpha: 0.25)
            cardView.layer.borderWidth = 2.5
            cardView.layer.borderColor = UIColor.systemRed.cgColor
            wordLabel.textColor = .systemRed
            statusIcon.isHidden = false
            statusIcon.image = UIImage(systemName: "exclamationmark.triangle.fill")
            statusIcon.tintColor = .systemRed

        case .revealedCrewmate:
            cardView.backgroundColor = Self.opaqueTint(.systemTeal, alpha: 0.20)
            cardView.layer.borderWidth = 2
            cardView.layer.borderColor = UIColor.systemTeal.cgColor
            subtitleLabel.isHidden = false
            subtitleLabel.text = L10n.AICoach.AmongWurds.crewmateLabel
            subtitleLabel.textColor = .systemTeal

        case .revealedImposter:
            cardView.backgroundColor = Self.opaqueTint(.systemRed, alpha: 0.25)
            cardView.layer.borderWidth = 2
            cardView.layer.borderColor = UIColor.systemRed.cgColor
            subtitleLabel.isHidden = false
            subtitleLabel.text = L10n.AICoach.AmongWurds.imposterLabel
            subtitleLabel.textColor = .systemRed

        case .revealedMurdered:
            // Dimmed via lower tint-alpha (card stays fully opaque).
            cardView.backgroundColor = Self.opaqueTint(.systemTeal, alpha: 0.10)
            cardView.layer.borderWidth = 2
            cardView.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.55).cgColor
            subtitleLabel.isHidden = false
            subtitleLabel.text = L10n.AICoach.AmongWurds.crewmateLabel
            subtitleLabel.textColor = UIColor.systemTeal.withAlphaComponent(0.7)
            murderedStamp.isHidden = false

        case .revealedEjectedCrewmate:
            cardView.backgroundColor = Self.opaqueTint(.systemTeal, alpha: 0.10)
            cardView.layer.borderWidth = 2
            cardView.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.55).cgColor
            subtitleLabel.isHidden = false
            subtitleLabel.text = L10n.AICoach.AmongWurds.crewmateLabel
            subtitleLabel.textColor = UIColor.systemTeal.withAlphaComponent(0.7)
            ejectedStamp.isHidden = false

        case .revealedEjectedImposter:
            cardView.backgroundColor = Self.opaqueTint(.systemRed, alpha: 0.12)
            cardView.layer.borderWidth = 2
            cardView.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.55).cgColor
            subtitleLabel.isHidden = false
            subtitleLabel.text = L10n.AICoach.AmongWurds.imposterLabel
            subtitleLabel.textColor = UIColor.systemRed.withAlphaComponent(0.7)
            ejectedStamp.isHidden = false
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        wordLabel.text = nil
        wordLabel.attributedText = nil
        wordLabel.isHidden = false
        subtitleLabel.isHidden = true
        statusIcon.isHidden = true
        murderedStamp.isHidden = true
        ejectedStamp.isHidden = true
        cardView.layer.borderWidth = 0
        cardView.transform = .identity
        cardView.alpha = 1
        contentView.transform = .identity
        contentView.alpha = 1
    }
}

// MARK: - StampView (Word Tinder style)

/// Bordered rotated text stamp, like Tinder's "LIKE" / "NOPE" overlays.
@available(iOS 26, *)
private final class StampView: UIView {
    init(text: String, color: UIColor, angle: CGFloat) {
        super.init(frame: .zero)

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 20, weight: .heavy)
        label.textColor = color
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        layer.borderWidth = 2.5
        layer.borderColor = color.cgColor
        layer.cornerRadius = 5

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])

        transform = CGAffineTransform(rotationAngle: angle)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }
}
