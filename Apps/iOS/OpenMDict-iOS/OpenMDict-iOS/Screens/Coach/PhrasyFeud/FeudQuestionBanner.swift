//
//  FeudQuestionBanner.swift
//  OpenMDict-iOS
//
//  Question card. Plain rounded rectangle with a dark-brown border and
//  bright yellow text — the iconic FF "monitor" look. The proscenium
//  arch is the OUTER frame (`FeudArchBackground`), not this banner.
//

import UIKit

@available(iOS 26, *)
final class FeudQuestionBanner: UIView {

    private let questionLabel = UILabel()

    private let verticalPadding: CGFloat

    override init(frame: CGRect) {
        self.verticalPadding = 12
        super.init(frame: frame)
        setupViews()
    }

    /// Customizable top/bottom padding around the question label. The
    /// top banner uses the default 12pt; the centered START prompt
    /// overlay passes 24pt for a beefier card.
    init(verticalPadding: CGFloat = 12) {
        self.verticalPadding = verticalPadding
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        backgroundColor = FeudPalette.boardBackground  // deep blue interior
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 3
        layer.borderColor = FeudPalette.frameDarkBrown.cgColor

        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionLabel.font = FeudPalette.bannerFont(size: 17)
        questionLabel.textColor = FeudPalette.goldText
        questionLabel.textAlignment = .center
        questionLabel.numberOfLines = 0
        // No `adjustsFontSizeToFitWidth` here. With `numberOfLines = 0` it's
        // a UIKit footgun — text can collapse to an unreadably small size
        // (or zero) at unexpected widths. Wrap to multiple lines instead:
        // banner height grows naturally with longer questions.
        addSubview(questionLabel)

        NSLayoutConstraint.activate([
            questionLabel.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            questionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            questionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            questionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
        ])
    }

    /// Override the question label's font. Used by the centered START
    /// prompt overlay which wants 3× the size of the top banner.
    func setFont(_ font: UIFont) {
        questionLabel.font = font
    }

    func setQuestion(_ question: String, animated: Bool = false) {
        // ALL CAPS to match the broadcast banner style.
        let upper = question.uppercased()
        if animated {
            // Same horizontal-axis flip the answer cards use, so the
            // banner reading "TAP TO START" → actual question lands
            // with a coherent visual language.
            UIView.transition(
                with: self,
                duration: 0.45,
                options: [.transitionFlipFromBottom, .curveEaseOut]
            ) {
                self.questionLabel.text = upper
            }
        } else {
            questionLabel.text = upper
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Without this, `numberOfLines = 0` labels compute intrinsic
        // content size as a SINGLE line at the natural text width — even
        // when their frame is narrower. The banner then sizes to a
        // single-line height, the wrapped multi-line text overflows
        // vertically, and `byTruncatingTail` doesn't help because the
        // overflow happens through frame clipping, not line truncation.
        // Visible result: banner shrinks to a thin bar with text clipped
        // out of view. Setting `preferredMaxLayoutWidth` to the actual
        // available width lets the label compute multi-line intrinsic
        // height, banner grows accordingly, text becomes visible.
        let labelWidth = bounds.width - 28  // 14pt leading + 14pt trailing
        if labelWidth > 0 && questionLabel.preferredMaxLayoutWidth != labelWidth {
            questionLabel.preferredMaxLayoutWidth = labelWidth
        }
    }
}
