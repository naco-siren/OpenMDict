//
//  DictResourceEditorViewController.swift
//  OpenMDict-iOS
//
//  Third column in Management mode - edit dictionary resources (CSS, fonts, etc.)
//  Currently a placeholder/stub.
//

import UIKit
import OpenMDictKit

class DictResourceEditorViewController: UIViewController {
    
    // MARK: - State
    
    private var currentDictId: String?
    
    /// Mode of the editor
    enum Mode {
        case empty           // No dictionary selected (import flow)
        case editing(dictId: String)  // Editing a specific dictionary's resources
    }
    
    private var mode: Mode = .empty {
        didSet { updateUI() }
    }
    
    // MARK: - UI
    
    private lazy var placeholderStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    
    private lazy var iconImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .thin)
        let image = UIImage(systemName: "doc.badge.gearshape", withConfiguration: config)
        let iv = UIImageView(image: image)
        iv.tintColor = .tertiaryLabel
        iv.contentMode = .scaleAspectFit
        return iv
    }()
    
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .title2)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupUI()
        updateUI()
    }
    
    // MARK: - Setup
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        placeholderStack.addArrangedSubview(iconImageView)
        placeholderStack.addArrangedSubview(titleLabel)
        placeholderStack.addArrangedSubview(subtitleLabel)
        
        // Add some spacing after icon
        placeholderStack.setCustomSpacing(24, after: iconImageView)
        
        view.addSubview(placeholderStack)
        NSLayoutConstraint.activate([
            placeholderStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            placeholderStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            placeholderStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
    
    private func updateUI() {
        switch mode {
        case .empty:
            titleLabel.text = "No Dictionary Selected"
            subtitleLabel.text = "Import or select a dictionary to edit its resources"
            
        case .editing(let dictId):
            currentDictId = dictId
            
            // Get dictionary name
            let dictName = DictionaryService.shared.dict(id: dictId)?.metadata?.title ?? "Dictionary"
            
            titleLabel.text = "Resource Editor"
            subtitleLabel.text = "Edit CSS, fonts, and other resources for \(dictName)\n\n(Coming Soon)"
        }
    }
    
    // MARK: - Public API
    
    /// Show empty state (for import flow)
    func showEmptyState() {
        mode = .empty
    }
    
    /// Show editor for a specific dictionary
    func showEditor(for dictId: String) {
        mode = .editing(dictId: dictId)
    }
}
