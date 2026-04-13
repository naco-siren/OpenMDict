//
//  AICoachPresenter.swift
//  OpenMDict-iOS
//
//  M14: Shared entry point for AI Coach features.
//  Presents AICoachViewController (facade list) modally.
//  Called from MainSplitViewController (iPad) and CompactTabBarController (iPhone).
//

import UIKit

@available(iOS 26, *)
func presentAICoach(from presenter: UIViewController) {
    let vc = AICoachViewController()
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = presenter.traitCollection.horizontalSizeClass == .regular
        ? .formSheet : .pageSheet
    presenter.present(nav, animated: true)
}
