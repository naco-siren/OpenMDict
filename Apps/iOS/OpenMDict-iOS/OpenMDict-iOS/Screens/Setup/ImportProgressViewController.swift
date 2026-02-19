//
//  ImportProgressViewController.swift
//  OpenMDict-iOS
//
//  Step 3 of the onboarding flow.
//  Shows per-dictionary import progress with real-time status updates.
//  Bundle assets import instantly; ODR assets show download progress.
//  Failed items can be retried individually by tapping the cell.
//

import UIKit

final class ImportProgressViewController: UIViewController {

    // MARK: - Callback

    var onDone: (() -> Void)?

    // MARK: - State

    /// Ordered list of presets being imported
    private var presets: [PresetDictionary] = []

    /// Per-preset import state
    private var importStates: [String: ImportItemState] = [:]

    private enum ImportItemState {
        case pending
        case importing(progress: Double)
        case completed
        case failed(message: String)

        /// Hashable-friendly snapshot key (state category + truncated info)
        var snapshotKey: String {
            switch self {
            case .pending: return "pending"
            case .importing(let p): return "importing:\(Int(p * 100))"
            case .completed: return "completed"
            case .failed(let m): return "failed:\(m.prefix(40))"
            }
        }
    }

    /// Whether all items have resolved (completed or failed)
    private var isAllDone: Bool {
        presets.allSatisfy { preset in
            switch importStates[preset.id] {
            case .completed, .failed: return true
            default: return false
            }
        }
    }

    // MARK: - UI: Header

    private let iconImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        let image = UIImage(systemName: "books.vertical", withConfiguration: config)
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 80),
            iv.heightAnchor.constraint(equalToConstant: 80),
        ])
        return iv
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private lazy var headerStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [iconImageView, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 32, left: 32, bottom: 16, right: 32)
        return stack
    }()

    // MARK: - UI: Collection View & Bottom

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    private let doneButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = L10n.Progress.importing
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        config.showsActivityIndicator = true
        config.imagePadding = 8
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = false
        return button
    }()

    private let bottomSeparator: UIView = {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        messageLabel.text = L10n.Progress.title

        setupCollectionView()
        setupLayout()
        configureDataSource()

        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
    }

    // MARK: - Public API

    /// Start importing the given presets. Called by SetupViewController after picker selection.
    func startImporting(_ presets: [PresetDictionary]) {
        self.presets = presets

        // Initialize all as pending
        for preset in presets {
            importStates[preset.id] = .pending
        }

        applySnapshot()
        updateStatusLabel()
        updateDoneButton()

        // Start batch import
        Task {
            await performBatchImport()
        }
    }

    // MARK: - Import Execution

    private func performBatchImport() async {
        let service = PresetDictionaryService.shared

        _ = await service.importBatch(
            presets,
            onProgress: { [weak self] presetId, progress in
                Task { @MainActor in
                    self?.importStates[presetId] = .importing(progress: progress)
                    self?.reconfigureItem(presetId)
                }
            },
            onComplete: { [weak self] result in
                Task { @MainActor in
                    self?.handleResult(result)
                }
            }
        )

        // Final UI update
        updateDoneButton()
        updateStatusLabel()
    }

    /// Retry a single failed preset import
    private func retryImport(preset: PresetDictionary) {
        importStates[preset.id] = .importing(progress: 0)
        reconfigureItem(preset.id)
        updateDoneButton()
        updateStatusLabel()

        Task {
            let service = PresetDictionaryService.shared
            do {
                let dictId: String
                if preset.isBundleAsset {
                    dictId = try await service.importFromBundle(preset)
                } else {
                    dictId = try await service.importFromODR(preset) { [weak self] progress in
                        Task { @MainActor in
                            self?.importStates[preset.id] = .importing(progress: progress)
                            self?.reconfigureItem(preset.id)
                        }
                    }
                }
                importStates[preset.id] = .completed
                // Piggyback loading into RAM
                Task {
                    await DictionaryService.shared.refreshAfterImport(dictId)
                }
                print("✅ Retry succeeded: \(preset.displayName) → \(dictId.prefix(16))...")
            } catch {
                importStates[preset.id] = .failed(message: error.localizedDescription)
                print("❌ Retry failed: \(preset.displayName): \(error.localizedDescription)")
            }

            reconfigureItem(preset.id)
            updateDoneButton()
            updateStatusLabel()
        }
    }

    // MARK: - Result Handling

    private func handleResult(_ result: PresetImportResult) {
        if result.isSuccess {
            importStates[result.presetId] = .completed

            // Piggyback: immediately start loading this dictionary into RAM
            // while other imports continue. By the time user taps "Done",
            // all successfully imported dicts are already loaded and searchable.
            if let dictId = result.libraryId {
                Task {
                    await DictionaryService.shared.refreshAfterImport(dictId)
                    print("📖 Piggybacked load complete: \(dictId.prefix(16))...")
                }
            }
        } else {
            let message = result.errorMessage ?? L10n.unknownError
            importStates[result.presetId] = .failed(message: message)
        }
        reconfigureItem(result.presetId)
        updateDoneButton()
        updateStatusLabel()
    }

    // MARK: - UI Updates

    private func reconfigureItem(_ presetId: String) {
        var snapshot = dataSource.snapshot()
        if snapshot.itemIdentifiers.contains(presetId) {
            snapshot.reconfigureItems([presetId])
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func updateDoneButton() {
        let done = isAllDone
        doneButton.isEnabled = done
        doneButton.configuration?.showsActivityIndicator = !done
        doneButton.configuration?.title = done ? L10n.done : L10n.Progress.importing
    }

    private func updateStatusLabel() {
        let completed = presets.filter {
            if case .completed = importStates[$0.id] { return true }
            return false
        }.count
        let failed = presets.filter {
            if case .failed = importStates[$0.id] { return true }
            return false
        }.count
        let total = presets.count

        if isAllDone {
            if failed == 0 {
                messageLabel.text = L10n.allImportedSuccess(completed)
            } else {
                messageLabel.text = L10n.importedAndFailed(imported: completed, failed: failed)
            }

            // Update icon to green checkmark
            let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.systemGreen]))
            iconImageView.image = UIImage(systemName: "checkmark.icloud.fill", withConfiguration: config)
        } else {
            let inProgress = completed + 1
            messageLabel.text = L10n.importingProgress(current: min(inProgress, total), total: total)
        }
    }

    // MARK: - Collection View Setup

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfig.headerMode = .none

        // Use section provider to set contentInsetsReference per-section.
        let layout = UICollectionViewCompositionalLayout { _, layoutEnvironment in
            let section = NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: layoutEnvironment)
            section.contentInsetsReference = .readableContent
            section.contentInsets.leading = 12
            section.contentInsets.trailing = 12
            return section
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = .systemGroupedBackground

        view.addSubview(collectionView)
    }

    private func setupLayout() {
        view.addSubview(headerStack)
        view.addSubview(bottomSeparator)
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            // Header (icon + message)
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.readableContentGuide.leadingAnchor),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.readableContentGuide.trailingAnchor),
            headerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Collection view (below header, above separator)
            collectionView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            // Separator
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            // Done button (pinned to bottom)
            doneButton.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor, constant: 20),
            doneButton.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            doneButton.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    // MARK: - Data Source

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, indexPath, presetId in
            guard let self, let preset = self.findPreset(id: presetId) else { return }
            self.configureCell(cell, preset: preset)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, presetId in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: presetId)
        }
    }

    private func configureCell(_ cell: UICollectionViewListCell, preset: PresetDictionary) {
        let state = importStates[preset.id] ?? .pending

        var content = UIListContentConfiguration.subtitleCell()
        content.text = "\(preset.flag) \(preset.displayName)"

        var accessories: [UICellAccessory] = []

        switch state {
        case .pending:
            content.secondaryText = preset.sizeFormatted
            content.secondaryTextProperties.color = .tertiaryLabel
            let clockImage = UIImageView(image: UIImage(systemName: "clock"))
            clockImage.tintColor = .tertiaryLabel
            accessories.append(.customView(configuration: .init(
                customView: clockImage, placement: .trailing(displayed: .always)
            )))

        case .importing(let progress):
            let totalMB = Double(preset.sizeBytes) / 1_048_576
            if progress > 0 && totalMB > 0 {
                let completedMB = totalMB * progress
                content.secondaryText = L10n.Progress.downloadingBytes(
                    completedMB: completedMB, totalMB: totalMB
                )
            } else {
                content.secondaryText = L10n.Progress.importing
            }
            content.secondaryTextProperties.color = .secondaryLabel

            let ring = CircularProgressView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            ring.progress = CGFloat(progress)
            accessories.append(.customView(configuration: .init(
                customView: ring, placement: .trailing(displayed: .always),
                reservedLayoutWidth: .custom(24)
            )))

        case .completed:
            content.secondaryText = preset.sizeFormatted
            content.secondaryTextProperties.color = .secondaryLabel
            let checkImage = UIImageView(image: UIImage(systemName: "checkmark.diamond.fill"))
            checkImage.tintColor = .systemGreen
            accessories.append(.customView(configuration: .init(
                customView: checkImage, placement: .trailing(displayed: .always)
            )))

        case .failed(let message):
            // Error icon prefix in subtitle via NSAttributedString
            let attachment = NSTextAttachment()
            attachment.image = UIImage(systemName: "xmark.circle.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            let attrStr = NSMutableAttributedString(attachment: attachment)
            attrStr.append(NSAttributedString(string: " \(message)"))
            content.secondaryAttributedText = attrStr
            content.secondaryTextProperties.color = .systemRed

            // Retry icon (trailing action)
            let retryImage = UIImageView(image: UIImage(systemName: "arrow.clockwise.circle"))
            retryImage.tintColor = .systemBlue
            accessories.append(.customView(configuration: .init(
                customView: retryImage, placement: .trailing(displayed: .always)
            )))
        }

        cell.contentConfiguration = content
        cell.accessories = accessories
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(presets.map { $0.id }, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        onDone?()
    }

    // MARK: - Helpers

    private func findPreset(id: String) -> PresetDictionary? {
        presets.first { $0.id == id }
    }
}

// MARK: - UICollectionViewDelegate

extension ImportProgressViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let presetId = dataSource.itemIdentifier(for: indexPath),
              let preset = findPreset(id: presetId) else { return }

        // Only allow retry on failed items
        guard case .failed = importStates[presetId] else { return }

        retryImport(preset: preset)
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let presetId = dataSource.itemIdentifier(for: indexPath) else { return false }

        // Only highlight failed items (for retry)
        if case .failed = importStates[presetId] {
            return true
        }
        return false
    }
}

