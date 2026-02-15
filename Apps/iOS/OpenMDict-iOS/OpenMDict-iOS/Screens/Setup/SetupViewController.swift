//
//  SetupViewController.swift
//  OpenMDict-iOS
//
//  Container/coordinator for the onboarding flow.
//  Manages three child view controllers:
//    Step 1: WelcomePageViewController
//    Step 2: PresetDictionaryPickerViewController
//    Step 3: ImportProgressViewController
//
//  Two modes:
//  - .firstInstall: full flow (Welcome → Picker → Progress), presented fullScreen
//  - .management: skip welcome, go to picker directly, presented as pageSheet
//
//  Uses child VC containment (not UIPageViewController) for precise control
//  over animated transitions between steps.
//

import UIKit

final class SetupViewController: UIViewController {

    // MARK: - Mode

    enum Mode {
        /// First launch: no dictionaries in CoreData. Full flow, non-dismissible.
        case firstInstall
        /// From sidebar management: skip welcome, pageSheet, can cancel.
        case management
    }

    let mode: Mode

    // MARK: - Callback

    /// Called after setup is complete and the VC has been dismissed
    var onComplete: (() -> Void)?

    // MARK: - Steps

    private enum Step {
        case welcome
        case picker
        case progress
    }

    private var currentStep: Step?

    // MARK: - Child VCs

    private lazy var welcomeVC = WelcomePageViewController()

    private lazy var pickerVC: PresetDictionaryPickerViewController = {
        let pickerMode: PresetDictionaryPickerViewController.Mode
        switch mode {
        case .firstInstall: pickerMode = .firstInstall
        case .management:   pickerMode = .management
        }
        return PresetDictionaryPickerViewController(mode: pickerMode)
    }()

    /// Wraps pickerVC in a UINavigationController for native nav bar support
    private lazy var pickerNavVC: UINavigationController = {
        let nav = UINavigationController(rootViewController: pickerVC)
        nav.navigationBar.prefersLargeTitles = false
        return nav
    }()

    private lazy var progressVC = ImportProgressViewController()

    // MARK: - Container

    private let containerView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Init

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        setupCallbacks()

        // Show initial step
        switch mode {
        case .firstInstall:
            showStep(.welcome, animated: false)
        case .management:
            showStep(.picker, animated: false)
        }
    }

    // MARK: - Callback Wiring

    private func setupCallbacks() {
        // Welcome → Picker
        welcomeVC.onGetStarted = { [weak self] in
            self?.showStep(.picker, animated: true)
        }

        // Picker → Progress (or cancel in management mode)
        pickerVC.onContinue = { [weak self] selectedPresets in
            guard let self else { return }
            self.showStep(.progress, animated: true)
            // Delay startImporting until the progress VC's view is loaded
            DispatchQueue.main.async {
                self.progressVC.startImporting(selectedPresets)
            }
        }

        pickerVC.onCancel = { [weak self] in
            self?.dismiss(animated: true)
        }

        // Progress → Done
        progressVC.onDone = { [weak self] in
            self?.completeSetup()
        }
    }

    // MARK: - Step Transitions

    private func showStep(_ step: Step, animated: Bool) {
        let newVC = viewController(for: step)
        let oldVC = children.first

        oldVC?.willMove(toParent: nil)
        addChild(newVC)

        newVC.view.frame = containerView.bounds
        newVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if animated, let oldVC = oldVC {
            // Slide left animation
            newVC.view.frame.origin.x = containerView.bounds.width
            containerView.addSubview(newVC.view)

            UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseInOut) {
                oldVC.view.frame.origin.x = -self.containerView.bounds.width
                newVC.view.frame.origin.x = 0
            } completion: { _ in
                oldVC.view.removeFromSuperview()
                oldVC.removeFromParent()
                newVC.didMove(toParent: self)
            }
        } else {
            containerView.addSubview(newVC.view)
            oldVC?.view.removeFromSuperview()
            oldVC?.removeFromParent()
            newVC.didMove(toParent: self)
        }

        currentStep = step
    }

    private func viewController(for step: Step) -> UIViewController {
        switch step {
        case .welcome:  return welcomeVC
        case .picker:   return pickerNavVC
        case .progress: return progressVC
        }
    }

    // MARK: - Completion

    private func completeSetup() {
        // Dictionaries are already loaded into DictionaryService.shared by the
        // piggybacked refreshAfterImport() calls in ImportProgressViewController.
        // Just dismiss and let the caller refresh its UI.
        dismiss(animated: true) { [weak self] in
            self?.onComplete?()
        }
    }
}
