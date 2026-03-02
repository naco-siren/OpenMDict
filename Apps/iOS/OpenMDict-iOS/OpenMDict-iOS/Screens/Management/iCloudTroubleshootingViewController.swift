//
//  iCloudTroubleshootingViewController.swift
//  OpenMDict-iOS
//
//  iCloud troubleshooting screen with the nuclear reset button.
//  Accessible from the Management section when iCloud sync is enabled.
//
//  MVP: only Tier 3 ("Clear All iCloud Data") is implemented.
//  Tier 1 (re-download) and Tier 2 (disconnect) are deferred.
//

import UIKit

final class iCloudTroubleshootingViewController: UIViewController {

    /// Called after a successful nuclear reset.  The parent is responsible for
    /// destroying extra scenes and replacing `window.rootViewController`.
    var onResetComplete: (() -> Void)?

    // MARK: - Data Source

    private nonisolated enum Section: Hashable, Sendable {
        case nuclear
    }

    private nonisolated enum Item: Hashable, Sendable {
        case clearAllCloudData
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var collectionView: UICollectionView!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Troubleshoot.title
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never

        configureCollectionView()
        configureDataSource()
        applySnapshot()
    }

    // MARK: - Collection View

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            (cell: UICollectionViewListCell, _: IndexPath, item: Item) in

            var config = cell.defaultContentConfiguration()
            switch item {
            case .clearAllCloudData:
                config.text = L10n.Troubleshoot.clearCloudTitle
                config.textProperties.color = .systemRed
                config.secondaryText = L10n.Troubleshoot.clearCloudDescription
                config.secondaryTextProperties.numberOfLines = 0
                config.image = UIImage(systemName: "exclamationmark.icloud")
                config.imageProperties.tintColor = .systemRed
            }
            cell.contentConfiguration = config
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { (header, _, indexPath) in
            var config = header.defaultContentConfiguration()
            config.text = L10n.Troubleshoot.dangerZone
            header.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: cellReg, for: indexPath, item: item
            )
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerReg, for: indexPath
            )
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.nuclear])
        snapshot.appendItems([.clearAllCloudData], toSection: .nuclear)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Nuclear Reset Flow

    private func beginNuclearReset() {
        // Step 1: First confirmation — explain impact
        let alert1 = UIAlertController(
            title: L10n.Troubleshoot.clearCloudConfirmTitle,
            message: L10n.Troubleshoot.clearCloudConfirmMessage,
            preferredStyle: .alert
        )
        alert1.addAction(UIAlertAction(
            title: L10n.Troubleshoot.continueButton,
            style: .destructive
        ) { [weak self] _ in
            self?.showDeleteConfirmation()
        })
        alert1.addAction(UIAlertAction(title: L10n.Troubleshoot.cancel, style: .cancel))
        present(alert1, animated: true)
    }

    /// Step 2: Type "DELETE" to confirm
    private func showDeleteConfirmation() {
        let alert2 = UIAlertController(
            title: L10n.Troubleshoot.typeDeleteTitle,
            message: L10n.Troubleshoot.typeDeleteMessage,
            preferredStyle: .alert
        )
        alert2.addTextField { textField in
            textField.placeholder = "DELETE"
            textField.autocapitalizationType = .allCharacters
            textField.autocorrectionType = .no
        }

        let confirmAction = UIAlertAction(
            title: L10n.Troubleshoot.clearCloudButton,
            style: .destructive
        ) { [weak self] _ in
            guard let text = alert2.textFields?.first?.text,
                  text.uppercased() == "DELETE" else {
                return
            }
            self?.executeNuclearReset()
        }
        alert2.addAction(confirmAction)
        alert2.addAction(UIAlertAction(title: L10n.Troubleshoot.cancel, style: .cancel))
        present(alert2, animated: true)
    }

    /// Step 3: Show progress and execute
    private func executeNuclearReset() {
        // Non-dismissible progress alert
        let progressAlert = UIAlertController(
            title: L10n.Troubleshoot.resettingTitle,
            message: L10n.Troubleshoot.starting,
            preferredStyle: .alert
        )
        // Add a spinner
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        progressAlert.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerYAnchor.constraint(equalTo: progressAlert.view.bottomAnchor, constant: -45),
            spinner.trailingAnchor.constraint(equalTo: progressAlert.view.trailingAnchor, constant: -20),
        ])

        present(progressAlert, animated: true)

        Task {
            var resetError: Error?
            await iCloudResetOrchestrator.shared.performClearAll { [weak progressAlert] progress in
                switch progress {
                case .starting:
                    progressAlert?.message = L10n.Troubleshoot.starting
                case .deletingCloudData:
                    progressAlert?.message = L10n.Troubleshoot.deletingCloudData
                case .deletingLocalData:
                    progressAlert?.message = L10n.Troubleshoot.deletingLocalData
                case .recreatingDatabase:
                    progressAlert?.message = L10n.Troubleshoot.recreatingDatabase
                case .complete:
                    break
                case .failed(let error):
                    resetError = error
                }
            }

            // Dismiss progress alert, then handle result
            progressAlert.dismiss(animated: true) { [weak self] in
                if resetError != nil {
                    self?.showResetFailedAlert()
                } else {
                    self?.onResetComplete?()
                }
            }
        }
    }
    private func showResetFailedAlert() {
        let alert = UIAlertController(
            title: L10n.Troubleshoot.resetFailed,
            message: L10n.Troubleshoot.resetFailedMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UICollectionViewDelegate

extension iCloudTroubleshootingViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .clearAllCloudData:
            beginNuclearReset()
        }
    }
}
