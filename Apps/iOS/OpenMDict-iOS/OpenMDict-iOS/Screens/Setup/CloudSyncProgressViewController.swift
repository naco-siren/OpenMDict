//
//  CloudSyncProgressViewController.swift
//  OpenMDict-iOS
//
//  Blocking progress screen shown during first-launch iCloud restore.
//
//  Phases:
//    1. Wait for CoreData metadata to sync from CloudKit (via CloudKitSyncMonitor).
//    2. If dictionaries exist, download their files via DictionaryFileSyncService.
//    3. Fire `onComplete` — the caller decides whether to go to main UI or picker.
//
//  UI: centered cloud icon + indeterminate spinner + status label.
//

import Combine
import UIKit

final class CloudSyncProgressViewController: UIViewController {

    // MARK: - Callbacks

    /// Fired when the initial sync phase is finished (metadata loaded,
    /// files downloaded where possible).  The caller inspects
    /// `DictMetadataService.shared.hasAnyDictionaries` to decide next step.
    var onComplete: (() -> Void)?

    // MARK: - UI

    private let cloudImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .thin)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        let image = UIImage(systemName: "icloud.and.arrow.down", withConfiguration: config)
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .large)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.hidesWhenStopped = false
        s.startAnimating()
        return s
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.SyncProgress.syncingData
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let detailLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - State

    private let syncMonitor = CloudKitSyncMonitor()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSync()
    }

    // MARK: - Layout

    private func setupLayout() {
        let stack = UIStackView(arrangedSubviews: [
            cloudImageView, spinner, statusLabel, detailLabel
        ])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    // MARK: - Sync Flow

    private func startSync() {
        statusLabel.text = L10n.SyncProgress.syncingData
        detailLabel.text = nil

        // Phase 1: wait for metadata to arrive via CloudKit
        syncMonitor.onInitialImportComplete = { [weak self] in
            self?.handleMetadataSynced()
        }
        syncMonitor.start()
    }

    /// Called when CloudKitSyncMonitor determines metadata import is done.
    private func handleMetadataSynced() {
        let allMetadata = DictMetadataService.shared.loadAll()

        if allMetadata.isEmpty {
            // No dictionaries in iCloud — finish immediately.
            debugLog("☁️ CloudSyncProgress: no metadata from iCloud — completing")
            finish()
            return
        }

        // Phase 2: download dictionary files
        statusLabel.text = L10n.SyncProgress.downloadingDictionaries
        detailLabel.text = nil

        Task {
            var downloaded = 0
            let total = allMetadata.count

            for metadata in allMetadata {
                downloaded += 1
                detailLabel.text = "\(downloaded) / \(total)"

                let dictDir = DictionaryStorageService.shared.dictionaryDirectoryURL(id: metadata.dictId)
                if FileManager.default.fileExists(atPath: dictDir.path) {
                    // Already present — skip
                    continue
                }

                // Download from CloudKit
                let success = await DictionaryFileSyncService.shared.downloadDictionary(
                    dictId: metadata.dictId
                )
                if success {
                    debugLog("☁️ CloudSyncProgress: downloaded \(metadata.dictId.prefix(16))")
                } else {
                    debugLog("☁️ CloudSyncProgress: failed to download \(metadata.dictId.prefix(16)) — skipping")
                }
            }

            finish()
        }
    }

    private func finish() {
        syncMonitor.stop()
        statusLabel.text = L10n.SyncProgress.almostDone
        spinner.stopAnimating()

        // Small delay for visual feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.onComplete?()
        }
    }
}
