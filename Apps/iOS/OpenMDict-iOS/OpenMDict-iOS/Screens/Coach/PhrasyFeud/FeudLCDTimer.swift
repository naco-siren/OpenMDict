//
//  FeudLCDTimer.swift
//  OpenMDict-iOS
//
//  Two LCD-style displays flank the buzzer — left = remaining seconds,
//  right = points scored. Each instance is a self-contained card
//  with a caption ("TIME" / "TOTAL") and a 3-digit value, both rendered
//  white on a shared black background with a dark-brown frame.
//
//  Previously the caption was a separate UILabel outside the timer
//  view, which (a) read as two visually disjoint pieces and (b) didn't
//  share the black "LCD pane" background. Wrapping them into one card
//  with a single bg + border ties them together as one game-show
//  scoreboard.
//

import UIKit

@available(iOS 26, *)
final class FeudLCDTimer: UIView {

    private let captionLabel = UILabel()
    private let digitLabel = UILabel()

    /// 0-999. Always rendered as a zero-padded 3-digit number so the
    /// width is stable across counts (`007` not `7`, `100`, `999`).
    /// Out-of-range values are clamped before display.
    var value: Int = 0 {
        didSet { digitLabel.text = String(format: "%03d", max(0, min(999, value))) }
    }

    /// Caption is fixed at init (one of "TIME" / "TOTAL" via L10n) —
    /// the two timers never swap roles within a round.
    init(caption: String) {
        super.init(frame: .zero)
        captionLabel.text = caption
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // No `intrinsicContentSize` override — the box auto-sizes from the
    // caption + digit labels' intrinsics + the 4pt edge inset
    // constraints below.

    private func setupViews() {
        backgroundColor = .black
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous
        layer.borderWidth = 2
        layer.borderColor = FeudPalette.frameDarkBrown.cgColor

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        // 18pt = the old 14pt × 1.3 bump for legibility.
        captionLabel.font = .systemFont(ofSize: 18, weight: .heavy)
        captionLabel.textColor = .white
        captionLabel.textAlignment = .center
        addSubview(captionLabel)

        digitLabel.translatesAutoresizingMaskIntoConstraints = false
        // 34pt = the old 26pt × 1.3 bump. Monospaced so digit positions
        // don't shift as the value changes (e.g. `099 → 100` doesn't
        // jitter the layout).
        digitLabel.font = .monospacedSystemFont(ofSize: 34, weight: .heavy)
        digitLabel.textColor = .white
        digitLabel.textAlignment = .center
        digitLabel.text = "000"
        addSubview(digitLabel)

        // 4pt edge inset all around; caption stacked above digits with
        // a small internal gap. View auto-sizes from this content.
        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            digitLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2),
            digitLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            digitLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            digitLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            digitLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
}
