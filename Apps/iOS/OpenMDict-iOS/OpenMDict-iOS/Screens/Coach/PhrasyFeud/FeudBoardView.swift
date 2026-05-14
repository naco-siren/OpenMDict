//
//  FeudBoardView.swift
//  OpenMDict-iOS
//
//  Answer board container — wraps the stack of `FeudCardView`s in a
//  double-border chrome (outer dark brown ring, inner gold ring) atop
//  the deep-blue board background. Built with three nested `UIView`s
//  + corner radii rather than CAShapeLayers, since this shape is just
//  a rounded rectangle (no arch on this element — the arch is the
//  outer screen frame, in `FeudArchBackground`).
//
//  Column count is width-driven, not size-class-driven: this VC always
//  presents in compact horizontal trait, so size class would never flip
//  to 2-col on its own. `layoutSubviews` measures the actual card-stack
//  width (already net of board chrome + interior padding) and picks 2
//  columns when each card can clear `minCardWidth` — kicks in on
//  landscape iPhones and most iPad presentations.
//
//  Saved per-slot states survive layout rebuilds, so rotation doesn't
//  flip revealed answers back to blank.
//

import UIKit

@available(iOS 26, *)
final class FeudBoardView: UIView {

    // MARK: - State

    private(set) var cards: [FeudCardView] = []
    private var slotStates: [FeudCardView.CardState] = []

    // MARK: - Chrome layers

    private let middleRing = UIView()    // gold band
    private let interior = UIView()      // deep blue play area
    private let scrollView = UIScrollView()
    private let cardStack = UIStackView()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Chrome dimensions hoisted to static so the column-count detector
    // in `layoutSubviews` can derive cardStack width directly from
    // self.bounds, without waiting for the grandchild scrollView+cardStack
    // frames to propagate.
    private static let outerThickness: CGFloat = 6
    private static let innerThickness: CGFloat = 6
    private static let scrollPadding: CGFloat = 10

    private func setupChrome() {
        // Outer ring: dark brown
        backgroundColor = FeudPalette.frameDarkBrown
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous

        let outerThickness = Self.outerThickness
        let innerThickness = Self.innerThickness

        // Middle ring: gold
        middleRing.backgroundColor = FeudPalette.goldBorder
        middleRing.layer.cornerRadius = max(0, layer.cornerRadius - outerThickness)
        middleRing.layer.cornerCurve = .continuous
        middleRing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(middleRing)

        // Interior: black. The dots-on-black arch backdrop matches the
        // stage tone, and the answer cards already carry the blue
        // gradients — a deep-blue interior here would compete with the
        // cards visually rather than letting them pop.
        interior.backgroundColor = .black
        interior.layer.cornerRadius = max(0, middleRing.layer.cornerRadius - innerThickness)
        interior.layer.cornerCurve = .continuous
        interior.translatesAutoresizingMaskIntoConstraints = false
        middleRing.addSubview(interior)

        // ScrollView wraps the card stack so cards can overflow the
        // board's visible height (e.g. iPhone landscape with 4 cards in
        // 1-col, or any layout where vertical space is tight). Without
        // this wrapper, cardStack would push board.height beyond the
        // safe-area cap, autolayout would conflict, and the banner —
        // having lower compression resistance than the cap — would
        // collapse as the only thing it could yield.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        interior.addSubview(scrollView)

        // Card stack — `.fill` distribution since cards now have a fixed
        // natural height (scoreSize + 8) from their internal constraints.
        cardStack.axis = .vertical
        cardStack.spacing = 8
        cardStack.distribution = .fill
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(cardStack)

        NSLayoutConstraint.activate([
            middleRing.topAnchor.constraint(equalTo: topAnchor, constant: outerThickness),
            middleRing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: outerThickness),
            middleRing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -outerThickness),
            middleRing.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -outerThickness),

            interior.topAnchor.constraint(equalTo: middleRing.topAnchor, constant: innerThickness),
            interior.leadingAnchor.constraint(equalTo: middleRing.leadingAnchor, constant: innerThickness),
            interior.trailingAnchor.constraint(equalTo: middleRing.trailingAnchor, constant: -innerThickness),
            interior.bottomAnchor.constraint(equalTo: middleRing.bottomAnchor, constant: -innerThickness),

            // ScrollView fills interior with `scrollPadding` (the role
            // cardStack used to play directly).
            scrollView.topAnchor.constraint(equalTo: interior.topAnchor, constant: Self.scrollPadding),
            scrollView.leadingAnchor.constraint(equalTo: interior.leadingAnchor, constant: Self.scrollPadding),
            scrollView.trailingAnchor.constraint(equalTo: interior.trailingAnchor, constant: -Self.scrollPadding),
            scrollView.bottomAnchor.constraint(equalTo: interior.bottomAnchor, constant: -Self.scrollPadding),

            // CardStack fills scrollView's content area; pinning width
            // to the frame guide locks horizontal scroll to off and lets
            // cardStack drive vertical contentSize.
            cardStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            cardStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    // MARK: - Public chrome access

    /// Read-only handle to the board's black interior — the area
    /// inside the brown + gold double border, where cards live. The
    /// VC parents the loading/error placeholder stack into this so
    /// the placeholder text reads against the board's black surface
    /// instead of the arch backdrop's yellow-dotted black (gold text
    /// on yellow dots is unreadable). Pair with `setCardsHidden(_:)`
    /// to swap between cards and placeholder content occupying the
    /// same area.
    var contentArea: UIView { interior }

    /// Toggle the card scroll view's visibility without removing it
    /// from the view hierarchy. Used during loading/placeholder
    /// states: cards hidden, placeholder visible in the same black
    /// interior. Per-slot states survive across hide/show cycles.
    func setCardsHidden(_ hidden: Bool) {
        scrollView.isHidden = hidden
    }

    // MARK: - Slot management

    func setSlotCount(_ count: Int) {
        // Lower bound is 1 (NOT 2) because PhrasyFeudEngine's single-word
        // fallback path returns a Round with exactly one ScoredAnswer.
        // The rebuildLayout math (rowCount = ceil(count/columns)) handles
        // count=1 the same as count=2..6 — one card in one row.
        precondition((1...6).contains(count), "FeudBoardView supports 1-6 slots, got \(count)")
        slotStates = Array(repeating: .blank, count: count)
        // Rebuild eagerly with the current column count (default 1) so the
        // card stack has arranged subviews — and therefore intrinsic content
        // size — for the FIRST layout pass. Without this the empty stack has
        // zero intrinsic height, the board's `<=` bottom constraint lets it
        // collapse, and the whole VC's vertical layout solves to something
        // weird (banner gets pushed too). `layoutSubviews` may rebuild again
        // if measured width crosses the column-count threshold.
        rebuildLayout()
    }

    func setCardState(at index: Int, _ state: FeudCardView.CardState, animated: Bool = false) {
        guard slotStates.indices.contains(index) else { return }
        slotStates[index] = state
        guard cards.indices.contains(index) else { return }
        let card = cards[index]
        if animated {
            // Broadcast contract: cards flip around the horizontal
            // center axis (front face spinning bottom-up to reveal the
            // back). `.transitionFlipFromBottom` does exactly that —
            // snapshots the view before + after the closure, then
            // animates the 3D rotation between them.
            UIView.transition(
                with: card,
                duration: 0.45,
                options: [.transitionFlipFromBottom, .curveEaseOut]
            ) {
                card.apply(state)
            }
        } else {
            card.apply(state)
        }
    }

    /// Brief scale pulse on a single card — used when the user submits
    /// an answer that matches an ALREADY revealed slot (so the dup is
    /// visibly acknowledged without a full re-flip animation).
    /// Different feedback channel from the wrong-answer board shake
    /// (whole-board kinetic-bad) and the per-card celebration burst
    /// (particle festive); this is a brief "yes, that one" pulse.
    func pulseCard(at index: Int) {
        guard cards.indices.contains(index) else { return }
        let card = cards[index]
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.08
        pulse.duration = 0.14
        pulse.autoreverses = true
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        card.layer.add(pulse, forKey: "pulse")
    }

    // MARK: - Layout

    /// Threshold per card. Compared against the card stack's actual width
    /// (already net of board chrome + interior padding), so this is the
    /// "real" card width target — not the screen width.
    private static let minCardWidth: CGFloat = 200
    private static let interCardSpacing: CGFloat = 8

    private var currentColumnCount: Int = 1

    private func columnCount(forStackWidth stackWidth: CGFloat) -> Int {
        (stackWidth - Self.interCardSpacing) / 2 >= Self.minCardWidth ? 2 : 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Derive stack width from `self.bounds` (NOT cardStack.bounds).
        // cardStack is a grandchild via middleRing → interior →
        // scrollView, and its frame isn't propagated yet when
        // self.layoutSubviews fires on the FIRST layout pass. Reading
        // cardStack.bounds.width returned 0 there, the early-out fired,
        // no rebuild happened, and we'd stay stuck at 1-col until the
        // user manually resized the modal (which forced another full
        // layout pass with cardStack frames already set). Subtracting
        // the chrome from self.bounds gives us the correct future
        // cardStack width without waiting for that propagation.
        let chromeWidth = 2 * (Self.outerThickness + Self.innerThickness + Self.scrollPadding)
        let stackWidth = bounds.width - chromeWidth
        guard stackWidth > 0, !slotStates.isEmpty else { return }
        let target = columnCount(forStackWidth: stackWidth)
        if target != currentColumnCount {
            currentColumnCount = target
            rebuildLayout()
            // setNeedsLayout queues a follow-up pass to lay out the new
            // arranged subviews. The `target == currentColumnCount`
            // guard above prevents recursion.
            setNeedsLayout()
        }
    }

    private func rebuildLayout() {
        cardStack.arrangedSubviews.forEach {
            cardStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cards.removeAll(keepingCapacity: true)

        let count = slotStates.count
        guard count > 0 else { return }

        let columns = currentColumnCount
        let rowCount = (count + columns - 1) / columns
        // Hardcoded score-square dimensions. Single value for both column
        // counts; if 1-col cards feel cramped or 2-col score boxes feel
        // too dominant, this can fork into per-column values without any
        // other change (FeudCardView already accepts a per-instance size).
        let scoreSize: CGFloat = 48

        for row in 0..<rowCount {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = Self.interCardSpacing
            rowStack.distribution = .fillEqually

            let cardsInThisRow: Int
            if row == rowCount - 1 && count % columns != 0 {
                cardsInThisRow = count % columns
            } else {
                cardsInThisRow = columns
            }
            for _ in 0..<cardsInThisRow {
                let card = FeudCardView(scoreSize: scoreSize)
                rowStack.addArrangedSubview(card)
                cards.append(card)
            }
            cardStack.addArrangedSubview(rowStack)
        }

        for (i, state) in slotStates.enumerated() where cards.indices.contains(i) {
            cards[i].apply(state)
        }
    }
}
