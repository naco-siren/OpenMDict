//
//  iCloudTroubleshootingViewController.swift
//  OpenMDict-iOS
//
//  iCloud troubleshooting screen: status overview, cloud data counts,
//  and a danger zone with reset actions.
//
//  Visible to ALL users (iCloud and offline).  When iCloud is disabled,
//  the cloud data section is hidden and the danger zone offers local-only
//  reset instead of the iCloud nuclear reset.
//
//  Presented as a modal (formSheet / pageSheet) from both regular and
//  compact layouts.  Dismissible by tapping outside.
//

import CoreData
import UIKit

final class iCloudTroubleshootingViewController: UIViewController {

    /// Called after a successful reset (cloud or local).
    var onResetComplete: (() -> Void)?

    // MARK: - Data Source

    private nonisolated enum Section: Hashable, Sendable {
        case status
        case cloudData
        case dangerZone
    }

    private nonisolated enum Item: Hashable, Sendable {
        case syncStatus
        case dictCount
        case groupCount
        case bookmarkCount
        case historyCount
        case clearAllCloudData
        case clearAllLocalData
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
        config.footerMode = .supplementary
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
            case .syncStatus:
                config.image = UIImage(systemName: enabled ? "person.icloud.fill" : "icloud.slash")
                config.imageProperties.tintColor = enabled ? .systemBlue : .secondaryLabel
                config.text = L10n.Troubleshoot.syncStatusTitle
                config.secondaryText = enabled
                    ? L10n.Troubleshoot.syncStatusSubtitleEnabled
                    : L10n.Troubleshoot.syncStatusSubtitleDisabled
                config.secondaryTextProperties.numberOfLines = 0

                let toggle = UISwitch()
                toggle.isOn = enabled
                toggle.isUserInteractionEnabled = false
                cell.accessories = [.customView(configuration: .init(
                    customView: toggle,
                    placement: .trailing(displayed: .always)
                ))]

            case .dictCount:
                config.image = UIImage(systemName: "books.vertical")
                config.text = L10n.Troubleshoot.dictCount(self.dictionaryCount)

            case .groupCount:
                config.image = UIImage(systemName: "folder")
                config.text = L10n.Troubleshoot.groupCount(self.groupCount)

            case .bookmarkCount:
                config.image = UIImage(systemName: "bookmark")
                config.text = L10n.Troubleshoot.bookmarkCountLabel(self.bookmarkCount)

            case .historyCount:
                config.image = UIImage(systemName: "clock.arrow.circlepath")
                config.text = L10n.Troubleshoot.historyCount(self.historyCount)

            case .clearAllCloudData:
                config.text = L10n.Troubleshoot.clearCloudTitle
                config.textProperties.color = .systemRed
                config.secondaryText = L10n.Troubleshoot.clearCloudDescription
                config.secondaryTextProperties.numberOfLines = 0
                config.image = UIImage(systemName: "exclamationmark.icloud.fill")
                config.imageProperties.tintColor = .systemRed

            case .clearAllLocalData:
                config.text = L10n.Troubleshoot.clearLocalTitle
                config.textProperties.color = .systemRed
                config.secondaryText = L10n.Troubleshoot.clearLocalDescription
                config.secondaryTextProperties.numberOfLines = 0
                config.image = UIImage(systemName: "exclamationmark.triangle.fill")
                config.imageProperties.tintColor = .systemRed
            }

            cell.contentConfiguration = config
            if item != .syncStatus {
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
            case .status:     config.text = L10n.Troubleshoot.sectionStatus
            case .cloudData:  config.text = L10n.Troubleshoot.sectionCloudData
            case .dangerZone: config.text = L10n.Troubleshoot.dangerZone
            case .none:       break
            }
            header.contentConfiguration = config
        }

        let footerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] (footer, _, indexPath) in
            guard let self else { return }
            var config = footer.defaultContentConfiguration()
            let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            let enabled = self.isCloudEnabled
            switch section {
            case .status:
                config.text = enabled
                    ? L10n.Troubleshoot.statusFooterEnabled
                    : L10n.Troubleshoot.statusFooterDisabled
            case .dangerZone:
                config.text = enabled
                    ? L10n.Troubleshoot.dangerZoneFooterCloud
                    : L10n.Troubleshoot.dangerZoneFooterLocal
            default:
                break
            }
            config.textProperties.font = .preferredFont(forTextStyle: .footnote)
            config.textProperties.color = .secondaryLabel
            config.textProperties.numberOfLines = 0
            footer.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: cellReg, for: indexPath, item: item
            )
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            switch kind {
            case UICollectionView.elementKindSectionHeader:
                return collectionView.dequeueConfiguredReusableSupplementary(
                    using: headerReg, for: indexPath
                )
            default:
                return collectionView.dequeueConfiguredReusableSupplementary(
                    using: footerReg, for: indexPath
                )
            }
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        snapshot.appendSections([.status])
        snapshot.appendItems([.syncStatus], toSection: .status)

        if isCloudEnabled {
            snapshot.appendSections([.cloudData])
            snapshot.appendItems(
                [.dictCount, .groupCount, .bookmarkCount, .historyCount],
                toSection: .cloudData
            )
        }

        snapshot.appendSections([.dangerZone])
        snapshot.appendItems(
            [isCloudEnabled ? .clearAllCloudData : .clearAllLocalData],
            toSection: .dangerZone
        )

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Reset Flow (shared two-alert pattern)

    /// Present the two-alert confirmation flow.
    /// Alert 1: [Proceed (red, left)] [Cancel (bold, right)]
    /// Alert 2: [Abort (bold, left)] [Confirm (red, right)]
    private func beginReset(
        alert1Title: String, alert1Message: String,
        alert2Title: String, alert2Message: String,
        execute: @escaping () -> Void
    ) {
        let alert1 = UIAlertController(
            title: alert1Title, message: alert1Message, preferredStyle: .alert
        )
        alert1.addAction(UIAlertAction(
            title: L10n.Troubleshoot.confirm1Proceed, style: .destructive
        ) { _ in
            let alert2 = UIAlertController(
                title: alert2Title, message: alert2Message, preferredStyle: .alert
            )
            let abort = UIAlertAction(
                title: L10n.Troubleshoot.confirm2Abort, style: .default
            )
            alert2.addAction(abort)
            alert2.addAction(UIAlertAction(
                title: L10n.Troubleshoot.confirm2Confirm, style: .destructive
            ) { _ in execute() })
            alert2.preferredAction = abort
            self.present(alert2, animated: true)
        })
        let cancel = UIAlertAction(title: L10n.cancel, style: .default)
        alert1.addAction(cancel)
        alert1.preferredAction = cancel
        present(alert1, animated: true)
    }

    // MARK: - iCloud Nuclear Reset

    private func beginCloudReset() {
        beginReset(
            alert1Title: L10n.Troubleshoot.confirm1Title,
            alert1Message: L10n.Troubleshoot.confirm1Message,
            alert2Title: L10n.Troubleshoot.confirm2Title,
            alert2Message: L10n.Troubleshoot.confirm2Message
        ) { [weak self] in
            self?.executeCloudReset()
        }
    }

    private func executeCloudReset() {
        showProgressAndRun { onProgress in
            await iCloudResetOrchestrator.shared.performClearAll(onProgress: onProgress)
        }
    }

    // MARK: - Local-Only Reset

    private func beginLocalReset() {
        beginReset(
            alert1Title: L10n.Troubleshoot.localConfirm1Title,
            alert1Message: L10n.Troubleshoot.localConfirm1Message,
            alert2Title: L10n.Troubleshoot.localConfirm2Title,
            alert2Message: L10n.Troubleshoot.localConfirm2Message
        ) { [weak self] in
            self?.executeLocalReset()
        }
    }

    private func executeLocalReset() {
        showProgressAndRun { onProgress in
            await iCloudResetOrchestrator.shared.performLocalClearAll(onProgress: onProgress)
        }
    }

    // MARK: - Shared Progress UI

    private func showProgressAndRun(
        _ work: @escaping (@escaping (iCloudResetOrchestrator.Progress) -> Void) async -> Void
    ) {
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
            await work { [weak progressAlert] progress in
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
        return item == .clearAllCloudData || item == .clearAllLocalData
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .clearAllCloudData: beginCloudReset()
        case .clearAllLocalData: beginLocalReset()
        default: break
        }
    }
}
