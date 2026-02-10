//
//  PresetDictionaryPickerViewController.swift
//  OpenMDict-iOS
//
//  Step 2 of the onboarding flow, also reusable from sidebar management.
//  Shows preset dictionaries grouped by source language with checkboxes.
//
//  Two modes:
//  - .firstInstall: bundle dicts locked (pre-checked, non-toggleable), shown on first launch
//  - .management: everything is optional, already-imported dicts shown with badge
//

import UIKit

final class PresetDictionaryPickerViewController: UIViewController {

    // MARK: - Mode

    enum Mode {
        /// First install: bundle dicts are locked (pre-checked, cannot uncheck)
        case firstInstall
        /// Sidebar management: everything optional, imported dicts badged
        case management
    }

    let mode: Mode

    // MARK: - Callbacks

    /// Called when user taps "Continue" with the selected presets
    var onContinue: (([PresetDictionary]) -> Void)?

    /// Called when user taps "Cancel" (management mode only)
    var onCancel: (() -> Void)?

    // MARK: - State

    /// Selected preset IDs
    private var selectedIds: Set<String> = []

    /// Catalog grouped by direction.src, sorted for display
    private var languageGroups: [LanguageGroup] = []

    private struct LanguageGroup {
        let langCode: String       // direction.src code (e.g. "DE")
        let flag: String           // source language flag emoji
        let presets: [PresetDictionary]
    }

    // MARK: - DiffableDataSource Types

    private nonisolated enum PickerSection: Hashable, Sendable {
        case language(code: String)
    }

    private nonisolated enum PickerItem: Hashable, Sendable {
        case dictionary(id: String)
    }

    // MARK: - UI

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<PickerSection, PickerItem>!

    private let continueButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Continue"
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    /// Separator line above the continue button area
    private let bottomSeparator: UIView = {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Init

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        // Navigation bar title
        if mode == .firstInstall {
            title = "Choose Dictionaries"
            subtitleLabel.text = "Select dictionaries to install. You can change this later."
        } else {
            title = "Add Preset Dictionaries"
            subtitleLabel.text = "Select dictionaries to add to your library."
        }

        // Navigation bar items
        // Left: close button (management mode only — firstInstall is non-dismissible)
        if mode == .management {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(cancelTapped)
            )
        }

        // Right: Select All / Deselect All
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Select All",
            style: .plain,
            target: self,
            action: #selector(selectAllTapped)
        )

        loadCatalogData()
        computePreSelection()
        setupCollectionView()
        setupLayout()
        configureDataSource()
        applySnapshot()
        updateContinueButton()
        updateSelectAllButton()
    }

    // MARK: - Catalog Data

    private func loadCatalogData() {
        let service = PresetDictionaryService.shared
        do {
            try service.loadCatalog()
        } catch {
            print("⚠️ Failed to load preset catalog: \(error)")
        }
        service.refreshImportStatus()

        // Group visible presets (tier != nil) by direction.src
        let visible = service.catalog.filter { $0.tier != nil }
        let grouped = Dictionary(grouping: visible) { $0.direction.src }

        let preferredLangs = Self.preferredLanguageCodes()

        languageGroups = grouped.map { langCode, presets in
            let sorted = presets.sorted { a, b in
                // 1. Lower tier first
                if (a.tier ?? 99) != (b.tier ?? 99) { return (a.tier ?? 99) < (b.tier ?? 99) }
                // 2. Bundle assets before ODR within same tier
                if a.isBundleAsset != b.isBundleAsset { return a.isBundleAsset }
                // 3. Alphabetical
                return a.displayName < b.displayName
            }

            return LanguageGroup(
                langCode: langCode,
                flag: sorted[0].flag,
                presets: sorted
            )
        }
        .sorted { a, b in
            let aPreferred = preferredLangs.contains(a.langCode)
            let bPreferred = preferredLangs.contains(b.langCode)
            if aPreferred != bPreferred { return aPreferred }
            if a.langCode == "EN" { return true }
            if b.langCode == "EN" { return false }
            let aName = PresetDictionary.localizedLanguageName(a.langCode)
            let bName = PresetDictionary.localizedLanguageName(b.langCode)
            return aName < bName
        }
    }

    // MARK: - Pre-selection

    private func computePreSelection() {
        let service = PresetDictionaryService.shared
        let preferredLangs = Self.preferredLanguageCodes()

        for group in languageGroups {
            for preset in group.presets {
                // First install: always select bundle assets
                if mode == .firstInstall && preset.isBundleAsset {
                    selectedIds.insert(preset.id)
                    continue
                }

                // Management: skip already-imported
                if mode == .management && service.isImported(preset.id) {
                    continue
                }

                // Pre-select tier 0 if src or any dest language matches user's preferred languages
                if preset.tier == 0 && !preset.languages.isDisjoint(with: preferredLangs) {
                    selectedIds.insert(preset.id)
                }
            }
        }

        // EN src tier 0 always pre-selected on first install
        if mode == .firstInstall {
            for preset in PresetDictionaryService.shared.catalog
                where preset.direction.src == "EN" && preset.tier == 0 {
                selectedIds.insert(preset.id)
            }
        }
    }

    // MARK: - Locale Detection

    /// Extract ISO 639-1 language codes from Locale.preferredLanguages.
    /// Maps iOS locale codes (e.g. "zh-Hans-US", "ja-JP") to our catalog codes ("ZH", "JA").
    static func preferredLanguageCodes() -> Set<String> {
        var codes: Set<String> = ["EN"]  // Always include English
        for lang in Locale.preferredLanguages {
            let primary = lang.split(separator: "-").first.map(String.init) ?? lang
            codes.insert(primary.uppercased())
        }
        return codes
    }

    // MARK: - Collection View Setup

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfig.headerMode = .supplementary

        // Use section provider so we can set contentInsetsReference per-section.
        // List sections don't inherit this from the layout configuration.
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
        view.addSubview(subtitleLabel)
        view.addSubview(bottomSeparator)
        view.addSubview(continueButton)

        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            // Subtitle below the navigation bar
            subtitleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),

            // Collection view (below subtitle, above separator)
            collectionView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            // Separator
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            bottomSeparator.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -16),

            // Continue button (constrained to readableContentGuide for iPad)
            continueButton.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            continueButton.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            continueButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    // MARK: - Data Source

    private func configureDataSource() {
        // Cell registration
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, indexPath, presetId in
            guard let self, let preset = self.findPreset(id: presetId) else { return }
            self.configureCell(cell, preset: preset)
        }

        // Section header registration
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, _, indexPath in
            guard let self,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section),
                  case .language(let code) = section,
                  let group = self.languageGroups.first(where: { $0.langCode == code })
            else { return }

            var content = headerView.defaultContentConfiguration()
            content.text = Self.sectionHeaderText(for: group)
            headerView.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .dictionary(let id):
                return collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: id)
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func configureCell(_ cell: UICollectionViewListCell, preset: PresetDictionary) {
        let service = PresetDictionaryService.shared
        let isSelected = selectedIds.contains(preset.id)
        let isImported = service.isImported(preset.id)
        let isLocked = (mode == .firstInstall && preset.isBundleAsset)

        // Content configuration
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "\(preset.flag) \(preset.displayName)"

        let entriesStr = Self.formatNumber(preset.entries)
        let size = preset.sizeFormatted
        let defLangs = preset.direction.dest.map { code in
            let f = PresetDictionary.flagEmoji(for: code)
            let name = PresetDictionary.localizedLanguageName(code)
            return "\(f) \(name)"
        }.joined(separator: ", ")
        content.secondaryText = "\(defLangs) \u{00B7} \(entriesStr) entries \u{00B7} \(size)"
        content.secondaryTextProperties.color = .secondaryLabel

        // Dim tier 2+ alternatives OR already-imported items in management mode
        if (isImported && mode == .management) {
            content.textProperties.color = .secondaryLabel
            content.secondaryTextProperties.color = .tertiaryLabel
        } else if let tier = preset.tier, tier >= 2 {
            content.textProperties.color = .secondaryLabel
            content.secondaryTextProperties.color = .tertiaryLabel
        }

        cell.contentConfiguration = content

        // Accessories
        var accessories: [UICellAccessory] = []

        if isImported && mode == .management {
            // Already imported — no leading checkbox (ambiguous in this context).
            // Diamond checkmark as trailing status indicator (distinct from circle checkboxes).
            let checkImage = UIImageView(image: UIImage(systemName: "checkmark.diamond.fill"))
            checkImage.tintColor = .systemGreen
            accessories.append(.customView(configuration: .init(
                customView: checkImage, placement: .trailing(displayed: .always)
            )))

        } else if isLocked {
            // Checkmark icon (leading) — pre-checked and cannot be unchecked
            let lockImage = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            lockImage.tintColor = .systemGray
            accessories.append(.customView(configuration: .init(
                customView: lockImage, placement: .leading(displayed: .always)
            )))

        } else {
            // Normal checkbox (leading)
            let imageName = isSelected ? "checkmark.circle.fill" : "circle"
            let imageView = UIImageView(image: UIImage(systemName: imageName))
            imageView.tintColor = isSelected ? .systemBlue : .tertiaryLabel
            accessories.append(.customView(configuration: .init(
                customView: imageView, placement: .leading(displayed: .always)
            )))
        }

        cell.accessories = accessories
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<PickerSection, PickerItem>()

        for group in languageGroups {
            let section = PickerSection.language(code: group.langCode)
            snapshot.appendSections([section])
            let items = group.presets.map { PickerItem.dictionary(id: $0.id) }
            snapshot.appendItems(items, toSection: section)
        }

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Continue Button

    private func updateContinueButton() {
        let count = selectedIds.count
        let title = count > 0 ? "Confirm Selection (\(count) items)" : "Confirm Selection"
        continueButton.configuration?.title = title
        continueButton.isEnabled = count > 0
    }

    // MARK: - Actions

    @objc private func continueTapped() {
        let selected = selectedIds.compactMap { findPreset(id: $0) }
        onContinue?(selected)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func selectAllTapped() {
        let selectableIds = allSelectableIds()
        let allSelected = !selectableIds.isEmpty && selectableIds.isSubset(of: selectedIds)

        if allSelected {
            selectedIds.subtract(selectableIds)
        } else {
            selectedIds.formUnion(selectableIds)
        }

        // Reconfigure all visible cells
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)

        updateContinueButton()
        updateSelectAllButton()
    }

    // MARK: - Select All State

    private func allSelectableIds() -> Set<String> {
        let service = PresetDictionaryService.shared
        var ids = Set<String>()
        for group in languageGroups {
            for preset in group.presets {
                if mode == .firstInstall && preset.isBundleAsset { continue }
                if mode == .management && service.isImported(preset.id) { continue }
                ids.insert(preset.id)
            }
        }
        return ids
    }

    private func updateSelectAllButton() {
        let selectableIds = allSelectableIds()
        let allSelected = !selectableIds.isEmpty && selectableIds.isSubset(of: selectedIds)
        navigationItem.rightBarButtonItem?.title = allSelected ? "Deselect All" : "Select All"
    }

    // MARK: - Helpers

    private func findPreset(id: String) -> PresetDictionary? {
        PresetDictionaryService.shared.catalog.first { $0.id == id }
    }

    /// Build section header text: just "🇬🇧 English" (localized via Locale API)
    private static func sectionHeaderText(for group: LanguageGroup) -> String {
        let langName = PresetDictionary.localizedLanguageName(group.langCode)
        return "\(group.flag) \(langName)"
    }

    private static func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - UICollectionViewDelegate

extension PresetDictionaryPickerViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .dictionary(let presetId) = item,
              let preset = findPreset(id: presetId) else { return }

        // Locked items (bundle on first install) cannot be toggled
        if mode == .firstInstall && preset.isBundleAsset { return }

        // Already-imported items cannot be toggled in management mode
        if mode == .management && PresetDictionaryService.shared.isImported(presetId) { return }

        // Toggle selection
        if selectedIds.contains(presetId) {
            selectedIds.remove(presetId)
        } else {
            selectedIds.insert(presetId)
        }

        // Reconfigure just this cell
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)

        updateContinueButton()
        updateSelectAllButton()
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .dictionary(let presetId) = item,
              let preset = findPreset(id: presetId) else { return false }

        // Locked items should not highlight
        if mode == .firstInstall && preset.isBundleAsset { return false }

        // Already-imported items should not highlight in management mode
        if mode == .management && PresetDictionaryService.shared.isImported(presetId) { return false }

        return true
    }
}
