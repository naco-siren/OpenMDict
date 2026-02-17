//
//  ActionNavigationController.swift
//  OpenMDict-ActionExtension
//
//  Principal class for the Action Extension.
//  Wraps ActionViewController in a UINavigationController so that
//  `navigationItem` (Done, Bookmark, Zoom) renders a proper nav bar.
//
//  The system instantiates this class (via NSExtensionPrincipalClass)
//  and presents it as a half-sheet.
//

import UIKit

class ActionNavigationController: UINavigationController {

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        let rootVC = ActionViewController()
        super.init(rootViewController: rootVC)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sheet detents — configured here since the system presents
        // this navigation controller, not the child ActionViewController.
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
    }
}
