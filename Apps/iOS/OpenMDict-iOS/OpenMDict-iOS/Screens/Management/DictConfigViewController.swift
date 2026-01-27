//
//  DictConfigViewController.swift
//  OpenMDict-iOS
//
//  Secondary column for Management Mode.
//  Shows dictionary configuration (Edit mode) or import form (Import mode).
//
//  Three states:
//  - Empty: No dictionary selected, shows placeholder
//  - Import: New dictionary import form
//  - Edit: Existing dictionary configuration
//

import UIKit
import OpenMDictKit

/// Current state of the config view
enum DictConfigState: Equatable {
    case empty
    case importing
    case editing(dictionaryId: String)
}

class DictConfigViewController: UIViewController {
    
    // MARK: - Callbacks (matching MainSplitViewController expectations)
    
    /// Called when user dismisses/cancels the config view
    var onDismiss: (() -> Void)?
    
    /// Called when import completes successfully
    var onImportComplete: ((String) -> Void)?  // dictionaryId
    
    /// Called when delete completes successfully
    var onDeleteComplete: ((String) -> Void)?  // dictionaryId
    
    // MARK: - State
    
    private(set) var currentState: DictConfigState = .empty {
        didSet {
            if isViewLoaded {
                updateUI()
            }
        }
    }
    
    /// Current entry being edited (for edit mode)
    private var currentEntry: DictionaryManifest.DictionaryEntry?
    
    // MARK: - UI
    
    private lazy var emptyStateView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        
        let imageView = UIImageView(image: UIImage(systemName: "books.vertical"))
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = .init(pointSize: 60)
        
        let label = UILabel()
        label.text = "Select a dictionary to edit\nor tap + to import new ones"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        
        let button = UIButton(type: .system)
        button.setTitle("Import Dictionary", for: .normal)
        button.setImage(UIImage(systemName: "plus"), for: .normal)
        button.addTarget(self, action: #selector(importButtonTapped), for: .touchUpInside)
        
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        
        return view
    }()
    
    private lazy var formView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        // TODO: Implement actual form UI with UICollectionView
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Import/Edit Form\n(Coming Soon)"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        
        return view
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemGroupedBackground
        
        view.addSubview(emptyStateView)
        view.addSubview(formView)
        
        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            formView.topAnchor.constraint(equalTo: view.topAnchor),
            formView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        updateUI()
    }
    
    // MARK: - UI Updates
    
    private func updateUI() {
        switch currentState {
        case .empty:
            title = "Dictionary"
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItem = nil
            emptyStateView.isHidden = false
            formView.isHidden = true
            
        case .importing:
            title = "Import Dictionary"
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(cancelTapped)
            )
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(doneTapped)
            )
            navigationItem.rightBarButtonItem?.isEnabled = false  // Enable when form is valid
            emptyStateView.isHidden = true
            formView.isHidden = false
            
        case .editing(let dictId):
            let dict = DictionaryService.shared.dict(id: dictId)
            title = dict?.metadata?.title ?? "Edit Dictionary"
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(cancelTapped)
            )
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(doneTapped)
            )
            emptyStateView.isHidden = true
            formView.isHidden = false
        }
    }
    
    // MARK: - Actions
    
    @objc private func importButtonTapped() {
        showImportMode()
    }
    
    @objc private func cancelTapped() {
        currentState = .empty
        currentEntry = nil
        onDismiss?()
    }
    
    @objc private func doneTapped() {
        switch currentState {
        case .importing:
            // TODO: Perform actual import with UIDocumentPicker
            // For now, just show placeholder
            print("📥 Import - TODO: Show document picker")
            
        case .editing(let dictId):
            // TODO: Save changes
            print("💾 Save changes for \(dictId) - TODO")
            
        case .empty:
            break
        }
    }
    
    // MARK: - Public API (matching MainSplitViewController expectations)
    
    /// Show empty state
    func showEmptyState() {
        currentState = .empty
        currentEntry = nil
    }
    
    /// Show import form
    func showImportMode() {
        currentState = .importing
        currentEntry = nil
    }
    
    /// Show edit form for existing dictionary
    func showEditMode(for entry: DictionaryManifest.DictionaryEntry?) {
        if let entry = entry {
            currentEntry = entry
            currentState = .editing(dictionaryId: entry.id)
        } else {
            // Bundled dictionary - show limited info
            currentState = .empty  // TODO: Show read-only info for bundled
        }
    }
}
