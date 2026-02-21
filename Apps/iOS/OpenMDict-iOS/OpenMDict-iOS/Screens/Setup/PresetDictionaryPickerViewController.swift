//
//  PresetDictionaryPickerViewController.swift
//  OpenMDict-iOS
//
//  Step 2 of the onboarding flow, also reusable from sidebar management.
//  Shows preset dictionaries grouped by source language with checkboxes.
//
//  Two modes:
//  - .firstInstall: tier 0 locked (pre-checked, non-toggleable), shown on first launch
//  - .management: everything is optional, already-imported dicts shown with badge
//

import UIKit

final class PresetDictionaryPickerViewController: UIViewController {

    // MARK: - Mode

    enum Mode {
        /// First install: tier 0 locked (pre-selected, non-deselectable)
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

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<PickerSection, PickerItem>!

    private let continueButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = L10n.Picker.continueButton
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

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
            title = L10n.Picker.titleFirstInstall
        } else {
            title = L10n.Picker.titleManagement
        }

        // Left: close button — only when onCancel is wired (management mode
        // that is actually cancellable; the "picker-only re-launch" case reuses
        // management mode but is non-cancellable).
        if onCancel != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(cancelTapped)
            )
        }

        // Right: Select All / Deselect All
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.Picker.selectAll,
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

        // Build a priority map: EN always 0, then user device languages
        // in preference order, everything else gets Int.max (sorted alphabetically).
        let orderedLangs = Self.orderedPreferredLanguageCodes()
        var priorityMap: [String: Int] = ["EN": 0]
        for (index, code) in orderedLangs.enumerated() {
            if priorityMap[code] == nil {
                priorityMap[code] = index + 1  // EN=0, then 1,2,3…
            }
        }

        languageGroups = grouped.map { langCode, presets in
            let sorted = presets.sorted { a, b in
                // 1. Lower tier first
                if (a.tier ?? 99) != (b.tier ?? 99) { return (a.tier ?? 99) < (b.tier ?? 99) }
                // 2. Bundle assets before ODR within same tier
                if a.isBundleAsset != b.isBundleAsset { return a.isBundleAsset }
                // 3. Monolingual before bilingual (e.g. Moby Thesaurus EN→EN before FreeDict EN→DE)
                if a.isMonolingual != b.isMonolingual { return a.isMonolingual }
                // 4. Alphabetical
                return a.displayName < b.displayName
            }

            return LanguageGroup(
                langCode: langCode,
                flag: PresetDictionary.flagEmoji(for: langCode),
                presets: sorted
            )
        }
        .sorted { a, b in
            let aPriority = priorityMap[a.langCode] ?? Int.max
            let bPriority = priorityMap[b.langCode] ?? Int.max
            if aPriority != bPriority { return aPriority < bPriority }
            // Both unprioritized → cultural proximity cluster, then localized name.
            // East Asian / CJK-sphere languages appear before Western / other,
            // matching user expectations in CJK locales where kanji-named and
            // katakana-named languages would otherwise interleave confusingly.
            let aCluster = Self.culturalCluster(a.langCode)
            let bCluster = Self.culturalCluster(b.langCode)
            if aCluster != bCluster { return aCluster < bCluster }
            let aName = PresetDictionary.localizedLanguageName(a.langCode)
            let bName = PresetDictionary.localizedLanguageName(b.langCode)
            return aName.localizedCaseInsensitiveCompare(bName) == .orderedAscending
        }
    }

    // MARK: - Pre-selection

    private func computePreSelection() {
        let service = PresetDictionaryService.shared
        let preferredLangs = Self.preferredLanguageCodes()

        for group in languageGroups {
            for preset in group.presets {
                let tier = preset.tier ?? 3
                let destLangs = Set(preset.direction.dest)
                let matchesDeviceLangs = preferredLangs.contains(preset.direction.src)
                    && !destLangs.isDisjoint(with: preferredLangs)

                // Management — skip already-imported
                if mode == .management && service.isImported(preset.id) {
                    continue
                }

                // Tier 0 (essential): always pre-selected in firstInstall (locked),
                //   in management mode only if device languages match.
                // Tier 1 (recommended): pre-selected if device languages match.
                // Tier 2 (alternative): pre-selected if device languages match.
                // Tier 3 (ordinary): never pre-selected.
                switch tier {
                case 0:
                    if mode == .firstInstall || matchesDeviceLangs {
                        selectedIds.insert(preset.id)
                    }
                case 1, 2:
                    if matchesDeviceLangs {
                        selectedIds.insert(preset.id)
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - Locale Detection

    /// Extract ISO 639-1 language codes from Locale.preferredLanguages.
    /// Maps iOS locale codes (e.g. "zh-Hans-US", "ja-JP") to our catalog codes ("ZH", "JA").
    /// Returns only the languages the user has actually configured on their device.
    static func preferredLanguageCodes() -> Set<String> {
        Set(orderedPreferredLanguageCodes())
    }

    /// Ordered version of `preferredLanguageCodes()` — preserves the user's
    /// device language priority (first = most preferred).
    /// Used for section ordering in the picker.
    static func orderedPreferredLanguageCodes() -> [String] {
        var seen = Set<String>()
        var codes: [String] = []
        for lang in Locale.preferredLanguages {
            let primary = lang.split(separator: "-").first.map(String.init) ?? lang
            let code = primary.uppercased()
            if seen.insert(code).inserted {
                codes.append(code)
            }
        }
        return codes
    }

    /// Cultural proximity cluster for language group ordering.
    /// East Asian / CJK-sphere (0) → European / Latin-alphabet (1) → Other (2).
    /// Within each cluster groups sort by localized name.
    private static func culturalCluster(_ code: String) -> Int {
        switch code {
        case "ZH", "JA", "KO":  return 0   // CJK sphere
        case "EN", "ES", "FR", "DE", "IT", "PT", "LA", "EL", "TR":
                                return 1   // European / Latin-alphabet
        case "RU":              return 1   // Cyrillic, but European cultural context
        default:                return 2   // Arabic, etc.
        }
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
        view.addSubview(bottomSeparator)
        view.addSubview(continueButton)

        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            // Collection view (fills space between nav bar and separator)
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            // Separator
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            // Continue button (pinned to bottom)
            continueButton.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor, constant: 20),
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
        let tier = preset.tier ?? 3
        let isLocked = mode == .firstInstall && tier == 0

        // Content configuration
        var content = UIListContentConfiguration.subtitleCell()
        content.text = preset.displayName

        let size = preset.sizeFormatted
        let srcFlag = preset.flag
        let destFlags = preset.direction.dest.map { PresetDictionary.flagEmoji(for: $0) }.joined(separator: " ")
        let directionLabel = "\(srcFlag) \u{2192} \(destFlags)"
        content.secondaryText = "\(directionLabel) \u{00B7} \(L10n.entryCount(preset.entries)) \u{00B7} \(size)"
        content.secondaryTextProperties.color = .secondaryLabel

        // Bold for tier 0/1 (prominent), normal weight for tier 2/3
        if tier <= 1,
           let boldDesc = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
               .withSymbolicTraits(.traitBold) {
            content.textProperties.font = UIFont(descriptor: boldDesc, size: 0)
        }

        // Dim already-imported items in management mode
        if isImported && mode == .management {
            content.textProperties.color = .secondaryLabel
            content.secondaryTextProperties.color = .tertiaryLabel
        }

        cell.contentConfiguration = content

        // Accessories
        var accessories: [UICellAccessory] = []

        if isImported && mode == .management {
            // Already imported — diamond checkmark as trailing status indicator
            let checkImage = UIImageView(image: UIImage(systemName: "checkmark.diamond.fill"))
            checkImage.tintColor = .systemGreen
            accessories.append(.customView(configuration: .init(
                customView: checkImage, placement: .trailing(displayed: .always)
            )))

        } else if isLocked {
            // Tier 0 in firstInstall — always selected, disabled appearance
            let lockImage = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            lockImage.tintColor = .secondaryLabel
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
        if count > 0 {
            continueButton.configuration?.title = L10n.confirmSelection(count)
            continueButton.configuration?.baseBackgroundColor = nil  // system default (filled blue)
        } else if mode == .firstInstall {
            continueButton.configuration?.title = L10n.Picker.skipPresets
            continueButton.configuration?.baseBackgroundColor = .systemGray4
        } else {
            continueButton.configuration?.title = L10n.Picker.confirmSelection
            continueButton.configuration?.baseBackgroundColor = nil
        }
        continueButton.isEnabled = true
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
                if mode == .management && service.isImported(preset.id) { continue }
                // Tier 0 is locked in firstInstall — not toggleable by Select All
                if mode == .firstInstall && (preset.tier ?? 3) == 0 { continue }
                ids.insert(preset.id)
            }
        }
        return ids
    }

    private func updateSelectAllButton() {
        let selectableIds = allSelectableIds()
        let allSelected = !selectableIds.isEmpty && selectableIds.isSubset(of: selectedIds)
        navigationItem.rightBarButtonItem?.title = allSelected ? L10n.Picker.deselectAll : L10n.Picker.selectAll
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

        // Already-imported items cannot be toggled in management mode
        if mode == .management && PresetDictionaryService.shared.isImported(presetId) { return }

        // Tier 0 is locked (non-toggleable) in firstInstall mode
        if mode == .firstInstall && (preset.tier ?? 3) == 0 { return }

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

        // Already-imported items should not highlight in management mode
        if mode == .management && PresetDictionaryService.shared.isImported(presetId) { return false }

        // Tier 0 is locked in firstInstall mode — no highlight
        if mode == .firstInstall && (preset.tier ?? 3) == 0 { return false }

        return true
    }
}
