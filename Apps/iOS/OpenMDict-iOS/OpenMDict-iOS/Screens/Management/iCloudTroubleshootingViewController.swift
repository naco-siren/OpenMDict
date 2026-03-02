//
//  iCloudTroubleshootingViewController.swift
//  OpenMDict-iOS
//
//  iCloud troubleshooting screen: status overview, cloud data counts,
//  and a nuclear reset button in the Danger Zone.
//
//  Presented as a modal (formSheet / pageSheet) from both regular and
//  compact layouts.  Dismissible by tapping outside.
//

import CoreData
import UIKit

final class iCloudTroubleshootingViewController: UIViewController {

    /// Called after a successful nuclear reset.  The parent is responsible for
    /// destroying extra scenes and replacing `window.rootViewController`.
    var onResetComplete: (() -> Void)?

    // MARK: - Data Source

    private nonisolated enum Section: Hashable, Sendable {
        case status
        case cloudData
        case dangerZone
    }

    private nonisolated enum Item: Hashable, Sendable {
        case iCloudToggle
        case dictCount
        case groupCount
        case bookmarkCount
        case historyCount
        case clearAllCloudData
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var collectionView: UICollectionView!

    // MARK: - State

    private var isCloudEnabled: Bool {
        SyncModeService.shared.isCloudSyncEnabled
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Troubleshoot.title
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never

        // Dismiss button (leading, just like Download Presets modal)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(dismissSelf)
        )

        configureCollectionView()
        configureDataSource()
        applySnapshot()
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    // MARK: - Cloud Data Counts

    private func countRecords<T: NSManagedObject>(ofType _: T.Type) -> Int {
        let ctx = CoreDataStack.shared.viewContext
        let request = T.fetchRequest()
        request.resultType = .countResultType
        return (try? ctx.count(for: request)) ?? 0
    }

    private var dictionaryCount: Int { countRecords(ofType: DictionaryMetadataRecord.self) }
    private var groupCount: Int { countRecords(ofType: DictionaryGroupRecord.self) }
    private var bookmarkCount: Int { countRecords(ofType: BookmarkRecord.self) }
    private var historyCount: Int { countRecords(ofType: LookupRecord.self) }

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
            [weak self] (cell, _, item) in
            guard let self else { return }

            var config = cell.defaultContentConfiguration()
            let enabled = self.isCloudEnabled

            switch item {
            case .iCloudToggle:
                config.image = UIImage(systemName: enabled ? "person.icloud.fill" : "icloud.slash")
                config.imageProperties.tintColor = enabled ? .systemBlue : .secondaryLabel
                config.text = enabled
                    ? L10n.Troubleshoot.statusEnabled
                    : L10n.Troubleshoot.statusDisabled

                let toggle = UISwitch()
                toggle.isOn = enabled
                toggle.isUserInteractionEnabled = false
                cell.accessories = [.customView(configuration: .init(
                    customView: toggle,
                    placement: .trailing(displayed: .always)
                ))]

            case .dictCount:
                config.image = UIImage(systemName: "books.vertical")
                let count = enabled ? self.dictionaryCount : 0
                config.text = L10n.Troubleshoot.dictCount(count)
                if !enabled { applyDisabledStyle(&config) }

            case .groupCount:
                config.image = UIImage(systemName: "folder")
                let count = enabled ? self.groupCount : 0
                config.text = L10n.Troubleshoot.groupCount(count)
                if !enabled { applyDisabledStyle(&config) }

            case .bookmarkCount:
                config.image = UIImage(systemName: "bookmark")
                let count = enabled ? self.bookmarkCount : 0
                config.text = L10n.Troubleshoot.bookmarkCountLabel(count)
                if !enabled { applyDisabledStyle(&config) }

            case .historyCount:
                config.image = UIImage(systemName: "clock.arrow.circlepath")
                let count = enabled ? self.historyCount : 0
                config.text = L10n.Troubleshoot.historyCount(count)
                if !enabled { applyDisabledStyle(&config) }

            case .clearAllCloudData:
                config.text = L10n.Troubleshoot.clearCloudTitle
                config.secondaryText = L10n.Troubleshoot.clearCloudDescription
                config.secondaryTextProperties.numberOfLines = 0
                config.image = UIImage(systemName: "exclamationmark.icloud.fill")
                if enabled {
                    config.textProperties.color = .systemRed
                    config.imageProperties.tintColor = .systemRed
                } else {
                    applyDisabledStyle(&config)
                }
            }

            cell.contentConfiguration = config
            // Remove accessories for non-toggle items
            if item != .iCloudToggle {
                cell.accessories = []
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] (header, _, indexPath) in
            guard let self else { return }
            var config = header.defaultContentConfiguration()
            let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            switch section {
            case .status:
                config.text = L10n.Troubleshoot.sectionStatus
            case .cloudData:
                config.text = L10n.Troubleshoot.sectionCloudData
            case .dangerZone:
                config.text = L10n.Troubleshoot.dangerZone
            case .none:
                break
            }
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

    private func applyDisabledStyle(_ config: inout UIListContentConfiguration) {
        config.textProperties.color = .tertiaryLabel
        config.imageProperties.tintColor = .tertiaryLabel
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        snapshot.appendSections([.status])
        snapshot.appendItems([.iCloudToggle], toSection: .status)

        snapshot.appendSections([.cloudData])
        snapshot.appendItems(
            [.dictCount, .groupCount, .bookmarkCount, .historyCount],
            toSection: .cloudData
        )

        snapshot.appendSections([.dangerZone])
        snapshot.appendItems([.clearAllCloudData], toSection: .dangerZone)

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Nuclear Reset Flow

    private func beginNuclearReset() {
        guard isCloudEnabled else { return }

        // Alert 1: Explain impact.
        // Visual order: [Proceed (red, left)] [Cancel (bold blue, right)]
        // .cancel style is NOT used — it forces left position on iOS.
        // Instead: .destructive first, .default second, preferredAction = cancel.
        let alert1 = UIAlertController(
            title: L10n.Troubleshoot.confirm1Title,
            message: L10n.Troubleshoot.confirm1Message,
            preferredStyle: .alert
        )
        alert1.addAction(UIAlertAction(
            title: L10n.Troubleshoot.confirm1Proceed,
            style: .destructive
        ) { [weak self] _ in
            self?.showFinalConfirmation()
        })
        let cancel1 = UIAlertAction(
            title: L10n.cancel,
            style: .default
        )
        alert1.addAction(cancel1)
        alert1.preferredAction = cancel1  // bold → "safe" choice
        present(alert1, animated: true)
    }

    /// Alert 2: Final confirmation with SWAPPED button positions.
    /// Visual order: [Abort (bold blue, left)] [Confirm (red, right)]
    /// The destructive button moved from left to right, forcing the user
    /// to read the button text instead of muscle-memory double-tapping.
    private func showFinalConfirmation() {
        let alert2 = UIAlertController(
            title: L10n.Troubleshoot.confirm2Title,
            message: L10n.Troubleshoot.confirm2Message,
            preferredStyle: .alert
        )
        let abort = UIAlertAction(
            title: L10n.Troubleshoot.confirm2Abort,
            style: .default
        )
        alert2.addAction(abort)
        alert2.addAction(UIAlertAction(
            title: L10n.Troubleshoot.confirm2Confirm,
            style: .destructive
        ) { [weak self] _ in
            self?.executeNuclearReset()
        })
        alert2.preferredAction = abort  // bold → "safe" choice
        present(alert2, animated: true)
    }

    /// Show progress and execute the reset.
    private func executeNuclearReset() {
        let progressAlert = UIAlertController(
            title: L10n.Troubleshoot.resettingTitle,
            message: L10n.Troubleshoot.starting,
            preferredStyle: .alert
        )
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        progressAlert.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerYAnchor.constraint(
                equalTo: progressAlert.view.bottomAnchor, constant: -45
            ),
            spinner.trailingAnchor.constraint(
                equalTo: progressAlert.view.trailingAnchor, constant: -20
            ),
        ])

        present(progressAlert, animated: true)

        Task {
            var resetError: Error?
            await iCloudResetOrchestrator.shared.performClearAll {
                [weak progressAlert] progress in
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
        shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        // Only the nuclear button is tappable, and only when iCloud is on
        return item == .clearAllCloudData && isCloudEnabled
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .clearAllCloudData:
            beginNuclearReset()
        default:
            break
        }
    }
}
