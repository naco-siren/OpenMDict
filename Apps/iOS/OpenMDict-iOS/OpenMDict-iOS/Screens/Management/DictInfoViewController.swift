//
//  DictInfoViewController.swift
//  OpenMDict-iOS
//
//  Dictionary configuration view controller.
//  Shows dictionary info form for Import or Edit mode.
//
//  Two modes:
//  - Import: Select MDX file, preview metadata, confirm import
//  - Edit: View/edit dictionary info, delete dictionary
//

import UIKit
import UniformTypeIdentifiers
import OpenMDictKit

// MARK: - State

enum DictConfigState: Equatable {
    case empty
    case importing
    case editing(dictionaryId: String)
}

// MARK: - View Controller

class DictInfoViewController: UIViewController {
    
    // MARK: - Callbacks
    
    var onDismiss: (() -> Void)?
    var onImportComplete: ((String) -> Void)?
    var onDeleteComplete: ((String) -> Void)?
    
    // MARK: - State
    
    private(set) var currentState: DictConfigState = .empty {
        didSet {
            if isViewLoaded {
                updateUI()
            }
        }
    }
    
    /// Selected MDX file URL (for import mode)
    private var selectedMDXURL: URL?
    
    /// Current dictionary ID (for edit mode)
    private var currentDictId: String?
    
    // MARK: - UI
    
    private enum Section: Int, CaseIterable {
        case fileSelection   // Import mode: "Select MDX File" button
        case metadata        // Title, description (from MDX header)
        case displayName     // Editable display name
        case actions         // Delete button (edit mode only)
    }
    
    private nonisolated enum Item: Hashable {
        case selectFile
        case metadataTitle(String)
        case metadataDescription(String)
        case displayNameField(String)
        case deleteButton
    }
    
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    
    private lazy var collectionView: UICollectionView = {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.delegate = self
        cv.backgroundColor = .systemGroupedBackground
        return cv
    }()
    
    private lazy var emptyStateView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        
        let imageView = UIImageView(image: UIImage(systemName: "doc.badge.plus"))
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = .init(pointSize: 60)
        
        let label = UILabel()
        label.text = "Select an MDX file to import\na new dictionary"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        
        let button = UIButton(type: .system)
        button.setTitle("Select MDX File", for: .normal)
        button.setImage(UIImage(systemName: "folder"), for: .normal)
        button.addTarget(self, action: #selector(selectFileTapped), for: .touchUpInside)
        
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
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemGroupedBackground
        
        view.addSubview(collectionView)
        view.addSubview(emptyStateView)
        
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        configureDataSource()
        updateUI()
    }
    
    // MARK: - Data Source
    
    private func configureDataSource() {
        // Select File Cell
        let selectFileReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Select MDX File"
            content.image = UIImage(systemName: "doc.badge.plus")
            content.imageProperties.tintColor = .systemBlue
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        
        // Metadata Cell (read-only)
        let metadataReg = UICollectionView.CellRegistration<UICollectionViewListCell, (String, String)> { cell, indexPath, tuple in
            let (label, value) = tuple
            var content = UIListContentConfiguration.valueCell()
            content.text = label
            content.secondaryText = value.isEmpty ? "—" : value
            content.secondaryTextProperties.color = value.isEmpty ? .tertiaryLabel : .label
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        // Display Name Cell (editable - TODO: make actually editable)
        let displayNameReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, indexPath, value in
            var content = UIListContentConfiguration.valueCell()
            content.text = "Display Name"
            content.secondaryText = value.isEmpty ? "Enter name..." : value
            content.secondaryTextProperties.color = value.isEmpty ? .placeholderText : .label
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        
        // Delete Button Cell
        let deleteReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, indexPath, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Delete Dictionary"
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessories = []
        }
        
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            
            switch item {
            case .selectFile:
                return collectionView.dequeueConfiguredReusableCell(using: selectFileReg, for: indexPath, item: ())
                
            case .metadataTitle(let value):
                return collectionView.dequeueConfiguredReusableCell(using: metadataReg, for: indexPath, item: ("Title", value))
                
            case .metadataDescription(let value):
                return collectionView.dequeueConfiguredReusableCell(using: metadataReg, for: indexPath, item: ("Description", value))
                
            case .displayNameField(let value):
                return collectionView.dequeueConfiguredReusableCell(using: displayNameReg, for: indexPath, item: value)
                
            case .deleteButton:
                return collectionView.dequeueConfiguredReusableCell(using: deleteReg, for: indexPath, item: ())
            }
        }
    }
    
    // MARK: - UI Updates
    
    private func updateUI() {
        switch currentState {
        case .empty:
            title = "Import Dictionary"
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(cancelTapped)
            )
            navigationItem.rightBarButtonItem = nil
            emptyStateView.isHidden = false
            collectionView.isHidden = true
            
        case .importing:
            title = "Import Dictionary"
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(cancelTapped)
            )
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Import",
                style: .done,
                target: self,
                action: #selector(importTapped)
            )
            navigationItem.rightBarButtonItem?.isEnabled = selectedMDXURL != nil
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            applyImportSnapshot()
            
        case .editing(let dictId):
            let dict = DictionaryService.shared.dict(id: dictId)
            title = dict?.metadata?.title ?? "Dictionary"
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(cancelTapped)
            )
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(saveTapped)
            )
            emptyStateView.isHidden = true
            collectionView.isHidden = false
            applyEditSnapshot(dictId: dictId)
        }
    }
    
    private func applyImportSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        // File selection section
        snapshot.appendSections([.fileSelection])
        snapshot.appendItems([.selectFile], toSection: .fileSelection)
        
        // If file selected, show metadata preview
        if selectedMDXURL != nil {
            snapshot.appendSections([.metadata, .displayName])
            // TODO: Read actual metadata from MDX file
            snapshot.appendItems([
                .metadataTitle("Preview Title"),
                .metadataDescription("Preview Description")
            ], toSection: .metadata)
            snapshot.appendItems([.displayNameField("")], toSection: .displayName)
        }
        
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    private func applyEditSnapshot(dictId: String) {
        guard let dict = DictionaryService.shared.dict(id: dictId) else { return }
        
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        
        // Metadata section
        snapshot.appendSections([.metadata])
        snapshot.appendItems([
            .metadataTitle(dict.metadata?.title ?? ""),
            .metadataDescription(dict.metadata?.description ?? "")
        ], toSection: .metadata)
        
        // Display name section
        snapshot.appendSections([.displayName])
        snapshot.appendItems([.displayNameField(dict.metadata?.title ?? "")], toSection: .displayName)
        
        // Delete section (only for user-imported dictionaries)
        // TODO: Check if dictionary is user-imported vs bundled
        snapshot.appendSections([.actions])
        snapshot.appendItems([.deleteButton], toSection: .actions)
        
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    // MARK: - Actions
    
    @objc private func selectFileTapped() {
        showDocumentPicker()
    }
    
    @objc private func cancelTapped() {
        selectedMDXURL = nil
        currentDictId = nil
        currentState = .empty
        onDismiss?()
    }
    
    @objc private func importTapped() {
        guard let url = selectedMDXURL else { return }
        
        // TODO: Perform actual import
        print("📥 Importing from: \(url.lastPathComponent)")
        
        // Simulate import completion
        let fakeDictId = UUID().uuidString
        selectedMDXURL = nil
        currentState = .empty
        onImportComplete?(fakeDictId)
    }
    
    @objc private func saveTapped() {
        guard case .editing(let dictId) = currentState else { return }
        
        // TODO: Save changes
        print("💾 Saving changes for: \(dictId)")
        
        currentDictId = nil
        currentState = .empty
        onDismiss?()
    }
    
    private func showDeleteConfirmation() {
        guard case .editing(let dictId) = currentState else { return }
        
        let dict = DictionaryService.shared.dict(id: dictId)
        let title = dict?.metadata?.title ?? "this dictionary"
        
        let alert = UIAlertController(
            title: "Delete Dictionary",
            message: "Are you sure you want to delete \"\(title)\"? This action cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.performDelete(dictId: dictId)
        })
        
        present(alert, animated: true)
    }
    
    private func performDelete(dictId: String) {
        // TODO: Perform actual delete
        print("🗑️ Deleting dictionary: \(dictId)")
        
        currentDictId = nil
        currentState = .empty
        onDeleteComplete?(dictId)
    }
    
    private func showDocumentPicker() {
        let mdxType = UTType(filenameExtension: "mdx") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [mdxType])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
    
    // MARK: - Public API
    
    func showEmptyState() {
        selectedMDXURL = nil
        currentDictId = nil
        currentState = .empty
    }
    
    func showImportMode() {
        selectedMDXURL = nil
        currentDictId = nil
        currentState = .empty  // Start with empty, showing file picker prompt
    }
    
    func showEditMode(for dictId: String) {
        selectedMDXURL = nil
        currentDictId = dictId
        currentState = .editing(dictionaryId: dictId)
    }
    
    // Legacy API compatibility
    func showEditMode(for entry: DictionaryManifest.DictionaryEntry?) {
        if let entry = entry {
            showEditMode(for: entry.id)
        } else {
            showEmptyState()
        }
    }
}

// MARK: - UICollectionViewDelegate

extension DictInfoViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item {
        case .selectFile:
            showDocumentPicker()
            
        case .displayNameField:
            // TODO: Show edit dialog or inline editing
            print("📝 Edit display name - TODO")
            
        case .deleteButton:
            showDeleteConfirmation()
            
        default:
            break
        }
    }
}

// MARK: - UIDocumentPickerDelegate

extension DictInfoViewController: UIDocumentPickerDelegate {
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        selectedMDXURL = url
        currentState = .importing
        
        print("📄 Selected: \(url.lastPathComponent)")
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Stay in current state
    }
}
