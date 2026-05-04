//
//  CardStackView.swift
//  OpenMDict-iOS
//
//  M14 Word Tinder: Apple Wallet-style card stack with swipe gesture.
//  Windowed rendering: only maxVisibleCards+1 views exist at any time.
//  Normalized curves (dim S-curve + scale power curve) ensure the
//  deepest visible card always reaches cap regardless of total count.
//

import UIKit

@available(iOS 26, *)
protocol CardStackViewDelegate: AnyObject {
    func cardStack(_ stack: CardStackView, didSwipe word: String,
                   direction: CandidateCardView.SwipeDirection)
    func cardStack(_ stack: CardStackView, didUpdateDrag direction: CandidateCardView.SwipeDirection,
                   progress: CGFloat)
    func cardStackDidCancelDrag(_ stack: CardStackView)
    func cardStackDidEmpty(_ stack: CardStackView)
}

@available(iOS 26, *)
final class CardStackView: UIView {

    weak var delegate: CardStackViewDelegate?

    private let cardHorizontalInset: CGFloat = 20
    private let maxVisibleCards = 7

    private let swipeThreshold: CGFloat = 100
    private let velocityThreshold: CGFloat = 500

    private let irrelevantLow  = CGFloat.pi / 3
    private let irrelevantHigh = CGFloat.pi * 2.0 / 3

    // MARK: - Data

    /// Full word queue (not all rendered).
    private var allWords: [String] = []
    /// Index into allWords for the next word to render when a slot opens.
    private var nextWordIndex = 0
    /// How many words remain unswipped (including rendered + not-yet-rendered).
    private var remainingCount = 0

    /// Rendered cards: index 0 = deepest (back), last = front.
    private var cards: [CandidateCardView] = []
    private var bottomConstraints: [NSLayoutConstraint] = []
    private var dimOverlays: [CandidateCardView: UIView] = [:]

    // MARK: - Setup

    func configure(words: [String]) {
        cards.forEach { $0.removeFromSuperview() }
        dimOverlays.values.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        bottomConstraints.removeAll()
        dimOverlays.removeAll()

        allWords = words
        remainingCount = words.count

        // Render up to maxVisibleCards + 1 (extra one at deepest, hidden behind others)
        let renderCount = min(words.count, maxVisibleCards + 1)
        for i in 0..<renderCount {
            let card = CandidateCardView(word: words[i])
            card.translatesAutoresizingMaskIntoConstraints = false
            cards.append(card)
        }
        nextWordIndex = renderCount

        layoutCards()
        attachPanGesture()
    }

    // MARK: - Normalized Curves

    // MARK: - Hardcoded Visual Tables
    // Each array is indexed by distFromFront (0 = front card).
    // Values are hand-tuned for the best visual depth perception.
    // Cards beyond maxVisibleCards (index 7+) clamp to the last value.

    /// Scale factor per position. Linear ramp from 1.0 → 0.4.
    private static let scaleTable: [CGFloat] =
        [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4]

    /// Overlap ratio per position: how much of the card above is covered
    /// by the card below (0 = no overlap, 1 = fully covered).
    /// Used to compute peek height: peek = cardHeight * (1 - overlap).
    private static let overlapTable: [CGFloat] =
        [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.85]

    /// Dim overlay alpha per position (light mode).
    /// Derived from overlap table: deeper = more dimmed.
    /// Dark mode multiplies by 0.75.
    private static let dimTable: [CGFloat] =
        [0.0, 0.15, 0.30, 0.45, 0.60, 0.75, 1.0]

    private func tableValue<T>(_ table: [T], for distFromFront: Int) -> T {
        table[min(distFromFront, table.count - 1)]
    }

    private func dimAlpha(for distFromFront: Int) -> CGFloat {
        let base = tableValue(Self.dimTable, for: distFromFront)
        let isDark = traitCollection.userInterfaceStyle == .dark
        return isDark ? base * 0.75 : base
    }

    private func cardScale(for distFromFront: Int) -> CGFloat {
        tableValue(Self.scaleTable, for: distFromFront)
    }

    /// Cumulative bottom offset from peek heights derived from overlap table.
    /// peek(n) = cardHeight * (1 - overlap[n]).
    /// Cards at maxVisibleCards or beyond clamp (hidden behind last visible).
    private func cumulativeOffset(for distFromFront: Int) -> CGFloat {
        guard distFromFront > 0 else { return 0 }
        let cappedDist = min(distFromFront, maxVisibleCards - 1)
        let cardHeight: CGFloat = 96  // CandidateCardView fixed height
        var total: CGFloat = 0
        for n in 1...cappedDist {
            let overlap = tableValue(Self.overlapTable, for: n)
            total += cardHeight * (1 - overlap)
        }
        return total
    }

    /// Shadow parameters for a card at given distance from front.
    private func shadowParams(for distFromFront: Int) -> (opacity: Float, radius: CGFloat, offsetY: CGFloat) {
        if distFromFront == 0 {
            return (0.25, 12, 6)
        }
        return (0.06, 3, 1)
    }

    private func applyShadow(to card: CandidateCardView, distFromFront: Int) {
        let p = shadowParams(for: distFromFront)
        card.layer.shadowOpacity = p.opacity
        card.layer.shadowRadius = p.radius
        card.layer.shadowOffset = CGSize(width: 0, height: p.offsetY)
    }

    // MARK: - Layout

    private func layoutCards() {
        for (i, card) in cards.enumerated() {
            addSubview(card)

            let distFromFront = cards.count - 1 - i
            let bottomOffset = cumulativeOffset(for: distFromFront)

            let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: cardHorizontalInset)
            let trailing = card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -cardHorizontalInset)
            let bottom = card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomOffset)
            NSLayoutConstraint.activate([leading, trailing, bottom])
            bottomConstraints.append(bottom)

            applyShadow(to: card, distFromFront: distFromFront)
            applyDim(to: card, distFromFront: distFromFront)

            let scale = cardScale(for: distFromFront)
            card.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    private func applyDim(to card: CandidateCardView, distFromFront: Int) {
        dimOverlays[card]?.removeFromSuperview()
        dimOverlays[card] = nil

        guard distFromFront > 0 else { return }

        let dim = UIView()
        dim.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.0, alpha: 1)
                : UIColor(white: 0.4, alpha: 1)
        }
        dim.alpha = dimAlpha(for: distFromFront)
        dim.translatesAutoresizingMaskIntoConstraints = false
        dim.isUserInteractionEnabled = false
        dim.layer.cornerRadius = 12
        card.addSubview(dim)
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: card.topAnchor),
            dim.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        dimOverlays[card] = dim
    }

    // MARK: - Advance Animation (vending machine)

    private func animateCardsForward() {
        guard !cards.isEmpty else { return }

        for (i, _) in cards.enumerated() {
            let distFromFront = cards.count - 1 - i
            let newOffset = cumulativeOffset(for: distFromFront)
            bottomConstraints[i].constant = -newOffset
        }

        UIView.animate(withDuration: 0.35, delay: 0,
                       usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0.3) {
            self.layoutIfNeeded()

            for (i, card) in self.cards.enumerated() {
                let distFromFront = self.cards.count - 1 - i
                self.applyShadow(to: card, distFromFront: distFromFront)

                let scale = self.cardScale(for: distFromFront)
                card.transform = CGAffineTransform(scaleX: scale, y: scale)

                if let dim = self.dimOverlays[card] {
                    if distFromFront == 0 {
                        dim.alpha = 0
                    } else {
                        dim.alpha = self.dimAlpha(for: distFromFront)
                    }
                }
            }
        } completion: { _ in
            if let frontCard = self.cards.last {
                self.dimOverlays[frontCard]?.removeFromSuperview()
                self.dimOverlays[frontCard] = nil
            }
        }
    }

    // MARK: - Pan Gesture

    private var panGesture: UIPanGestureRecognizer?

    private func attachPanGesture() {
        if let old = panGesture { removeGestureRecognizer(old) }
        guard !cards.isEmpty else { panGesture = nil; return }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        panGesture = pan
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let card = cards.last else { return }

        let translation = pan.translation(in: self)
        let velocity = pan.velocity(in: self)

        switch pan.state {
        case .began:
            break

        case .changed:
            let rotationAngle = translation.x / 1000 * (.pi / 6)
            card.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                .rotated(by: rotationAngle)

            let (direction, progress) = classifySwipe(translation: translation)
            card.updateSwipeFeedback(direction: direction, progress: progress)
            delegate?.cardStack(self, didUpdateDrag: direction, progress: progress)

        case .ended, .cancelled:
            let distance = hypot(translation.x, translation.y)
            let speed = hypot(velocity.x, velocity.y)
            let (direction, _) = classifySwipe(translation: translation)

            if distance > swipeThreshold || speed > velocityThreshold {
                flyOut(card: card, direction: direction)
            } else {
                UIView.animate(withDuration: 0.3, delay: 0,
                               usingSpringWithDamping: 0.7,
                               initialSpringVelocity: 0.5) {
                    card.transform = .identity
                    card.resetSwipeFeedback()
                }
                delegate?.cardStackDidCancelDrag(self)
            }

        default:
            break
        }
    }

    // MARK: - Direction Classification

    private func classifySwipe(translation: CGPoint) -> (CandidateCardView.SwipeDirection, CGFloat) {
        let angle = atan2(-translation.y, translation.x)
        let distance = hypot(translation.x, translation.y)
        let progress = min(distance / swipeThreshold, 1.0)

        let direction: CandidateCardView.SwipeDirection
        if angle >= irrelevantLow && angle <= irrelevantHigh {
            direction = .up
        } else if angle < irrelevantLow && angle > -irrelevantLow {
            direction = .right
        } else {
            direction = .left
        }

        return (direction, progress)
    }

    // MARK: - Fly Out Animation

    private func flyOut(card: CandidateCardView,
                        direction: CandidateCardView.SwipeDirection) {
        let flyDistance: CGFloat = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) + 200

        let targetTranslation: CGPoint
        let rotationAngle: CGFloat

        switch direction {
        case .right:
            targetTranslation = CGPoint(x: flyDistance, y: -50)
            rotationAngle = .pi / 6
        case .left:
            targetTranslation = CGPoint(x: -flyDistance, y: -50)
            rotationAngle = -.pi / 6
        case .up:
            targetTranslation = CGPoint(x: 0, y: -flyDistance)
            rotationAngle = 0
        }

        let word = card.word
        card.updateSwipeFeedback(direction: direction, progress: 1.0)

        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseIn]) {
            card.transform = CGAffineTransform(translationX: targetTranslation.x,
                                               y: targetTranslation.y)
                .rotated(by: rotationAngle)
        } completion: { [weak self] _ in
            guard let self else { return }

            // Remove card
            card.removeFromSuperview()
            let removedIndex = self.cards.count - 1
            self.cards.removeLast()
            self.bottomConstraints.remove(at: removedIndex)
            self.dimOverlays[card]?.removeFromSuperview()
            self.dimOverlays[card] = nil
            self.remainingCount -= 1

            self.delegate?.cardStack(self, didSwipe: word, direction: direction)

            if self.remainingCount == 0 {
                self.delegate?.cardStackDidEmpty(self)
            } else {
                // Replenish standby slot (silently, no animation)
                self.replenishStandbyCard()
                self.animateCardsForward()
                self.attachPanGesture()
            }
        }
    }

    /// If there are unrendered words left, silently place a new card at the
    /// standby slot (same position as the deepest visible card — fully hidden
    /// behind it). No animation needed; the card just "exists" there and will
    /// become visible when the deck advances.
    private func replenishStandbyCard() {
        guard nextWordIndex < allWords.count else { return }

        let word = allWords[nextWordIndex]
        nextWordIndex += 1

        let card = CandidateCardView(word: word)
        card.translatesAutoresizingMaskIntoConstraints = false

        // Insert at index 0 (behind everything in z-order)
        cards.insert(card, at: 0)
        insertSubview(card, at: 0)

        // Standby slot: same offset/dim/scale as the deepest visible card
        // (cumulativeOffset caps at maxVisibleCards-1, so it sits right behind)
        let distFromFront = cards.count - 1
        let bottomOffset = cumulativeOffset(for: distFromFront)

        let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: cardHorizontalInset)
        let trailing = card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -cardHorizontalInset)
        let bottom = card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomOffset)
        NSLayoutConstraint.activate([leading, trailing, bottom])
        bottomConstraints.insert(bottom, at: 0)

        applyShadow(to: card, distFromFront: distFromFront)
        applyDim(to: card, distFromFront: distFromFront)

        let scale = cardScale(for: distFromFront)
        card.transform = CGAffineTransform(scaleX: scale, y: scale)

        // Force immediate layout so the card is already at its standby
        // position before animateCardsForward runs — otherwise it flies
        // in from (0,0) during the animation ("天外飞仙" bug).
        layoutIfNeeded()
    }

    // MARK: - Programmatic Swipe (footer button tap)

    func swipeFrontCard(direction: CandidateCardView.SwipeDirection) {
        guard !cards.isEmpty else { return }
        cards.last?.updateSwipeFeedback(direction: direction, progress: 1.0)
        flyOut(card: cards.last!, direction: direction)
    }
}
