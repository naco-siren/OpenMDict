//
//  FeudBuzzerView.swift
//  OpenMDict-iOS
//
//  Cherry-red dome on a chrome cylinder — the iconic Family Feud
//  contestant buzzer that gets slapped to ring in. We only show the
//  dome + a slice of the cylinder (the rest disappears below the
//  podium in the broadcast set, and we don't have the vertical room
//  for a full cylinder anyway). Perspective is 3/4-overhead so the
//  dome is rendered as a flattened ellipse rather than a circle.
//
//  Drawn into a UIImage at first layout (cached, no continuous CALayer
//  cost), with a touchDown scale transform for tactile feedback.
//

import UIKit

@available(iOS 26, *)
final class FeudBuzzerView: UIControl {

    // MARK: - Subviews

    private let imageView = UIImageView()
    private var cachedImageSize: CGSize = .zero

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 225, height: 170)
    }

    private func setupViews() {
        backgroundColor = .clear

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Press feedback: bottom-anchored compression. The dome
        // (top of image) moves DOWN + flattens slightly while the
        // cylinder bottom stays put, so visually the button gets
        // pressed INTO the metal pipe — instead of the whole buzzer
        // shrinking around its center, which read as "shrink in
        // place" rather than "press down".
        //
        // Math: scale Y around the layer's default center anchor pulls
        // the bottom UP by `bounds.h/2 × (1-sy)`. We translate Y back
        // down by the same amount so the bottom returns to its frame
        // position, which leaves only the top half visibly compressing.
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let scaleX: CGFloat = 0.97
            let scaleY: CGFloat = 0.92
            let bottomCompensation = self.imageView.bounds.height / 2 * (1 - scaleY)
            UIView.animate(withDuration: 0.08) {
                self.imageView.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
                    .concatenating(CGAffineTransform(translationX: 0, y: bottomCompensation))
            }
        }, for: .touchDown)
        let restore = UIAction { [weak self] _ in
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.45,
                initialSpringVelocity: 0.6
            ) {
                self?.imageView.transform = .identity
            }
        }
        addAction(restore, for: .touchUpInside)
        addAction(restore, for: .touchUpOutside)
        addAction(restore, for: .touchCancel)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-render only when bounds actually change, not every layout
        // pass — the image is identical for identical sizes.
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != cachedImageSize {
            cachedImageSize = bounds.size
            imageView.image = Self.renderBuzzer(size: bounds.size)
        }
    }

    // MARK: - Rendering

    /// Renders the buzzer as: cylinder drawn FIRST (it stretches all
    /// the way to the bottom of the view; the caller positions the
    /// view past the screen edge so the cylinder appears cropped),
    /// then the dome ON TOP — wider than the cylinder and overlapping
    /// its lip by 15pt, so the cylinder's actual top edge is hidden
    /// behind the dome's "skirt".
    private static func renderBuzzer(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext

            // Fixed dome geometry — does NOT scale with view height.
            // The cylinder absorbs all extra height, so taller views
            // just show more cylinder (the part that gets cropped off
            // when the view extends past view.bottom).
            //
            // Dome aspect ~2.3:1 (size.width × 98). Cylinder top is
            // positioned 14pt up inside the dome's bottom rim so the
            // dome's "skirt" overhangs the cylinder. Cylinder is
            // proportionally narrower (cylinder width / view width
            // ratio is smaller than before): the dome was widened 50%
            // while the cylinder only widened 20%, so the dome's
            // overhang past the cylinder is more pronounced — reads as
            // a beefy mushroom-cap on a slimmer stem.
            let domeHeight: CGFloat = 98
            let domeOverlap: CGFloat = 14
            let cylinderInsetRatio: CGFloat = 0.278

            let domeRect = CGRect(x: 0, y: 0, width: size.width, height: domeHeight)
            let cylinderInset = size.width * cylinderInsetRatio
            let cylinderTop = domeHeight - domeOverlap
            let cylinderRect = CGRect(
                x: cylinderInset,
                y: cylinderTop,
                width: size.width - 2 * cylinderInset,
                height: size.height - cylinderTop
            )

            // 1. Cylinder body — chrome gradient with vertical-band
            //    highlights (bright/dark stripes suggest polished metal
            //    reflecting room lights).
            cg.saveGState()
            cg.addRect(cylinderRect)
            cg.clip()
            let chromeColors = [
                UIColor(white: 0.50, alpha: 1).cgColor,
                UIColor(white: 0.95, alpha: 1).cgColor,
                UIColor(white: 0.65, alpha: 1).cgColor,
                UIColor(white: 0.35, alpha: 1).cgColor,
                UIColor(white: 0.78, alpha: 1).cgColor,
            ]
            let chromeLocations: [CGFloat] = [0, 0.25, 0.55, 0.78, 1]
            if let g = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: chromeColors as CFArray,
                locations: chromeLocations
            ) {
                cg.drawLinearGradient(
                    g,
                    start: CGPoint(x: cylinderRect.minX, y: 0),
                    end: CGPoint(x: cylinderRect.maxX, y: 0),
                    options: []
                )
            }
            cg.restoreGState()

            // 2. Cylinder top "rim" — a tall darker ellipse centered
            //    at the dome's bottom edge. The dome covers the upper
            //    half of this ellipse; the visible LOWER half reads as
            //    the cylinder's curved top edge in 3/4 perspective —
            //    sells the cylinder as a 3D pipe rather than a flat
            //    rectangle. Without this, the cylinder felt too low-
            //    angle compared to the dome.
            let rimHeight: CGFloat = 24
            let rimRect = CGRect(
                x: cylinderRect.minX,
                y: domeHeight - rimHeight / 2,
                width: cylinderRect.width,
                height: rimHeight
            )
            cg.setFillColor(UIColor(white: 0.18, alpha: 1.0).cgColor)
            cg.fillEllipse(in: rimRect)

            // 3. Dome — solid red base (the ellipse fully overlaps the
            //    cylinder's top, so the cylinder's exposed lip stays
            //    hidden behind the dome).
            cg.setFillColor(UIColor(red: 0.7, green: 0.05, blue: 0.05, alpha: 1).cgColor)
            cg.fillEllipse(in: domeRect)

            // 4. Dome 3D gradient — bright top, deep crimson at the
            //    bottom rim where it meets the cylinder.
            cg.saveGState()
            cg.addEllipse(in: domeRect)
            cg.clip()
            let domeColors = [
                UIColor(red: 1.0,  green: 0.45, blue: 0.45, alpha: 1).cgColor,
                UIColor(red: 0.92, green: 0.10, blue: 0.10, alpha: 1).cgColor,
                UIColor(red: 0.45, green: 0.0,  blue: 0.0,  alpha: 1).cgColor,
            ]
            let domeLocations: [CGFloat] = [0, 0.55, 1]
            if let g = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: domeColors as CFArray,
                locations: domeLocations
            ) {
                cg.drawLinearGradient(
                    g,
                    start: CGPoint(x: 0, y: domeRect.minY),
                    end: CGPoint(x: 0, y: domeRect.maxY),
                    options: []
                )
            }
            cg.restoreGState()

            // 5. Specular highlight near the dome's apex (the wet look).
            let highlightWidth = domeRect.width * 0.42
            let highlightHeight = domeRect.height * 0.32
            let highlightRect = CGRect(
                x: domeRect.midX - highlightWidth / 2,
                y: domeRect.minY + domeRect.height * 0.08,
                width: highlightWidth,
                height: highlightHeight
            )
            cg.setFillColor(UIColor(white: 1, alpha: 0.55).cgColor)
            cg.fillEllipse(in: highlightRect)
        }
    }
}
