//
//  ArticleIndexOverviewViewController.swift
//  OpenMDict-iOS  (M15)
//
//  Management screen for article-content ("full-text") search indexing.
//  Reached from the sidebar / compact-management list (iOS 26+ only).
//
//  Structure — modeled after `GroupDictionaryEditorViewController`:
//
//    • Master toggle section: "Enable Article Search" switch + footer.
//    • Enabled section: dicts the user wants searchable in article search.
//    • Disabled section: dicts the user has opted out of (still listed,
//      with their current index state visible).
//
//  Tap row body = toggle between Enabled/Disabled sections. NO drag-
//  reorder — both sections sorted by the default group's `dictionaryIds`
//  order (the canonical "all dictionaries" custom order shared with
//  sidebar + group editor).
//
//  Per-dict index state (cell trailing accessory, Enabled section only
//  shows actionable buttons; Disabled section shows passive icons):
//    .indexing(N%) → spinner + ⏸ pause button
//    .paused(N%)   → ▶ resume button
//    .indexed      → ✓ checkmark
//    .error        → ⟲ retry button
//    .notIndexed   → clock icon (queued)
//
//  Enabled vs Disabled is ORTHOGONAL to index state. A disabled dict
//  can still be `.indexed` (sidecar on disk, just not queried at search
//  time). Toggle Enabled → Disabled on an indexing dict implicitly
//  pauses (state → .paused, progress preserved). Toggle Disabled →
//  Enabled on a paused dict implicitly resumes (state → .notIndexed,
//  scheduler eligible). The mutation flows through Coordinator.setEnabled
//  which owns the cancel + state-transition atomicity.
//

import UIKit
import OpenMDictKit
import Combine

private nonisolated enum AISection: Int, Hashable, Sendable {
    case toggleMaster
    case enabled
    case disabled
}

private nonisolated enum AIItem: Hashable, Sendable {
    case masterToggle
    /// `enabled` doubles as section indicator: true → Enabled section,
    /// false → Disabled. Putting it in the item identity means
    /// DiffableDataSource animates the section move when a dict toggles.
    case dict(id: String, enabled: Bool)
    /// Empty-section placeholder cells. Section is encoded in the case
    /// so DiffableDataSource can diff/animate them independently.
    case emptyEnabled
    case emptyDisabled
    /// "Zero dicts in the whole library" — distinct from `.emptyDisabled`
    /// because the copy is different ("Import a dictionary first" vs
    /// "All dictionaries are enabled"). Rendered in the Disabled
    /// section when both partitions are empty.
    case emptyNoDicts
    /// Per-dictionary article-search result-count knob (Fewer / Default /
    /// More). Lives in the toggleMaster section under the switch, shown only
    /// while the master toggle is on. In-app (not Settings.bundle) because the
    /// feature is iOS 26+ and Settings.bundle can't conditionally hide a row —
    /// see ArticleResultsTier.
    case resultsCount
}

@MainActor
final class ArticleIndexOverviewViewController: UIViewController {

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<AISection, AIItem>!
    private var cancellables = Set<AnyCancellable>()

    /// id → display name (from `DictionaryService.allDictionaries`).
    private var dictNames: [String: String] = [:]
    /// id → article total (`reader.entryCount`), the progress denominator.
    private var dictTotals: [String: Int] = [:]
    /// All dict ids, partitioned by `userExcluded` and each partition
    /// sorted by default-group order.
    private var enabledIds: [String] = []
    private var disabledIds: [String] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Surfaces this device's chip/GPU strings — drives the
        // DeviceChipInfo.prefersCPUForeground tier rule in the dispatcher.
        // Gated by VERBOSE_LOGGING (zero overhead in release).
        debugLog("📱 DeviceChipInfo (overview): \(DeviceChipInfo.summary)")
        debugLog("ArticleIndexOverviewVC.viewDidLoad: starting")
        title = L10n.ArticleIndex.title
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        // Modal dismiss (✕). Matches the other modal management VCs —
        // iCloudTroubleshooting / AppIconChooser / PresetDictionaryPicker
        // all use a `.close` system item + `dismissSelf`.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(dismissSelf)
        )
        setupCollectionView()
        setupDataSource()
        reloadDicts()
        applySnapshot(animated: false)
        // Prime caches from dispatcher + provider BEFORE subscribing so
        // the first `updateModelOverlay()` reflects what's already in
        // flight (e.g. came back to the VC during an in-progress
        // download initiated by the previous appearance).
        currentGatePauseReasons = ArticleIndexDispatcher.shared.pauseReasons
        currentProviderState = ArticleIndexAssetProvider.shared.state
        updateModelOverlay()
        subscribe()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Trigger the provider's state machine + backfill. The provider's
        // `ensureAcquired` is idempotent: it no-ops if already `.ready`,
        // piggybacks on the in-flight Task if `.acquiring`, and starts
        // fresh from `.unknown` or `.failed`. The `$state` subscription
        // catches every transition for overlay updates.
        guard UserDefaults.standard.articleSearchEnabled else {
            debugLog("ArticleIndexOverviewVC.viewWillAppear: master toggle off, no acquire trigger")
            return
        }
        Task { [weak self] in
            debugLog("ArticleIndexOverviewVC.viewWillAppear: ensureAcquired + backfillIfEnabled")
            await ArticleIndexAssetProvider.shared.ensureAcquired()
            guard self != nil else { return }
            ArticleIndexCoordinator.shared.backfillIfEnabled()
        }
    }

    // MARK: - Setup

    private func setupCollectionView() {
        var cfg = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        cfg.headerMode = .supplementary
        cfg.footerMode = .supplementary
        // Trailing swipe = pause action on in-flight indexing rows in
        // the Enabled section. The pause button used to live in the cell
        // as a visible accessory; it should
        // be de-emphasized (it's a stop-the-good-thing action), so it
        // moved to a swipe gesture.
        cfg.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipe(at: indexPath)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: cfg)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)

        // Model-status overlay. Visible only when the master toggle is
        // ON and the model isn't currently usable (downloading or in
        // some classified error state). When visible, covers the dict
        // sections — the master toggle row keeps showing in the
        // collection underneath because the overlay sits BELOW it
        // (anchored to the master section's bottom). On model-ready
        // states the overlay is hidden and dict sections render
        // normally.
        modelStatusView = EmptyStateView()
        modelStatusView.translatesAutoresizingMaskIntoConstraints = false
        modelStatusView.isHidden = true
        modelStatusView.backgroundColor = .systemGroupedBackground
        view.addSubview(modelStatusView)
        NSLayoutConstraint.activate([
            modelStatusView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 120),
            modelStatusView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            modelStatusView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            modelStatusView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Model-status overlay — see `setupCollectionView()` for the
    /// rationale. Mutated by `updateModelOverlay()`.
    private var modelStatusView: EmptyStateView!

    private func setupDataSource() {
        let toggleReg = UICollectionView.CellRegistration<UICollectionViewListCell, AIItem> {
            [weak self] cell, _, _ in
            var c = cell.defaultContentConfiguration()
            c.text = L10n.ArticleIndex.enableTitle
            // Cell stays compact (just title + switch). The "what" copy
            // moved to this section's FOOTER (enableFooter) and the "how"
            // copy moved to the Enabled-dictionaries section's footer
            // (enabledSectionFooter), because even a
            // 1-sentence subtitle on this cell felt too heavy.
            cell.contentConfiguration = c
            let sw = UISwitch()
            sw.isOn = UserDefaults.standard.articleSearchEnabled
            sw.addAction(UIAction { [weak self, weak sw] _ in
                guard let self, let sw else { return }
                // Both directions need confirmation — flipping on starts an
                // ~80 MB download and per-dict indexing pass; flipping off
                // wipes the model + every existing sidecar. Wrap in an
                // alert and revert the switch position if the user backs out.
                self.confirmMasterToggle(desiredOn: sw.isOn) { [weak sw] confirmed in
                    guard let sw else { return }
                    if confirmed { return }
                    // User cancelled — bounce the switch back to its prior
                    // state without re-firing the action.
                    sw.setOn(!sw.isOn, animated: true)
                }
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration:
                .init(customView: sw, placement: .trailing(displayed: .always)))]
        }

        let dictReg = UICollectionView.CellRegistration<UICollectionViewListCell, AIItem> {
            [weak self] cell, _, item in
            guard let self, case .dict(let id, let enabled) = item else { return }
            self.configureDictCell(cell, dictId: id, enabled: enabled)
        }

        // Empty-section placeholder. Same idiom as GroupDictionaryEditor's
        // `.emptyInGroup` / `.emptyAvailable` rows — centered tertiary
        // text, no accessories. Two cases so DiffableDataSource diffs
        // them independently when one section gains a dict and the
        // other empties. `numberOfLines = 0` so a two-sentence message
        // ("No dictionaries enabled. Tap one below to enable.") wraps
        // naturally to two lines instead of truncating mid-sentence.
        let emptyReg = UICollectionView.CellRegistration<UICollectionViewListCell, AIItem> {
            cell, _, item in
            var c = cell.defaultContentConfiguration()
            switch item {
            case .emptyEnabled:  c.text = L10n.ArticleIndex.emptyEnabled
            case .emptyDisabled: c.text = L10n.ArticleIndex.emptyDisabled
            case .emptyNoDicts:  c.text = L10n.ArticleIndex.emptyNoDicts
            default: return
            }
            c.textProperties.color = .tertiaryLabel
            c.textProperties.alignment = .center
            c.textProperties.numberOfLines = 0
            cell.contentConfiguration = c
            cell.accessories = []
        }

        // Result-count tier knob: a pull-down menu button (Fewer / Default /
        // More), the in-app equivalent of a Settings.bundle multi-value row.
        // `changesSelectionAsPrimaryAction` makes the button title track the
        // chosen tier; the UIAction writes the K value to UserDefaults, where
        // ArticleResultsTier.current reads it on the next search.
        let resultsReg = UICollectionView.CellRegistration<UICollectionViewListCell, AIItem> {
            cell, _, _ in
            var c = cell.defaultContentConfiguration()
            c.text = L10n.ArticleIndex.ResultsCount.title
            cell.contentConfiguration = c

            let tiers = ArticleResultsTier.allCases      // [.few, .default, .more]
            let titles = [
                L10n.ArticleIndex.ResultsCount.few,
                L10n.ArticleIndex.ResultsCount.default,
                L10n.ArticleIndex.ResultsCount.more,
            ]
            let current = ArticleResultsTier.current
            let button = UIButton(type: .system)
            button.showsMenuAsPrimaryAction = true
            button.changesSelectionAsPrimaryAction = true
            button.menu = UIMenu(children: zip(tiers, titles).map { tier, title in
                UIAction(title: title, state: tier == current ? .on : .off) { _ in
                    UserDefaults.standard.set(tier.k, forKey: ArticleResultsTier.userDefaultsKey)
                }
            })
            cell.accessories = [.customView(configuration:
                .init(customView: button, placement: .trailing(displayed: .always)))]
        }

        dataSource = UICollectionViewDiffableDataSource<AISection, AIItem>(
            collectionView: collectionView
        ) { cv, indexPath, item in
            switch item {
            case .masterToggle:
                return cv.dequeueConfiguredReusableCell(using: toggleReg, for: indexPath, item: item)
            case .resultsCount:
                return cv.dequeueConfiguredReusableCell(using: resultsReg, for: indexPath, item: item)
            case .dict:
                return cv.dequeueConfiguredReusableCell(using: dictReg, for: indexPath, item: item)
            case .emptyEnabled, .emptyDisabled, .emptyNoDicts:
                return cv.dequeueConfiguredReusableCell(using: emptyReg, for: indexPath, item: item)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var c = view.defaultContentConfiguration()
            switch section {
            case .toggleMaster: c.text = nil
            case .enabled:      c.text = L10n.ArticleIndex.sectionEnabled
            case .disabled:     c.text = L10n.ArticleIndex.sectionDisabled
            }
            view.contentConfiguration = c
        }
        let footerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else {
                view.contentConfiguration = nil
                return
            }
            var c = view.defaultContentConfiguration()
            switch section {
            case .toggleMaster:
                // "What" copy — describes what article search does.
                c.text = L10n.ArticleIndex.enableFooter
            case .enabled:
                // "How" copy — describes the resource cost (on-device,
                // time, requires charging). Belongs here because the
                // statement is ABOUT what happens to enabled dicts.
                c.text = L10n.ArticleIndex.enabledSectionFooter
            case .disabled:
                c.text = nil
            }
            view.contentConfiguration = c
        }
        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            if kind == UICollectionView.elementKindSectionFooter {
                return cv.dequeueConfiguredReusableSupplementary(using: footerReg, for: indexPath)
            }
            return cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    // MARK: - Cell config

    private func configureDictCell(_ cell: UICollectionViewListCell, dictId: String, enabled: Bool) {
        var c = cell.defaultContentConfiguration()
        c.text = dictNames[dictId] ?? dictId
        let snap = ArticleIndexService.shared.snapshot(for: dictId)
        let presentation = statusPresentation(snap: snap, dictId: dictId, enabled: enabled)
        // Subtitle is up to two lines: state + (optional) "N / M entries".
        // `numberOfLines = 0` allows the secondary label to grow vertically
        // so the "X / Y" line never truncates or wraps awkwardly mid-number.
        if let entriesLine = presentation.entriesLine {
            c.secondaryText = "\(presentation.subtitle)\n\(entriesLine)"
        } else {
            c.secondaryText = presentation.subtitle
        }
        c.secondaryTextProperties.color = presentation.subtitleColor
        c.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = c
        // Leading: ⊖ (red minus, will be removed) in Enabled section;
        // ⊕ (green plus, will be added) in Disabled section. Same idiom
        // as GroupDictionaryEditorViewController.
        let leadingImage = UIImageView(image: UIImage(systemName:
            enabled ? "minus.circle.fill" : "plus.circle.fill"))
        leadingImage.tintColor = enabled ? .systemRed : .systemGreen
        var accessories: [UICellAccessory] = [
            .customView(configuration: .init(customView: leadingImage, placement: .leading())),
        ]
        accessories.append(contentsOf: presentation.trailingAccessories)
        cell.accessories = accessories
    }

    // MARK: - Status presentation

    private struct StatusPresentation {
        let subtitle: String          // Line 1: "Indexing… 23%" / "Paused at 23%" / ...
        let entriesLine: String?      // Optional line 2: "40023 / 153888 entries"
        let subtitleColor: UIColor
        let trailingAccessories: [UICellAccessory]
    }

    /// Build the subtitle + trailing accessories for one dict cell.
    /// Resume / Retry buttons live in the cell (positive, encouraged
    /// actions). Pause is intentionally moved to a trailing swipe gesture
    /// — see `trailingSwipe(at:)` and `configureCollectionView`.
    ///
    /// Gate-pause (thermal / lowPower / memoryWarning) overrides the
    /// normal `.indexing` / `.notIndexed` rendering: when the dispatcher
    /// holds any `pauseReasons` AND the row is eligible (state in
    /// {.indexing, .notIndexed} AND enabled), the subtitle is replaced
    /// with "Paused (thermal, …)" so the user knows WHY their indexing
    /// stopped (the original bug: thermal pause was invisible to UX).
    private func statusPresentation(snap: ArticleIndexRecordSnapshot, dictId: String, enabled: Bool)
        -> StatusPresentation
    {
        let total = max(1, dictTotals[dictId] ?? 1)
        let pct = min(100, Int(Double(snap.indexedThrough) / Double(total) * 100))
        let inFlight = ArticleIndexDispatcher.shared.isInFlight(dictId)
        // Entries line shown whenever there's measurable progress to
        // display (any non-zero indexed-through, regardless of state).
        let entriesLine: String? = snap.indexedThrough > 0
            ? L10n.ArticleIndex.entriesProgress(snap.indexedThrough, total)
            : nil

        // Gate-pause overlay: when dispatcher is gate-blocked AND this row
        // would otherwise be eligible (indexing/notIndexed, enabled),
        // surface the gate reason instead of the normal subtitle. User-
        // paused rows (persisted `.paused`) keep their own subtitle —
        // user-pause is more specific than the global gate.
        //
        // Multiple gates can fire concurrently (e.g. thermal + Low Power).
        // `Dispatcher.primaryReason` picks the single most-actionable one
        // (Low Power > thermal > memory) so the subtitle stays concise.
        // Each PauseReason carries its own full sentence — terse noun
        // labels like "thermal" felt opaque.
        let isEligibleForGateOverride = enabled
            && (snap.state == .indexing || snap.state == .notIndexed)
        if isEligibleForGateOverride,
           let primary = ArticleIndexDispatcher.primaryReason(from: currentGatePauseReasons) {
            // `.downloadingModel` is intentionally NOT shown per-cell —
            // when the model is downloading, the whole VC switches to a
            // full-surface EmptyStateView overlay (see `updateModelOverlay()`)
            // so the user sees one clear "Downloading…" status instead
            // of N duplicated cells. Cells in this state render as
            // normal "queued" rows (the spinner just hasn't kicked in
            // yet because the encoder isn't loaded).
            guard primary != .downloadingModel else {
                return StatusPresentation(
                    subtitle: L10n.ArticleIndex.statusToBeIndexed,
                    entriesLine: entriesLine,
                    subtitleColor: .secondaryLabel,
                    trailingAccessories: [stateIconAccessory("clock.circle", color: .secondaryLabel)]
                )
            }
            return StatusPresentation(
                subtitle: primary.localizedLabel,
                entriesLine: entriesLine,
                subtitleColor: .secondaryLabel,
                trailingAccessories: [stateIconAccessory("pause.circle.fill", color: .systemOrange)]
            )
        }

        switch snap.state {
        case .indexed:
            return StatusPresentation(
                subtitle: L10n.ArticleIndex.statusIndexed,
                entriesLine: nil,  // 100% — redundant with "Indexed" badge
                subtitleColor: .secondaryLabel,
                trailingAccessories: [stateIconAccessory("checkmark.circle.fill", color: .systemGreen)]
            )

        case .indexing:
            // Pause action moved to trailing swipe (cfg.trailingSwipe
            // ActionsConfigurationProvider). No ⏸ button here — only the
            // spinner so we don't visually encourage a "stop the good
            // thing happening" tap.
            if inFlight && enabled {
                let spin = UIActivityIndicatorView(style: .medium)
                spin.startAnimating()
                return StatusPresentation(
                    subtitle: L10n.ArticleIndex.statusIndexing(pct),
                    entriesLine: entriesLine,
                    subtitleColor: .secondaryLabel,
                    trailingAccessories: [
                        .customView(configuration: .init(customView: spin, placement: .trailing(displayed: .always))),
                    ]
                )
            } else {
                // Orphan `.indexing` (no live job) — shouldn't happen post-
                // launch-time normalize, but defend with a passive render.
                return StatusPresentation(
                    subtitle: L10n.ArticleIndex.statusToBeIndexed,
                    entriesLine: entriesLine,
                    subtitleColor: .secondaryLabel,
                    trailingAccessories: [stateIconAccessory("clock.circle", color: .secondaryLabel)]
                )
            }

        case .paused:
            var accessories: [UICellAccessory] = []
            if enabled {
                // Primary-action blue (NOT green): green reads as
                // "completed/done" and would mislead users into thinking
                // this row is finished indexing. The system convention
                // for "the obvious next thing to tap" is .systemBlue.
                let resumeBtn = makeActionButton(
                    systemName: "play.circle.fill",
                    color: .systemBlue,
                    a11y: L10n.ArticleIndex.actionResume
                ) { [weak self] in
                    ArticleIndexCoordinator.shared.userResume(dictId)
                    self?.reconfigureDictRows()
                }
                accessories.append(.customView(configuration:
                    .init(customView: resumeBtn, placement: .trailing(displayed: .always))))
            } else {
                // Orange (NOT secondaryLabel gray) so the paused-with-
                // partial-progress state is visually attention-grabbing
                // in Disabled section — the user opted out but their
                // partial index is still here waiting to be resumed.
                // Matches the gate-pause icon's tint for consistency.
                accessories.append(stateIconAccessory("pause.circle.fill", color: .systemOrange))
            }
            return StatusPresentation(
                subtitle: L10n.ArticleIndex.statusPaused(pct),
                entriesLine: entriesLine,
                subtitleColor: .secondaryLabel,
                trailingAccessories: accessories
            )

        case .error:
            var accessories: [UICellAccessory] = []
            if enabled {
                let retryBtn = makeActionButton(
                    systemName: "arrow.clockwise.circle.fill",
                    color: .systemOrange,
                    a11y: L10n.ArticleIndex.actionRetry
                ) { [weak self] in
                    _ = ArticleIndexCoordinator.shared.userRequestIndex(dictId)
                    self?.reconfigureDictRows()
                }
                accessories.append(.customView(configuration:
                    .init(customView: retryBtn, placement: .trailing(displayed: .always))))
            } else {
                accessories.append(stateIconAccessory("exclamationmark.circle", color: .systemRed))
            }
            return StatusPresentation(
                subtitle: snap.errorMessage ?? L10n.ArticleIndex.statusError,
                entriesLine: entriesLine,
                subtitleColor: .systemRed,
                trailingAccessories: accessories
            )

        case .notIndexed:
            return StatusPresentation(
                subtitle: L10n.ArticleIndex.statusToBeIndexed,
                entriesLine: entriesLine,
                subtitleColor: .secondaryLabel,
                trailingAccessories: [stateIconAccessory("clock.circle", color: .secondaryLabel)]
            )
        }
    }

    /// Snapshot of `Dispatcher.pauseReasons` cached so cell renderer reads
    /// it synchronously. Updated by the subscribe() Combine pipeline.
    private var currentGatePauseReasons: Set<ArticleIndexDispatcher.PauseReason> = []

    // MARK: - Cell helper widgets

    private func stateIconAccessory(_ systemName: String, color: UIColor) -> UICellAccessory {
        let iv = UIImageView(image: UIImage(systemName: systemName))
        iv.tintColor = color
        return .customView(configuration: .init(customView: iv, placement: .trailing(displayed: .always)))
    }

    /// Tappable trailing action button (pause/resume/retry). UIKit
    /// doesn't propagate accessory touches to the cell's `didSelectItemAt`,
    /// so the button-tap stays independent of the row-tap (which toggles
    /// section membership). That's what lets us layer "tap = move section"
    /// and "button = state action" cleanly on the same cell.
    ///
    /// Layout note: `contentInsets` are deliberately non-zero. With
    /// `.zero`, the button's `intrinsicContentSize` matches the SF Symbol
    /// image's nominal size (e.g. 24×24 for a 24pt symbol) — but the
    /// rendered glyph of "filled circle" symbols like `play.circle.fill`
    /// extends a pixel or two beyond the nominal box, and
    /// `UICellAccessory.customView` lays out the button at exactly
    /// `intrinsicContentSize`, clipping that overshoot. The 4pt symmetric
    /// inset makes the button 32×32, giving the glyph slack on all sides.
    private func makeActionButton(
        systemName: String, color: UIColor, a11y: String, action: @escaping () -> Void
    ) -> UIButton {
        let btn = UIButton(type: .system)
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(
            systemName: systemName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        )
        cfg.baseForegroundColor = color
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        btn.configuration = cfg
        btn.accessibilityLabel = a11y
        btn.accessibilityTraits = .button
        btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return btn
    }

    // MARK: - Data

    private func reloadDicts() {
        let all = DictionaryService.shared.allDictionaries
        dictNames = Dictionary(all.map { ($0.id, $0.preferredTitle) }, uniquingKeysWith: { a, _ in a })
        dictTotals = Dictionary(all.map { ($0.id, $0.reader?.entryCount ?? 0) }, uniquingKeysWith: { a, _ in a })
        let orderedIds = orderedDictIds()
        var enabled: [String] = []
        var disabled: [String] = []
        for id in orderedIds {
            if ArticleIndexService.shared.snapshot(for: id).userExcluded {
                disabled.append(id)
            } else {
                enabled.append(id)
            }
        }
        enabledIds = enabled
        disabledIds = disabled
    }

    /// Default-group order (the canonical "all dictionaries" order),
    /// with any dict not in the group appended at the end. Defensive —
    /// the default group should always contain every loaded dict.
    private func orderedDictIds() -> [String] {
        let all = DictionaryService.shared.allDictionaries
        guard let group = DictionaryService.shared.defaultGroup else {
            return all.map(\.id)
        }
        var ids = group.dictionaryIds
        let inGroup = Set(ids)
        for d in all where !inGroup.contains(d.id) { ids.append(d.id) }
        return ids
    }

    private func applySnapshot(animated: Bool) {
        var snap = NSDiffableDataSourceSnapshot<AISection, AIItem>()
        snap.appendSections([.toggleMaster])
        snap.appendItems([.masterToggle], toSection: .toggleMaster)
        if UserDefaults.standard.articleSearchEnabled {
            // Result-count knob sits right under the switch, same section —
            // only meaningful once the feature is on.
            snap.appendItems([.resultsCount], toSection: .toggleMaster)
            snap.appendSections([.enabled])
            if enabledIds.isEmpty {
                snap.appendItems([.emptyEnabled], toSection: .enabled)
            } else {
                snap.appendItems(enabledIds.map { .dict(id: $0, enabled: true) }, toSection: .enabled)
            }
            snap.appendSections([.disabled])
            if disabledIds.isEmpty {
                // Two empty-Disabled cases:
                //  • Zero dicts in the WHOLE library → user deleted everything
                //    they imported (or hasn't imported any yet). The "All
                //    dictionaries are enabled" copy is wrong here; the user
                //    needs to import a dict first. Use `.emptyNoDicts`
                //    placeholder which points them at the management screen.
                //  • Zero disabled BUT some enabled → "All dictionaries are
                //    enabled" is correct. Use `.emptyDisabled`.
                let placeholder: AIItem = enabledIds.isEmpty ? .emptyNoDicts : .emptyDisabled
                snap.appendItems([placeholder], toSection: .disabled)
            } else {
                snap.appendItems(disabledIds.map { .dict(id: $0, enabled: false) }, toSection: .disabled)
            }
        }
        dataSource.apply(snap, animatingDifferences: animated)
    }

    private func subscribe() {
        // ArticleIndexService.$revision ticks on EVERY state mutation
        // (progress checkpoint, pause/resume/userExcluded). Reconfigure
        // existing cells in place — section partitioning is only
        // recomputed on user-driven section moves (didSelect).
        ArticleIndexService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconfigureDictRows() }
            .store(in: &cancellables)
        DictionaryService.shared.$allDictionaries
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadDicts()
                self?.applySnapshot(animated: true)
            }
            .store(in: &cancellables)
        // Gate-pause changes (thermal / Low Power / memory warning) don't
        // tick the service's revision — they're dispatcher-only transient
        // state. Subscribe directly so cell subtitles flip to "Paused
        // (thermal)" the moment a gate engages and back to "Indexing… N%"
        // the moment it clears. Initial value comes through too (no
        // `dropFirst`) because we want the cell to be correct from the
        // first render in case we launched into a hot device.
        ArticleIndexDispatcher.shared.$pauseReasons
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reasons in
                guard let self else { return }
                guard self.currentGatePauseReasons != reasons else { return }
                self.currentGatePauseReasons = reasons
                self.reconfigureDictRows()
                self.updateModelOverlay()
            }
            .store(in: &cancellables)
        // AssetProvider state machine — single source of truth for the
        // overlay. Transitions:
        //   .unknown → .acquiring(nil) → .acquiring(progress) → .ready
        //                            ↘ .failed(odr)
        //   .failed → (retry) → .unknown → .acquiring → …
        ArticleIndexAssetProvider.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                debugLog("ArticleIndexOverviewVC: provider state → \(state)")
                self.currentProviderState = state
                self.updateModelOverlay()
            }
            .store(in: &cancellables)
    }

    /// Cached `AssetProvider.$state`. Single source of truth for the
    /// overlay; replaces the previous trio (`modelLocallyAvailable` +
    /// `currentDownloadProgress` + `currentModelAcquireError`) which
    /// drifted independently and raced on relaunch.
    private var currentProviderState: ArticleIndexAssetProvider.State = .unknown

    // MARK: - Model overlay state machine

    /// Decide whether the EmptyStateView overlay should be visible and,
    /// if so, which presentation. Driven by `AssetProvider.$state`
    /// (single source of truth) + the master-toggle UserDefault.
    ///
    ///   master toggle off                              → hidden
    ///   provider .unknown                              → .loading (indeterminate)
    ///   provider .acquiring(nil)                       → .loading (indeterminate)
    ///   provider .acquiring(progress)                  → .loading (progress%)
    ///   provider .failed(odr)                          → .error(odr, retry)
    ///   provider .ready                                → hidden (cells show)
    private func updateModelOverlay() {
        let masterOn = UserDefaults.standard.articleSearchEnabled
        guard masterOn else {
            modelStatusView.isHidden = true
            return
        }

        switch currentProviderState {
        case .ready:
            modelStatusView.isHidden = true

        case .failed(let odr):
            modelStatusView.configure(.error(
                odr,
                retryTitle: L10n.ArticleIndex.modelOverlayRetry,
                retry: { ArticleIndexDispatcher.shared.retryModelAcquire() }
            ))
            modelStatusView.isHidden = false

        case .unknown:
            modelStatusView.configure(.loading(
                icon: "arrow.down.circle",
                title: L10n.ArticleIndex.modelOverlayDownloadingTitle,
                message: L10n.ArticleIndex.modelOverlayDownloadingMessageIndeterminate
            ))
            modelStatusView.isHidden = false

        case .acquiring(let progress):
            let message: String
            if let progress {
                message = L10n.ArticleIndex.modelOverlayDownloadingMessage(pct: Int(progress * 100))
            } else {
                message = L10n.ArticleIndex.modelOverlayDownloadingMessageIndeterminate
            }
            modelStatusView.configure(.loading(
                icon: "arrow.down.circle",
                title: L10n.ArticleIndex.modelOverlayDownloadingTitle,
                message: message
            ))
            modelStatusView.isHidden = false
        }
    }

    // MARK: - Trailing swipe (pause action)

    /// Provides the trailing-swipe Pause action for in-flight indexing
    /// rows in the Enabled section. By design, pause is moved
    /// from a visible in-cell button to a swipe gesture — we offer the
    /// capability but don't visually encourage frequent use.
    ///
    /// Excluded rows: Disabled section (the dict isn't running anyway),
    /// non-indexing rows (nothing to pause), in-flight=false (orphan or
    /// gate-paused, already not actively running).
    private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .dict(let id, let enabled) = item,
              enabled
        else { return nil }
        let snap = ArticleIndexService.shared.snapshot(for: id)
        guard snap.state == .indexing,
              ArticleIndexDispatcher.shared.isInFlight(id)
        else { return nil }
        let pause = UIContextualAction(
            style: .normal, title: L10n.ArticleIndex.actionPause
        ) { [weak self] _, _, done in
            ArticleIndexCoordinator.shared.userPause(id)
            self?.reconfigureDictRows()
            done(true)
        }
        pause.backgroundColor = .systemOrange
        pause.image = UIImage(systemName: "pause.circle.fill")
        return UISwipeActionsConfiguration(actions: [pause])
    }

    private func reconfigureDictRows() {
        var snap = dataSource.snapshot()
        let items = snap.itemIdentifiers.filter {
            if case .dict = $0 { return true } else { return false }
        }
        guard !items.isEmpty else { return }
        snap.reconfigureItems(items)
        dataSource.apply(snap, animatingDifferences: false)
    }

    // MARK: - Master toggle

    /// Present a confirmation alert before flipping the master toggle.
    /// On confirm, call `setMasterEnabled(desiredOn)`. On cancel, the
    /// completion is called with `confirmed: false` so the caller can
    /// snap the UISwitch back to its prior position.
    ///
    /// Two distinct copies:
    ///   - ON: warns about the ~80 MB ODR download + per-dict indexing
    ///   - OFF: warns about removing the model + every existing sidecar
    ///     (the indexed-dict count is interpolated so the user sees how
    ///     much work they're throwing away).
    private func confirmMasterToggle(desiredOn: Bool, completion: @escaping (Bool) -> Void) {
        let alert: UIAlertController
        if desiredOn {
            alert = UIAlertController(
                title: L10n.ArticleIndex.MasterToggle.enableTitle,
                message: L10n.ArticleIndex.MasterToggle.enableMessage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: L10n.ArticleIndex.MasterToggle.enableConfirm,
                style: .default,
                handler: { [weak self] _ in
                    self?.setMasterEnabled(true)
                    completion(true)
                }
            ))
            alert.addAction(UIAlertAction(
                title: L10n.ArticleIndex.MasterToggle.cancel,
                style: .cancel,
                handler: { _ in completion(false) }
            ))
        } else {
            let indexedCount = ArticleIndexService.shared.allSnapshots()
                .filter { $0.state == .indexed }
                .count
            alert = UIAlertController(
                title: L10n.ArticleIndex.MasterToggle.disableTitle,
                message: L10n.ArticleIndex.MasterToggle.disableMessage(indexedCount: indexedCount),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: L10n.ArticleIndex.MasterToggle.disableConfirm,
                style: .destructive,
                handler: { [weak self] _ in
                    self?.setMasterEnabled(false)
                    completion(true)
                }
            ))
            alert.addAction(UIAlertAction(
                title: L10n.ArticleIndex.MasterToggle.cancel,
                style: .cancel,
                handler: { _ in completion(false) }
            ))
        }
        present(alert, animated: true)
    }

    private func setMasterEnabled(_ on: Bool) {
        UserDefaults.standard.articleSearchEnabled = on
        // Narrow, app-private signal so WordListVC's scope bar reacts to
        // THIS toggle only — not to the global UserDefaults.didChange
        // firehose. See `Notification.Name.articleSearchMasterToggleDidChange`.
        NotificationCenter.default.post(
            name: .articleSearchMasterToggleDidChange, object: nil)
        if on {
            // Same as viewWillAppear: ensure the provider's state
            // machine kicks off (idempotent if already in flight or
            // ready), then backfill so per-dict jobs route through
            // the dispatcher.
            Task {
                debugLog("ArticleIndexOverviewVC.setMasterEnabled(true): ensureAcquired + backfillIfEnabled")
                await ArticleIndexAssetProvider.shared.ensureAcquired()
                ArticleIndexCoordinator.shared.backfillIfEnabled()
            }
        } else {
            debugLog("ArticleIndexOverviewVC.setMasterEnabled(false): cancelAll + tearDown")
            ArticleIndexDispatcher.shared.cancelAll()
            // Promised by the confirm-disable alert: wipe the on-disk
            // sidecars + drop in-memory state + release the ODR
            // reservation so iOS reclaims the ~80 MB model file.
            ArticleIndexCoordinator.shared.deleteAllSidecars()
            ArticleIndexAssetProvider.shared.release()
            // Drop the cached query encoder too, so its CoreML model memory
            // goes away with the ODR file (the article scope stops querying
            // the moment the toggle flips off).
            ArticleSearchService.shared.evictEncoder()
        }
        // Toggle drives overlay visibility — see updateModelOverlay()
        updateModelOverlay()
        applySnapshot(animated: true)
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }
}

// MARK: - UICollectionViewDelegate

extension ArticleIndexOverviewViewController: UICollectionViewDelegate {
    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        cv.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .dict(let id, let enabled):
            // Tap row body → toggle Enabled/Disabled section membership.
            // The pause/resume/retry trailing buttons handle their own
            // taps; UIKit doesn't propagate accessory taps to didSelect.
            ArticleIndexCoordinator.shared.setEnabled(!enabled, for: id)
            reloadDicts()
            applySnapshot(animated: true)
        case .masterToggle, .resultsCount, .emptyEnabled, .emptyDisabled, .emptyNoDicts:
            break  // master switch + results menu handle their own actions; empty rows inert
        }
    }
}
