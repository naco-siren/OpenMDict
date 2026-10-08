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

import Combine
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
        /// DEBUG builds only: the HistoryExpired reproduction harness.
        case debug
    }

    private nonisolated enum Item: Hashable, Sendable {
        case syncStatus
        case lastSyncReset
        case dictCount
        case groupCount
        case bookmarkCount
        case historyCount
        case clearAllCloudData
        case clearAllLocalData
        case debugHistoryCount
        case debugExpireHistory
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var collectionView: UICollectionView!
    private var cancellables = Set<AnyCancellable>()

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

        // Refresh the "last sync reset" row if a mirroring reset happens
        // while this screen is open.
        CoreDataStack.shared.$mirroringStatusRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconfigureDynamicRows() }
            .store(in: &cancellables)
    }

    /// Re-render rows whose content is computed at display time.
    private func reconfigureDynamicRows() {
        var snapshot = dataSource.snapshot()
        let dynamic = snapshot.itemIdentifiers.filter {
            $0 == .lastSyncReset || $0 == .debugHistoryCount
        }
        guard !dynamic.isEmpty else { return }
        snapshot.reconfigureItems(dynamic)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Secondary text for the "last sync reset" row.
    private var lastSyncResetDescription: String {
        guard let reset = CoreDataStack.shared.lastMirroringReset else {
            return L10n.Troubleshoot.lastResetNever
        }
        let date = DateFormatter.localizedString(from: reset.date, dateStyle: .medium, timeStyle: .short)
        let reason: String
        switch reset.reason {
        case "historyExpired":     reason = L10n.Troubleshoot.lastResetReasonHistoryExpired
        case "changeTokenExpired": reason = L10n.Troubleshoot.lastResetReasonChangeTokenExpired
        case "zoneDeleted":        reason = L10n.Troubleshoot.lastResetReasonZoneDeleted
        default:                   reason = reset.reason
        }
        let count = CoreDataStack.shared.mirroringResetCount
        return count > 1 ? "\(date) · \(reason) · ×\(count)" : "\(date) · \(reason)"
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

            case .lastSyncReset:
                let hadReset = CoreDataStack.shared.lastMirroringReset != nil
                config.image = UIImage(systemName: hadReset ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud")
                config.imageProperties.tintColor = hadReset ? .systemOrange : .systemGreen
                config.text = L10n.Troubleshoot.lastResetTitle
                config.secondaryText = self.lastSyncResetDescription
                config.secondaryTextProperties.color = .secondaryLabel
                config.secondaryTextProperties.numberOfLines = 0

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
                config.secondaryTextProperties.color = .secondaryLabel
                config.secondaryTextProperties.numberOfLines = 0
                config.image = UIImage(systemName: "exclamationmark.icloud.fill")
                config.imageProperties.tintColor = .systemRed

            case .clearAllLocalData:
                config.text = L10n.Troubleshoot.clearLocalTitle
                config.textProperties.color = .systemRed
                config.secondaryText = L10n.Troubleshoot.clearLocalDescription
                config.secondaryTextProperties.color = .secondaryLabel
                config.secondaryTextProperties.numberOfLines = 0
                config.image = UIImage(systemName: "exclamationmark.triangle.fill")
                config.imageProperties.tintColor = .systemRed

            // DEBUG-only harness rows (plain literals: developer-facing, not localized)
            case .debugHistoryCount:
                config.image = UIImage(systemName: "clock.arrow.circlepath")
                config.imageProperties.tintColor = .secondaryLabel
                #if DEBUG
                config.text = "History transactions: \(CoreDataStack.shared.debugCloudStoreHistoryTransactionCount()) (cloud store)"
                #endif
                config.secondaryText = "Persistent-history rows the CloudKit exporter anchors on."
                config.secondaryTextProperties.color = .secondaryLabel
                config.secondaryTextProperties.numberOfLines = 0

            case .debugExpireHistory:
                config.text = "Expire persistent history (DEBUG)"
                config.textProperties.color = .systemRed
                config.secondaryText = "Deletes ALL cloud-store history. Force-quit and relaunch: the next export fails with 134301 and the mirroring delegate resets (HistoryExpired) — the 2026-10-08 incident on demand."
                config.secondaryTextProperties.color = .secondaryLabel
                config.secondaryTextProperties.numberOfLines = 0
                config.image = UIImage(systemName: "clock.badge.exclamationmark")
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
            case .debug:      config.text = "Debug (DEBUG build only)"
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
            if section == .dangerZone {
                config.text = L10n.Troubleshoot.dangerZoneFooter
            } else if section == .debug {
                config.text = "Test harness for the CloudKit HistoryExpired reset. Use only on a test iCloud account; afterwards the device re-imports its zone from iCloud."
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
        snapshot.appendItems(isCloudEnabled ? [.syncStatus, .lastSyncReset] : [.syncStatus],
                             toSection: .status)

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

        #if DEBUG
        if isCloudEnabled {
            snapshot.appendSections([.debug])
            snapshot.appendItems([.debugHistoryCount, .debugExpireHistory], toSection: .debug)
        }
        #endif

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

    // MARK: - DEBUG: HistoryExpired harness

    #if DEBUG
    private func beginDebugExpireHistory() {
        beginReset(
            alert1Title: "Expire persistent history?",
            alert1Message: "Deletes ALL persistent-history transactions of the CloudKit store on this device. The next CloudKit export will fail with error 134301 and the mirroring delegate will reset (HistoryExpired): every mirrored row is purged locally and the zone is re-imported from iCloud.\n\nOnly use on a test iCloud account.",
            alert2Title: "EXPIRE HISTORY NOW?",
            alert2Message: "Afterwards force-quit the app and relaunch it from Xcode (or toggle a bookmark) to trigger the export."
        ) { [weak self] in
            self?.executeDebugExpireHistory()
        }
    }

    private func executeDebugExpireHistory() {
        let ok = CoreDataStack.shared.debugExpireCloudStoreHistory()
        let alert = UIAlertController(
            title: ok ? "History expired" : "Expire failed",
            message: ok
                ? "Force-quit and relaunch (or make any change) to trigger the HistoryExpired reset. Watch the console for 134301."
                : "See the console for the error.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default) { [weak self] _ in
            self?.reconfigureDynamicRows()
        })
        present(alert, animated: true)
    }
    #endif

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
        return item == .syncStatus || item == .clearAllCloudData || item == .clearAllLocalData
            || item == .debugExpireHistory
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .syncStatus:       showSyncModeAlert()
        case .clearAllCloudData: beginCloudReset()
        case .clearAllLocalData: beginLocalReset()
        case .debugExpireHistory:
            #if DEBUG
            beginDebugExpireHistory()
            #endif
        default: break
        }
    }

    private func showSyncModeAlert() {
        let message = isCloudEnabled
            ? L10n.Troubleshoot.statusFooterEnabled
            : L10n.Troubleshoot.statusFooterDisabled
        let alert = UIAlertController(
            title: L10n.Troubleshoot.syncStatusTitle,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }
}
