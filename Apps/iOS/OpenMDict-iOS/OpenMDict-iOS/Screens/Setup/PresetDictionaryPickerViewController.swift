//
//  PresetDictionaryPickerViewController.swift
//  OpenMDict-iOS
//
//  Step 2 of the onboarding flow, also reusable from sidebar management.
//  Shows preset dictionaries in a 3-level hierarchy:
//    Region (section) → Language (expandable parent) → Dictionary (leaf)
//
//  Two modes:
//  - .firstInstall: tier 0 locked (pre-checked, non-toggleable), shown on first launch
//  - .management: everything is optional, already-imported dicts hidden
//

import UIKit

final class PresetDictionaryPickerViewController: UIViewController {

    // MARK: - Mode

    enum Mode {
        /// First install: tier 0 locked (pre-selected, non-deselectable)
        case firstInstall
        /// Sidebar management: everything optional, already-imported dicts hidden
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

    /// Hierarchical data: Region → [LanguageGroup]
    private var regionGroups: [(region: PresetDictionary.Region, languages: [LanguageGroup])] = []

    private struct LanguageGroup {
        let langCode: String               // primary language code (e.g. "JA", "CJK", "YUE")
        let flag: String                   // emoji flag
        let displayName: String            // localized language name
        let presets: [PresetDictionary]    // sorted dicts under this language
    }

    // MARK: - DiffableDataSource Types

    private nonisolated enum PickerSection: Hashable, Sendable {
        case region(String)   // region rawValue, e.g. "Far East"
    }

    private nonisolated enum PickerItem: Hashable, Sendable {
        case languageHeader(code: String, region: String)   // expandable parent
        case dictionary(id: String)                         // checkable leaf
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

        // Empty state: all available presets are already installed (management mode only)
        if regionGroups.isEmpty && mode == .management {
            setupCollectionView()
            setupLayout()
            showEmptyState()
            return
        }

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

        // Filter visible presets (tier != nil).
        // In management mode, hide already-imported dictionaries entirely.
        var visible = service.catalog.filter { $0.tier != nil }
        if mode == .management {
            visible = visible.filter { !service.isImported($0.id) }
        }

        // Group by region → primaryLanguage
        let byRegion = Dictionary(grouping: visible) { $0.region }

        // Build a priority map for language ordering within regions
        let orderedLangs = Self.orderedPreferredLanguageCodes()
        var priorityMap: [String: Int] = ["EN": 0]
        for (index, code) in orderedLangs.enumerated() {
            if priorityMap[code] == nil {
                priorityMap[code] = index + 1
            }
        }

        regionGroups = PresetDictionary.Region.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { region in
                guard let presetsInRegion = byRegion[region], !presetsInRegion.isEmpty else { return nil }

                // Group by primaryLanguage within this region
                let byLang = Dictionary(grouping: presetsInRegion) { $0.primaryLanguage }

                let languages = byLang.map { langCode, presets in
                    let sorted = presets.sorted { a, b in
                        // 1. Lower tier first
                        if (a.tier ?? 99) != (b.tier ?? 99) { return (a.tier ?? 99) < (b.tier ?? 99) }
                        // 2. Bundle assets before ODR within same tier
                        if a.isBundleAsset != b.isBundleAsset { return a.isBundleAsset }
                        // 3. Monolingual before bilingual
                        if a.isMonolingual != b.isMonolingual { return a.isMonolingual }
                        // 4. Alphabetical
                        return a.displayName < b.displayName
                    }
                    let first = presets[0]
                    return LanguageGroup(
                        langCode: langCode,
                        flag: first.primaryFlag,
                        displayName: first.primaryLanguageName,
                        presets: sorted
                    )
                }
                .sorted { a, b in
                    let aPriority = priorityMap[a.langCode] ?? Int.max
                    let bPriority = priorityMap[b.langCode] ?? Int.max
                    if aPriority != bPriority { return aPriority < bPriority }
                    return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                }

                return (region: region, languages: languages)
            }
    }

    // MARK: - Pre-selection

    private func computePreSelection() {
        let preferredLangs = Self.preferredLanguageCodes()

        for regionGroup in regionGroups {
            for langGroup in regionGroup.languages {
                for preset in langGroup.presets {
                    let tier = preset.tier ?? 3
                    let destLangs = Set(preset.direction.dest)
                    let matchesDeviceLangs = preferredLangs.contains(preset.direction.src)
                        && !destLangs.isDisjoint(with: preferredLangs)

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
    }

    // MARK: - Locale Detection

    static func preferredLanguageCodes() -> Set<String> {
        Set(orderedPreferredLanguageCodes())
    }

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

    // MARK: - Collection View Setup

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfig.headerMode = .supplementary

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
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            continueButton.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor, constant: 20),
            continueButton.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            continueButton.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            continueButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    // MARK: - Data Source

    private func configureDataSource() {
        // Cell registration — handles both language headers and dictionary items
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, PickerItem> {
            [weak self] cell, indexPath, item in
            guard let self else { return }

            switch item {
            case .languageHeader(let code, let region):
                self.configureLanguageHeaderCell(cell, langCode: code, regionName: region)
            case .dictionary(let id):
                if let preset = self.findPreset(id: id) {
                    self.configureDictionaryCell(cell, preset: preset)
                }
            }
        }

        // Section header registration (region headers)
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, _, indexPath in
            guard let self,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section),
                  case .region(let regionName) = section
            else { return }

            var content = headerView.defaultContentConfiguration()
            if let region = self.regionGroups.first(where: { $0.region.rawValue == regionName }) {
                content.text = "\(region.region.headerEmoji) \(self.localizedRegionName(region.region))"
            } else {
                content.text = regionName
            }
            headerView.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    /// Configure a language header cell (expandable parent with disclosure triangle)
    private func configureLanguageHeaderCell(_ cell: UICollectionViewListCell, langCode: String, regionName: String) {
        guard let langGroup = findLanguageGroup(langCode: langCode, regionName: regionName) else { return }

        var content = UIListContentConfiguration.cell()
        content.text = "\(langGroup.flag) \(langGroup.displayName)"

        // Bold font for language headers
        if let boldDesc = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            .withSymbolicTraits(.traitBold) {
            content.textProperties.font = UIFont(descriptor: boldDesc, size: 0)
        }

        cell.contentConfiguration = content

        // Trailing "X / Y selected" label before disclosure
        let selectedCount = langGroup.presets.filter { selectedIds.contains($0.id) }.count
        let totalCount = langGroup.presets.count
        let countLabel = UILabel()
        countLabel.text = L10n.Picker.selectedCount(selectedCount, totalCount)
        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.textColor = .secondaryLabel
        countLabel.sizeToFit()

        cell.accessories = [
            .customView(configuration: .init(
                customView: countLabel,
                placement: .trailing(displayed: .always)
            )),
            .outlineDisclosure()
        ]
    }

    /// Configure a dictionary cell (checkable leaf with checkbox)
    private func configureDictionaryCell(_ cell: UICollectionViewListCell, preset: PresetDictionary) {
        let isSelected = selectedIds.contains(preset.id)
        let tier = preset.tier ?? 3
        let isLocked = mode == .firstInstall && tier == 0

        var content = UIListContentConfiguration.subtitleCell()
        content.text = preset.displayName

        let size = preset.sizeFormatted
        let srcFlag = preset.flag
        let destFlags = preset.direction.dest.map { PresetDictionary.flagEmoji(for: $0) }.joined(separator: " ")
        let directionLabel = "\(srcFlag) \u{2192} \(destFlags)"
        content.secondaryText = "\(directionLabel) \u{00B7} \(L10n.entryCount(preset.entries)) \u{00B7} \(size)"
        content.secondaryTextProperties.color = .secondaryLabel

        // Bold for tier 0/1
        if tier <= 1,
           let boldDesc = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
               .withSymbolicTraits(.traitBold) {
            content.textProperties.font = UIFont(descriptor: boldDesc, size: 0)
        }

        cell.contentConfiguration = content

        // Accessories
        var accessories: [UICellAccessory] = []

        if isLocked {
            let lockImage = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            lockImage.tintColor = .secondaryLabel
            accessories.append(.customView(configuration: .init(
                customView: lockImage, placement: .leading(displayed: .always)
            )))
        } else {
            let imageName = isSelected ? "checkmark.circle.fill" : "circle"
            let imageView = UIImageView(image: UIImage(systemName: imageName))
            imageView.tintColor = isSelected ? .systemBlue : .tertiaryLabel
            accessories.append(.customView(configuration: .init(
                customView: imageView, placement: .leading(displayed: .always)
            )))
        }

        cell.accessories = accessories
    }

    // MARK: - Snapshot (Hierarchical)

    private func applySnapshot() {
        // First: create the top-level snapshot with sections
        var snapshot = NSDiffableDataSourceSnapshot<PickerSection, PickerItem>()
        let sections = regionGroups.map { PickerSection.region($0.region.rawValue) }
        snapshot.appendSections(sections)
        dataSource.apply(snapshot, animatingDifferences: false)

        // Then: apply per-section hierarchical snapshots
        for regionGroup in regionGroups {
            let section = PickerSection.region(regionGroup.region.rawValue)
            var sectionSnapshot = NSDiffableDataSourceSectionSnapshot<PickerItem>()

            // Collect standalone items (no parent header) to append after all groups
            var standaloneItems: [PickerItem] = []

            for langGroup in regionGroup.languages {
                // Standalone items: no parent header (CJK/Unihan, Classical, Bible)
                if langGroup.langCode == "CJK" || regionGroup.region == .classical || regionGroup.region == .bible {
                    standaloneItems.append(contentsOf:
                        langGroup.presets.map { PickerItem.dictionary(id: $0.id) }
                    )
                    continue
                }

                // Normal: language header → dictionary children
                let parent = PickerItem.languageHeader(
                    code: langGroup.langCode,
                    region: regionGroup.region.rawValue
                )
                sectionSnapshot.append([parent])

                // Dictionary items = children
                let children = langGroup.presets.map { PickerItem.dictionary(id: $0.id) }
                sectionSnapshot.append(children, to: parent)

                // Expand only if this language group has default-selected children
                let hasSelectedChild = langGroup.presets.contains { selectedIds.contains($0.id) }
                if hasSelectedChild {
                    sectionSnapshot.expand([parent])
                }
            }

            // Append standalone items after all parent-child groups
            if !standaloneItems.isEmpty {
                sectionSnapshot.append(standaloneItems)
            }

            dataSource.apply(sectionSnapshot, to: section, animatingDifferences: false)
        }
    }

    // MARK: - Continue Button

    private func updateContinueButton() {
        let count = selectedIds.count
        if count > 0 {
            continueButton.configuration?.title = L10n.confirmSelection(count)
            continueButton.configuration?.baseBackgroundColor = nil
        } else {
            continueButton.configuration?.title = L10n.Picker.skipPresets
            continueButton.configuration?.baseBackgroundColor = .systemGray4
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
        reconfigureAllItems()

        updateContinueButton()
        updateSelectAllButton()
    }

    // MARK: - Select All State

    private func allSelectableIds() -> Set<String> {
        var ids = Set<String>()
        for regionGroup in regionGroups {
            for langGroup in regionGroup.languages {
                for preset in langGroup.presets {
                    if mode == .firstInstall && (preset.tier ?? 3) == 0 { continue }
                    ids.insert(preset.id)
                }
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

    private func findLanguageGroup(langCode: String, regionName: String) -> LanguageGroup? {
        regionGroups
            .first(where: { $0.region.rawValue == regionName })?
            .languages
            .first(where: { $0.langCode == langCode })
    }

    /// Reconfigure all items across all sections (checkbox + selection count refresh).
    private func reconfigureAllItems() {
        var snapshot = dataSource.snapshot()
        let allItems = snapshot.itemIdentifiers
        guard !allItems.isEmpty else { return }
        snapshot.reconfigureItems(allItems)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func localizedRegionName(_ region: PresetDictionary.Region) -> String {
        switch region {
        case .farEast:    return L10n.Picker.regionFarEast
        case .europe:     return L10n.Picker.regionEurope
        case .middleEast: return L10n.Picker.regionMiddleEast
        case .classical:  return L10n.Picker.regionClassical
        case .bible:      return L10n.Picker.regionBible
        }
    }

    // MARK: - Empty State

    private func showEmptyState() {
        // Hide list chrome
        collectionView.isHidden = true
        bottomSeparator.isHidden = true
        continueButton.isHidden = true
        navigationItem.rightBarButtonItem = nil

        // Build placeholder (ContentUnavailableView equivalent for iOS 15+)
        let iconName: String
        if #available(iOS 16, *) {
            iconName = "info.bubble"
        } else {
            iconName = "info.circle"
        }

        let imageView = UIImageView(image: UIImage(systemName: iconName))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .secondaryLabel
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 48, weight: .light
        )

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = L10n.Picker.allPresetsInstalled
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
}

// MARK: - UICollectionViewDelegate

extension PresetDictionaryPickerViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .languageHeader(let code, let region):
            // Toggle expand/collapse when tapping anywhere on the language header cell
            let section = PickerSection.region(region)
            var sectionSnapshot = dataSource.snapshot(for: section)
            if sectionSnapshot.isExpanded(item) {
                sectionSnapshot.collapse([item])
            } else {
                sectionSnapshot.expand([item])
            }
            dataSource.apply(sectionSnapshot, to: section, animatingDifferences: true)
            _ = code  // suppress unused warning

        case .dictionary(let presetId):
            guard let preset = findPreset(id: presetId) else { return }

            // Tier 0 is locked in firstInstall mode
            if mode == .firstInstall && (preset.tier ?? 3) == 0 { return }

            // Toggle selection
            if selectedIds.contains(presetId) {
                selectedIds.remove(presetId)
            } else {
                selectedIds.insert(presetId)
            }

            // Reconfigure this cell + its parent language header (if present)
            var snapshot = dataSource.snapshot()
            var itemsToReconfigure: [PickerItem] = [item]
            let parentItem = PickerItem.languageHeader(
                code: preset.primaryLanguage,
                region: preset.region.rawValue
            )
            if snapshot.itemIdentifiers.contains(parentItem) {
                itemsToReconfigure.append(parentItem)
            }
            snapshot.reconfigureItems(itemsToReconfigure)
            dataSource.apply(snapshot, animatingDifferences: false)

            updateContinueButton()
            updateSelectAllButton()
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }

        switch item {
        case .languageHeader:
            return true  // Allow highlight for expand/collapse

        case .dictionary(let presetId):
            guard let preset = findPreset(id: presetId) else { return false }
            if mode == .firstInstall && (preset.tier ?? 3) == 0 { return false }
            return true
        }
    }
}
