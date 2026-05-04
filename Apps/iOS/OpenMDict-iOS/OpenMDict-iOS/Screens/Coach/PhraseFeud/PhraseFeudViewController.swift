//
//  PhraseFeudViewController.swift
//  OpenMDict-iOS
//
//  Family Feud parody quiz. The user's bookmarked words become the
//  hidden answers on a board; AI generates a "Name a word that …"
//  question that ties 2-6 of them together; user guesses by typing.
//
//  This file is the FOUNDATION (step 1 of the 4-commit rollout):
//    - Phase machine scaffold (loading / questionReveal / playing /
//      endRound / finale) — only `playing` populated for visual review.
//    - Hardcoded sample question + 4 sample answers; no AI engine yet.
//    - Static board + banner; no flip animation, no input field, no
//      strike X overlay. Those land in step 3.
//
//  Layout (z-stacked under nav bar):
//    1. `FeudArchBackground` (full-screen) — proscenium-arch silhouette
//       with double border (dark brown outer + gold inner) framing the
//       dark-gray + yellow-dot play area.
//    2. Question banner — centered horizontally, ~half screen wide.
//    3. Answer board — wider, double-bordered card stack below banner.
//

import UIKit

@available(iOS 26, *)
final class PhraseFeudViewController: UIViewController {

    // MARK: - Phase machine

    private enum Phase {
        case loading        // AI generating question + grouping bookmarks
        case questionReveal // banner pops in, board face-down
        case playing        // input active, cards reveal as matched
        case endRound       // 3 strikes OR all matched — flip remaining
        case finale         // total score + Next CTA
    }

    private var currentPhase: Phase = .loading

    // MARK: - UI

    private let archBackground = FeudArchBackground()
    private let banner = FeudQuestionBanner()
    private let board = FeudBoardView()
    private let buzzer = FeudBuzzerView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.AICoach.phraseFeud
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .black

        // Force dark appearance — show graphics expect black/dark surrounds.
        // Nav bar tint is overridden in `viewWillAppear` (UIKit reads nav
        // bar styling from the controller it's pushed onto).
        overrideUserInterfaceStyle = .dark

        setupLayout()

        // Step 1 placeholder: jump straight into a hardcoded "playing"
        // state with sample data so we can visually verify the layout.
        showHardcodedDemo()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Nav title + back chevron use the dimmer banner-text yellow, not
        // the bright bulb yellow of the dots/bands — text reads better in
        // a slightly more muted gold.
        navigationController?.navigationBar.tintColor = FeudPalette.goldText
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: FeudPalette.goldText,
            .font: FeudPalette.bannerFont(size: 17),
        ]
        navigationController?.navigationBar.titleTextAttributes = titleAttrs
    }

    // MARK: - Layout

    private func setupLayout() {
        // Arch backdrop fills the whole view, including under the nav bar
        // (the arch curves at the very top). Pin to view, NOT safe area.
        archBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(archBackground)

        // Question banner + board sit INSIDE the arch's content area.
        // Adding them as siblings of archBackground (not children of its
        // contentContainer) gives them direct constraints to the safe
        // area without wrestling with the arch's frame extending below.
        banner.translatesAutoresizingMaskIntoConstraints = false
        board.translatesAutoresizingMaskIntoConstraints = false
        // Banner must NEVER yield vertical space — the cards live inside
        // a scroll view, so vertical pressure should push card overflow
        // into the scroller, not collapse the banner. Default
        // compression resistance is .defaultHigh, which would lose to
        // any required constraint that needs a smaller banner.
        banner.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(banner)
        view.addSubview(board)

        buzzer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buzzer)
        buzzer.addAction(UIAction { [weak self] _ in
            self?.presentAnswerInput()
        }, for: .touchUpInside)

        let safe = view.safeAreaLayoutGuide

        // Banner width = `min(200, safe.width × 0.5)`. The two `<=` caps
        // bind the upper bound; the `=200` at .defaultHigh pulls the
        // banner up to 200pt when the wider cap allows. This keeps the
        // banner narrow on every device — the typical question is wider
        // than 172pt of label space at 17pt, so `numberOfLines = 0`
        // wraps it to multiple lines. Reads like a vintage TV monitor
        // rather than a stretched pill.
        let bannerPreferredWidth = banner.widthAnchor.constraint(equalToConstant: 200)
        bannerPreferredWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Arch starts at the safe-area top (BELOW the nav bar) — the
            // broadcast set has no chrome above the proscenium, and the
            // arch peak should sit just above the question banner, not be
            // hidden behind the iOS nav bar.
            archBackground.topAnchor.constraint(equalTo: safe.topAnchor),
            archBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            archBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            archBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Banner sits just below the arch curve at its sides. With
            // archDepth=60, the curve at the banner's left/right edges
            // (x≈W/4) descends to y≈15, and the bands extend ~8pt below
            // that (≈y=23). banner.top at safe.top+30 stays clear of the
            // bands but is close enough that the arch reads as "framing"
            // the banner.
            banner.topAnchor.constraint(equalTo: safe.topAnchor, constant: 30),
            banner.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            banner.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.5),
            bannerPreferredWidth,

            // Board — wider than banner, framed by its own double border.
            // bottom is `equalTo` (not `<=`) so board takes a fixed slice
            // of the available vertical space; cards inside scroll if they
            // overflow.
            board.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 24),
            board.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28),
            board.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -28),
            board.bottomAnchor.constraint(equalTo: buzzer.topAnchor, constant: -16),

            // Buzzer centered horizontally at the bottom; cylinder
            // extends DOWN past view.bottom so it appears cropped (the
            // metal pipe disappears off the bottom of the screen, like
            // the podium continues out of frame). Pin bottom past view
            // bottom AND fix height — the dome lands at top of buzzer
            // (50pt above buzzer.bottom).
            buzzer.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            buzzer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 30),
            buzzer.widthAnchor.constraint(equalToConstant: 225),
            buzzer.heightAnchor.constraint(equalToConstant: 170),
        ])
    }

    // MARK: - Input

    private func presentAnswerInput() {
        // Step 3 wires the submitted text to the match logic. The
        // foundation just round-trips through an alert so the buzzer
        // tap → input → dismiss flow is verifiable end-to-end.
        let alert = UIAlertController(
            title: nil,
            message: "Submit your answer",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "Your answer…"
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .allCharacters
            tf.font = FeudPalette.answerFont(size: 17)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Submit", style: .default) { [weak alert] _ in
            _ = alert?.textFields?.first?.text
        })
        present(alert, animated: true)
    }

    // MARK: - Demo (replaced by AI engine in step 2)

    private func showHardcodedDemo() {
        banner.setQuestion("Name a word that means \u{201C}happy\u{201D}")

        board.setSlotCount(4)
        // Two revealed + two blank — covers both states in one screen.
        board.setCardState(at: 0, .revealed(answer: "joyful", score: 38))
        board.setCardState(at: 1, .blank)
        board.setCardState(at: 2, .revealed(answer: "cheerful", score: 24))
        board.setCardState(at: 3, .blank)
    }
}
