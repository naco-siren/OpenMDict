//
//  LoadingViewController.swift
//  OpenMDict-iOS
//
//  A simple non-dismissable loading modal for long-running operations.
//

import UIKit

final class LoadingViewController: UIViewController {
    
    // MARK: - UI
    
    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 16
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let spinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }()
    
    private let messageLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    // MARK: - Configuration
    
    var message: String = "Loading..." {
        didSet {
            messageLabel.text = message
        }
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        spinner.startAnimating()
    }
    
    // MARK: - Setup
    
    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        
        view.addSubview(containerView)
        containerView.addSubview(spinner)
        containerView.addSubview(messageLabel)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            containerView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            
            spinner.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 32),
            spinner.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            
            messageLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            messageLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -24),
            messageLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -24),
        ])
        
        messageLabel.text = message
    }
}

// MARK: - Convenience Presentation

extension UIViewController {
    
    /// Show a non-dismissable loading modal
    func showLoadingModal(message: String = "Loading...") -> LoadingViewController {
        let loadingVC = LoadingViewController()
        loadingVC.message = message
        loadingVC.modalPresentationStyle = .overFullScreen
        loadingVC.modalTransitionStyle = .crossDissolve
        present(loadingVC, animated: true)
        return loadingVC
    }
    
    /// Hide the loading modal
    func hideLoadingModal(_ loadingVC: LoadingViewController?, completion: (() -> Void)? = nil) {
        loadingVC?.dismiss(animated: true, completion: completion)
    }
}
