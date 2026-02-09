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

    // MARK: - UI

    private let titleIconView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let image = UIImage(systemName: "arrow.down.circle.fill", withConfiguration: config)
        let iv = UIImageView(image: image)
        iv.tintColor = .label
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Setting Up Dictionaries"
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.numberOfLines = 0
        return label
    }()

    private let titleStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let doneButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Importing..."
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = false
        return button
    }()

    /// Separator line above the bottom area
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

        // Assemble title stack (icon + label)
        titleStack.addArrangedSubview(titleIconView)
        titleStack.addArrangedSubview(titleLabel)

        setupCollectionView()
        setupBottomBar()
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
        } else {
            let message = result.error?.localizedDescription ?? "Unknown error"
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
        doneButton.configuration?.title = done ? "Done" : "Importing..."
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
                statusLabel.text = "All \(completed) dictionaries imported successfully!"
            } else {
                statusLabel.text = "\(completed) imported, \(failed) failed"
            }
        } else {
            let inProgress = completed + 1
            statusLabel.text = "Importing \(min(inProgress, total)) of \(total)..."
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

    private func setupBottomBar() {
        view.addSubview(titleStack)
        view.addSubview(bottomSeparator)
        view.addSubview(statusLabel)
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            // Title header (centered, aligned with readableContentGuide)
            titleStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.readableContentGuide.leadingAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: view.readableContentGuide.trailingAnchor),

            // Separator
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            bottomSeparator.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),

            // Status label (constrained to readableContentGuide for iPad)
            statusLabel.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -12),

            // Done button (constrained to readableContentGuide for iPad)
            doneButton.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            doneButton.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),

            // Collection view (below title header, above separator)
            collectionView.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
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
            let percent = Int(progress * 100)
            content.secondaryText = percent > 0 ? "Downloading... \(percent)%" : "Importing..."
            content.secondaryTextProperties.color = .secondaryLabel

            let progressView = UIProgressView(progressViewStyle: .default)
            progressView.progress = Float(progress)
            // UICellAccessory.customView requires translatesAutoresizingMaskIntoConstraints = true (default).
            // Use .custom width since UIProgressView's intrinsicContentSize fills the container.
            progressView.frame = CGRect(x: 0, y: 0, width: 60, height: 4)
            accessories.append(.customView(configuration: .init(
                customView: progressView, placement: .trailing(displayed: .always),
                reservedLayoutWidth: .custom(60)
            )))

        case .completed:
            content.secondaryText = preset.sizeFormatted
            content.secondaryTextProperties.color = .secondaryLabel
            let checkImage = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            checkImage.tintColor = .systemGreen
            accessories.append(.customView(configuration: .init(
                customView: checkImage, placement: .trailing(displayed: .always)
            )))

        case .failed(let message):
            content.secondaryText = message
            content.secondaryTextProperties.color = .systemRed

            // Error icon
            let errorImage = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
            errorImage.tintColor = .systemRed
            accessories.append(.customView(configuration: .init(
                customView: errorImage, placement: .trailing(displayed: .always)
            )))

            // Retry icon (placed after error icon)
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

