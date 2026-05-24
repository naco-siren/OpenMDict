//
//  WordListViewController.swift
//  OpenMDict-iOS
//
//  Three-state word list (enhanced search UX):
//  - Idle: search bar not active — shows date-grouped lookup history
//  - Active + empty query: search bar focused — shows clipboard + history
//  - Active + query: search bar has text — shows search results (+ suggestions if few)
//
//  All search logic is handled by the reactive pipeline in SpellingLookupSession.
//  History data is fetched from LookupHistoryService.
//

import UIKit
import Combine
import OpenMDictKit

class WordListViewController: UIViewController {

    // MARK: - Display State

    /// Three-state display model replacing the old boolean `isSearching`.
    private enum DisplayState: Equatable {
        case idle                    // search bar not active
        case activeEmpty             // search bar focused, no text
        case activeWithQuery(String) // search bar focused, has text
    }

    // MARK: - Section Model

    fileprivate enum SectionType {
        case clipboard
        case history(String)         // title = date string ("Today", "Yesterday", …)
        case searchResults
        case relatedForms            // lemma-resolved related forms (inflections, base forms)
        // Two parallel "we couldn't return direct hits, here are some adjacent ideas"
        // sections, surfaced visually identically (same header copy, same row icon)
        // since they play the same role from the user's perspective — just sourced
        // from different algorithms behind the scenes. SectionType names describe
        // what the section IS; RowItem names describe what individual rows ARE.
        case spellingSuggestions     // Levenshtein-distance fuzzy fallback
        case semanticSuggestions     // NLEmbedding semantic neighbors (deduped to words; no dict tag)
    }

    private struct SectionData {
        let type: SectionType
        let rows: [RowItem]
    }

    private enum RowItem {
        case clipboardContent(String?)     // nil = clipboard empty → placeholder
        case historyRecord(HistoryItem)
        case searchResult(WordDisplayItem)
        case relatedForm(WordDisplayItem)  // lemma-derived result (tap opens article)
        case suggestion(String)
        case semanticCandidate(String)     // semantic neighbor; tap behavior depends on context
    }

    // MARK: - State

    /// When true, search controller activation is not required for display state
    /// transitions. Used in tutorial mode where WordListVC is embedded as a child
    /// and UISearchController cannot be naturally activated.
    var isTutorialMode = false

    /// Returns the frame of a section matching the given type, in the specified
    /// coordinate space. Used by the tutorial coaching mark for spotlighting.
    func sectionFrame(matching kind: TutorialSectionKind, in coordinateSpace: UIView) -> CGRect? {
        guard let idx = sections.firstIndex(where: { kind.matches($0.type) }) else { return nil }
        let rect = tableView.rect(forSection: idx)
        return tableView.convert(rect, to: coordinateSpace)
    }

    /// Returns the frame of the search bar in the specified coordinate space.
    func searchBarFrame(in coordinateSpace: UIView) -> CGRect? {
        guard let searchBar = navigationItem.searchController?.searchBar else { return nil }
        return searchBar.convert(searchBar.bounds, to: coordinateSpace)
    }

    /// Section kinds queryable from outside (tutorial use).
    enum TutorialSectionKind {
        case clipboard
        case searchResults
        case relatedForms
        case suggestions

        fileprivate func matches(_ type: SectionType) -> Bool {
            switch (self, type) {
            case (.clipboard, .clipboard): return true
            case (.searchResults, .searchResults): return true
            case (.relatedForms, .relatedForms): return true
            // Tutorial currently only runs against spelling-scope UX, so the
            // public `.suggestions` kind maps to the spelling variant.
            // (`.semanticSuggestions` isn't a tutorial target yet.)
            case (.suggestions, .spellingSuggestions): return true
            default: return false
            }
        }
    }

    var onWordSelected: ((WordDisplayItem) -> Void)?
    var onViewAllHistory: (() -> Void)?
    var onSearchActivated: (() -> Void)?
    var onSearchDeactivated: (() -> Void)?

    /// Per-scene active search session — the one currently driving table results.
    /// Externally (MainSplitVC / CompactTabBarController), this is the spelling
    /// session being injected. Internally, it's whichever scope is currently
    /// selected (SpellingLookupSession for `.spelling`, lazy SemanticLookupSession
    /// for `.semantic`).
    ///
    /// The setter treats external assignment as "this is the spelling session":
    /// it always updates `spellingSession`, and only re-routes the active session
    /// + subscriptions if the user is currently on the spelling scope. If they're
    /// on semantic, the new spelling session sits in the wings and takes over
    /// the next time scope flips back to spelling.
    var searchSession: (any LookupSessionProtocol)? {
        get { activeSession }
        set {
            spellingSession = newValue
            if currentScope == .spelling {
                setActiveSession(newValue)
            }
        }
    }

    /// Parent-injected spelling-scope session. Held strongly so we can swap
    /// back to it when the user flips out of semantic scope.
    private var spellingSession: (any LookupSessionProtocol)?

    /// Created lazily on first flip into `.semantic` scope. Reused across
    /// scope toggles so its query / context state survives.
    private var semanticSession: SemanticLookupSession?

    /// The session actually backing the publishers right now. Switches between
    /// `spellingSession` and `semanticSession` as the user toggles scope.
    private var activeSession: (any LookupSessionProtocol)?

    /// Currently selected scope. Always starts on `.spelling` per cold launch;
    /// see `SearchScope` doc for the rationale.
    private var currentScope: SearchScope = .spelling

    /// Swap the active session and rewire subscriptions. Idempotent if the
    /// session reference hasn't changed.
    private func setActiveSession(_ session: (any LookupSessionProtocol)?) {
        let old = activeSession
        activeSession = session
        guard session !== old, isViewLoaded else { return }
        resubscribeToSearchSession()
    }

    private var cancellables = Set<AnyCancellable>()
    /// Subscriptions tied to the current `searchSession`.  Separated from
    /// `cancellables` so they can be torn down when the session is replaced.
    private var searchCancellables = Set<AnyCancellable>()

    private var displayState: DisplayState = .idle
    private var sections: [SectionData] = []

    /// Current displayed words (bound to SpellingLookupSession.$results)
    private var displayedWords: [WordDisplayItem] = []

    /// Lemma-resolved related forms (bound to SpellingLookupSession.$lemmaResults)
    private var lemmaWords: [WordDisplayItem] = []

    /// Suggested words when search results are few (bound to SpellingLookupSession.$suggestions)
    private var suggestedWords: [String] = []

    /// Whether the full search pipeline has settled for the current query.
    /// When false + query non-empty + all results empty → show "Searching…" instead of "No results".
    private var isSearchSettled: Bool = true

    /// History records grouped by date
    private var historyGroups: [HistorySection] = []

    /// Clipboard text read once when search becomes active
    private var clipboardText: String?

    // MARK: - UI

    private lazy var searchController: UISearchController = {
        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
        sc.delegate = self
        sc.obscuresBackgroundDuringPresentation = false
        sc.searchBar.placeholder = L10n.WordList.searchPlaceholder
        // M15: scope bar swaps between spelling and semantic
        // (NLEmbedding) search. We own searchBar.delegate to receive scope
        // changes — UISearchController still handles text via searchResultsUpdater.
        sc.searchBar.delegate = self
        sc.searchBar.scopeButtonTitles = [
            L10n.WordList.searchScopeSpelling,
            L10n.WordList.searchScopeSemantic,
        ]
        sc.searchBar.selectedScopeButtonIndex = SearchScope.spelling.rawValue
        // Force scope bar visible at all times — on iOS 15 the default is
        // hidden (showsScopeBar = false); on iOS 16+ `automaticallyShowsScopeBar`
        // only reveals it once search is active. We want users to discover
        // the spelling↔semantic toggle without having to focus the field first,
        // so we set scopeBarActivation = .manual and pin showsScopeBar = true.
        sc.searchBar.showsScopeBar = true
        if #available(iOS 16.0, *) {
            sc.scopeBarActivation = .manual
        }
        return sc
    }()

    /// Search-bar scope segmented control. Index 0 = spelling (default),
    /// index 1 = semantic.
    ///
    /// **Not persisted across launches** — every cold start begins on `.spelling`
    /// scope. This is the canonical "neutral" state the rest of the app's
    /// initial-selection logic (default-group auto-pick, sidebar highlight,
    /// title view) is wired up against. Persisting scope across launches
    /// previously caused a subtle bug: on a launch where persisted scope was
    /// `.semantic`, the parent VC's initial `setContext(group: defaultGroup)`
    /// call would route through an `activeSession` that was nil until
    /// viewDidLoad finished lazily materializing the semantic session,
    /// silently dropping the context.
    ///
    /// Scope still survives within a session — toggling has effect — but the
    /// next cold start always lands back on spelling.
    fileprivate enum SearchScope: Int {
        case spelling = 0
        case semantic = 1
    }

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tv.keyboardDismissMode = .onDrag
        return tv
    }()

    // MARK: Empty State View (ContentUnavailableView-like, iOS 15+)

    private lazy var emptyStateView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true

        container.addSubview(emptyStateStack)
        NSLayoutConstraint.activate([
            emptyStateStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyStateStack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 40),
            emptyStateStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
        ])

        return container
    }()

    /// Spinner shown in place of the empty-state icon while the search pipeline
    /// is in flight. `hidesWhenStopped = true` so it disappears entirely when
    /// stopped, and `configureEmptyState` always stops it before resetting the
    /// icon — no separate cleanup path needed.
    private lazy var loadingSpinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .large)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.hidesWhenStopped = true
        s.color = .secondaryLabel
        return s
    }()

    private lazy var emptyStateStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            loadingSpinner, emptyStateIcon, emptyStateTitle, emptyStateMessage, emptyStateButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(12, after: emptyStateIcon)
        return stack
    }()

    private lazy var emptyStateIcon: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.tintColor = .secondaryLabel
        iv.contentMode = .scaleAspectFit
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40)
        return iv
    }()

    private lazy var emptyStateTitle: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()

    private lazy var emptyStateMessage: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 15, weight: .regular)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()

    private lazy var emptyStateButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
        b.addTarget(self, action: #selector(emptyStateButtonTapped), for: .touchUpInside)
        return b
    }()

    @objc private func emptyStateButtonTapped() {
        onViewAllHistory?()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        
        navigationItem.backButtonDisplayMode = .default
        navigationItem.backButtonTitle = L10n.WordList.backButtonTitle

        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        
        definesPresentationContext = true
        
        view.backgroundColor = .systemBackground
        view.addSubview(tableView)
        view.addSubview(emptyStateView)
        view.addInteraction(UIDropInteraction(delegate: self))
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Scope always starts on `.spelling` on cold launch (see SearchScope
        // docs), so `spellingSession` is the active session and the parent's
        // `setContext(group:)` from `applyInitialSelection` has already
        // landed on it. Subscribe straight to that.

        subscribeToSearchResults()
        subscribeToLemmaResults()
        subscribeToSuggestions()
        subscribeToSearchSettled()
        subscribeToHistoryChanges()
        loadHistory()
        if isTutorialMode { updateDisplayState() }
        rebuildSections()
        updateTitleView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Refresh clipboard when returning from a pushed VC (e.g. article detail)
        // so it picks up text the user may have copied in the WebView.
        // iOS 16+: always shows placeholder, no refresh needed.
        if #unavailable(iOS 16.0), case .activeEmpty = displayState {
            refreshClipboard()
            rebuildSections()
        }
    }

    // MARK: - Display State Management

    private func updateDisplayState() {
        let isActive = isTutorialMode || searchController.isActive
        let query = (searchController.searchBar.text ?? "")
            .trimmingCharacters(in: .whitespaces)

        let newState: DisplayState
        if !isActive {
            newState = .idle
        } else if query.isEmpty {
            newState = .activeEmpty
        } else {
            newState = .activeWithQuery(query)
        }

        guard newState != displayState else { return }
        displayState = newState
        rebuildSections()
    }

    // MARK: - Section Assembly

    /// Rebuild `sections` from backing stores and reload the table view.
    /// This is the terminal convergence point for all reactive signals.
    private func rebuildSections() {
        var newSections: [SectionData] = []

        switch displayState {
        case .idle:
            // History only (date-grouped)
            for group in historyGroups {
                newSections.append(SectionData(
                    type: .history(group.title),
                    rows: group.records.map { .historyRecord($0) }
                ))
            }

        case .activeEmpty:
            // Clipboard
            if isTutorialMode {
                // Tutorial: always show clipboard with fake text
                newSections.append(SectionData(
                    type: .clipboard,
                    rows: [.clipboardContent("ephemeral")]
                ))
            } else if #available(iOS 16.0, *) {
                // Always show actionable placeholder (reads clipboard on tap)
                newSections.append(SectionData(
                    type: .clipboard,
                    rows: [.clipboardContent(nil)]
                ))
            } else if let clipboardText {
                // iOS 15: only show when clipboard has valid text
                newSections.append(SectionData(
                    type: .clipboard,
                    rows: [.clipboardContent(clipboardText)]
                ))
            }
            // History
            for group in historyGroups {
                newSections.append(SectionData(
                    type: .history(group.title),
                    rows: group.records.map { .historyRecord($0) }
                ))
            }

        case .activeWithQuery:
            // Semantic scope: candidate words (deduped, no per-dict rows) PLUS
            // optionally a spelling-suggestions section if the SemanticLookup
            // Session decided the query looked like a typo (few matches / low
            // top similarity) and fired the Levenshtein fuzzy fallback.
            // `displayedWords` here is the session's `results` — each entry's
            // `.word` is the candidate; dictId/dictName are intentionally empty
            // (the candidate isn't tied to one dict — tap routes via context,
            // see didSelectRowAt).
            //
            // Spelling scope: the existing three-section layout (results +
            // lemma-related forms + fuzzy suggestions). Each result row
            // shows its source dict.
            switch currentScope {
            case .semantic:
                if !displayedWords.isEmpty {
                    newSections.append(SectionData(
                        type: .semanticSuggestions,
                        rows: displayedWords.map { .semanticCandidate($0.word) }
                    ))
                }
                // Same `.spellingSuggestions` rendering as spelling scope —
                // visually consistent, taps still go through the existing
                // `.suggestion` handler (injectSearchText).
                if !suggestedWords.isEmpty {
                    newSections.append(SectionData(
                        type: .spellingSuggestions,
                        rows: suggestedWords.map { .suggestion($0) }
                    ))
                }
            case .spelling:
                if !displayedWords.isEmpty {
                    newSections.append(SectionData(
                        type: .searchResults,
                        rows: displayedWords.map { .searchResult($0) }
                    ))
                }
                if !lemmaWords.isEmpty {
                    newSections.append(SectionData(
                        type: .relatedForms,
                        rows: lemmaWords.map { .relatedForm($0) }
                    ))
                }
                if !suggestedWords.isEmpty {
                    newSections.append(SectionData(
                        type: .spellingSuggestions,
                        rows: suggestedWords.map { .suggestion($0) }
                    ))
                }
            }
        }

        sections = newSections
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: - Reactive Binding

    /// Cancel existing search subscriptions and re-subscribe to the new active
    /// session. Then synchronously pull the new session's current state into
    /// the VC's local arrays — the publisher sinks above will deliver the
    /// initial @Published values asynchronously (next runloop tick) and we
    /// don't want a brief flicker of stale prior-session state in between.
    private func resubscribeToSearchSession() {
        searchCancellables.removeAll()
        subscribeToSearchResults()
        subscribeToLemmaResults()
        subscribeToSuggestions()
        subscribeToSearchSettled()
        snapshotActiveSessionState()
    }

    /// Synchronously mirror the active session's published state into the
    /// VC's local arrays. Used right after swapping `activeSession` to
    /// avoid a one-runloop-tick gap during which the table would still
    /// reflect the previous session's contents. Idempotent — the publisher
    /// sinks will overwrite with the same values on the next tick.
    private func snapshotActiveSessionState() {
        guard let s = activeSession else { return }
        displayedWords = s.results
        lemmaWords     = s.lemmaResults
        suggestedWords = s.suggestions
        isSearchSettled = s.isSearchSettled
        rebuildSections()
        updateEmptyState()
    }

    /// Clear search bar and reset to idle state.  Called during compact ↔ regular
    /// layout transitions — transferring mid-search state across UISearchControllers
    /// is unreliable (activation requires view hierarchy), so we simply reset.
    func resetSearchState() {
        searchController.searchBar.text = nil
        if searchController.isActive {
            searchController.isActive = false
        }
        searchSession?.clearSearch()
        displayedWords = []
        lemmaWords = []
        suggestedWords = []
        isSearchSettled = true
        displayState = .idle
        rebuildSections()
    }

    private func subscribeToSearchResults() {
        searchSession?.resultsPublisher
            // .dropFirst() removed — experimentally, to see whether the
            // initial @Published emission causes UI flicker / unwanted
            // rebuilds. The original reason for the drop is not documented;
            // we want the initial emit so that swapping sessions surfaces
            // the new session's existing state. Re-evaluate after dogfood.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] results in
                guard let self else { return }
                self.displayedWords = results
                self.rebuildSections()
            }
            .store(in: &searchCancellables)
    }

    private func subscribeToLemmaResults() {
        searchSession?.lemmaResultsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] results in
                guard let self else { return }
                self.lemmaWords = results
                self.rebuildSections()
            }
            .store(in: &searchCancellables)
    }

    private func subscribeToSuggestions() {
        searchSession?.suggestionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suggestions in
                guard let self else { return }
                self.suggestedWords = suggestions
                self.rebuildSections()
            }
            .store(in: &searchCancellables)
    }

    private func subscribeToSearchSettled() {
        searchSession?.isSearchSettledPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settled in
                guard let self else { return }
                self.isSearchSettled = settled
                // Only update overlay — no need to rebuild table data
                self.updateEmptyState()
            }
            .store(in: &searchCancellables)
    }

    private func subscribeToHistoryChanges() {
        LookupHistoryService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadHistory()
            }
            .store(in: &cancellables)

        // React to dictionary metadata changes (e.g., dict renamed locally or on another device)
        DictMetadataService.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadHistory()
            }
            .store(in: &cancellables)

        // React to group/dict display name changes (local rename or iCloud sync)
        DictionaryService.shared.$displayNameRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateTitleView()
            }
            .store(in: &cancellables)
    }

    // MARK: - History Data

    /// Lookup context tuple derived from current search context.
    /// Exactly one of the two values is non-nil.
    private var lookupContext: (dictId: String?, groupId: String?)? {
        guard let context = searchSession?.currentContext else { return nil }
        switch context {
        case .group(let group):
            return (nil, group.id)
        case .dictionary(let dict):
            return (dict.id, nil)
        case .none:
            return nil
        }
    }

    private func loadHistory() {
        if isTutorialMode {
            loadTutorialHistory()
            return
        }
        let ctx = lookupContext
        let rawGroups = LookupHistoryService.shared.groupedHistory(
            lookupContextDictId: ctx?.dictId, lookupContextGroupId: ctx?.groupId
        )
        // Resolve dictName from DictMetadataService (authoritative).
        // Filter out records whose dictionary is not locally available — these
        // are synced from another device but the dict hasn't been downloaded yet.
        // They remain visible in the dedicated LookupHistoryListViewController
        // (with "dictionary unavailable" styling) but should not clutter the
        // group/dict WordListVC which only shows actionable history.
        let groups: [HistorySection] = rawGroups.compactMap { section in
            let filtered = section.records.compactMap { item -> HistoryItem? in
                guard let metadata = DictMetadataService.shared.find(dictId: item.dictId) else {
                    return nil  // dict not available locally — skip
                }
                return HistoryItem(
                    objectID: item.objectID,
                    word: item.word,
                    dictId: item.dictId,
                    dictName: metadata.displayName,
                    isDictAvailable: true,
                    lastLookedUpAt: item.lastLookedUpAt
                )
            }
            guard !filtered.isEmpty else { return nil }  // drop empty sections
            return HistorySection(title: section.title, records: filtered)
        }

        historyGroups = groups
        rebuildSections()
    }

    private func loadTutorialHistory() {
        let sampleAId = "__tutorial_sample_a__"
        let sampleBId = "__tutorial_sample_b__"
        let sampleCId = "__tutorial_sample_c__"
        let sampleDId = "__tutorial_sample_d__"
        let wordnetId = "__tutorial_wordnet__"

        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        historyGroups = [
            HistorySection(title: L10n.HistorySection.today, records: [
                HistoryItem(objectID: nil, word: "never", dictId: sampleAId,
                            dictName: "Sample Dictionary A", isDictAvailable: true,
                            lastLookedUpAt: today),
                HistoryItem(objectID: nil, word: "gonna", dictId: sampleBId,
                            dictName: "Sample Dictionary B", isDictAvailable: true,
                            lastLookedUpAt: today),
            ]),
            HistorySection(title: L10n.HistorySection.yesterday, records: [
                HistoryItem(objectID: nil, word: "make", dictId: sampleCId,
                            dictName: "Sample Dictionary C", isDictAvailable: true,
                            lastLookedUpAt: yesterday),
                HistoryItem(objectID: nil, word: "you", dictId: sampleDId,
                            dictName: "Sample Dictionary D", isDictAvailable: true,
                            lastLookedUpAt: yesterday),
                HistoryItem(objectID: nil, word: "cry", dictId: wordnetId,
                            dictName: "WordNet", isDictAvailable: true,
                            lastLookedUpAt: yesterday),
            ]),
        ]
        rebuildSections()
    }

    // MARK: - Clipboard

    private func refreshClipboard() {
        if #available(iOS 16.0, *) {
            // Don't read clipboard upfront — avoids system paste permission alert.
            // Clipboard section shows actionable placeholder; actual read happens on tap.
            clipboardText = nil
        } else {
            // iOS 15: Read clipboard directly (no system alert).
            // Only show if text is reasonable for a dictionary lookup.
            let text = UIPasteboard.general.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty,
               text.count <= 50,
               text.components(separatedBy: .whitespaces).filter({ !$0.isEmpty }).count <= 10 {
                clipboardText = text
            } else {
                clipboardText = nil
            }
        }
    }

    /// Synchronously update displayed data from the current search session.
    /// Bypasses the Combine pipeline's async `.receive(on: .main)` delivery.
    /// Used in tutorial mode where mock data must be visible immediately
    /// before the coaching mark resolves spotlight frames.
    func syncFromSession() {
        guard let session = searchSession else { return }
        displayedWords = session.results
        lemmaWords = session.lemmaResults
        suggestedWords = session.suggestions
        isSearchSettled = session.isSearchSettled
        updateDisplayState()
        rebuildSections()
    }

    /// Inject text into the search bar, triggering the reactive search pipeline.
    /// Public in tutorial mode; called internally for clipboard paste.
    func injectSearchText(_ text: String) {
        searchController.searchBar.text = text
        searchController.searchBar.delegate?.searchBar?(
            searchController.searchBar, textDidChange: text
        )
    }

    // MARK: - Context Setting (called by MainSplitVC)

    func loadWords(for group: MDicts) {
        // Push to BOTH sessions, not just `searchSession` (= active session).
        // If we only updated the active one, a later scope flip would surface
        // the OTHER session with a stale context (e.g. user changes dict in
        // sidebar while on the semantic scope, then flips back to spelling —
        // spelling session would still be pointed at the previous dict).
        // Keeping the two in lock-step is cheaper than chasing every edge.
        spellingSession?.setContext(group: group)
        semanticSession?.setContext(group: group)
        loadHistory()  // Reload history filtered by new context
        updateTitleView()
    }

    func loadWords(for dict: MDict) {
        spellingSession?.setContext(dict: dict)
        semanticSession?.setContext(dict: dict)
        loadHistory()  // Reload history filtered by new context
        updateTitleView()
    }

    /// Activate the search bar and show keyboard (called from keyboard shortcut ⌘L)
    func focusSearchBar() {
        searchController.isActive = true
        searchController.searchBar.becomeFirstResponder()
    }

    /// Activate the search bar, inject initial text, and trigger search update.
    /// Used by pressesBegan auto-focus to forward the first typed character.
    func focusSearchBar(withInitialText text: String) {
        searchController.isActive = true
        searchController.searchBar.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in
            self?.injectSearchText(text)
        }
    }

    /// Whether the search bar currently has keyboard focus
    var isSearchBarFirstResponder: Bool {
        searchController.searchBar.isFirstResponder
    }

    /// Whether the search controller is active (bar visible, not necessarily first responder)
    var isSearchBarActive: Bool {
        searchController.isActive
    }

    /// Whether the search bar contains non-empty text
    var hasSearchText: Bool {
        !(searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Deactivate the search bar (used by Esc smart dismiss)
    func dismissSearchBar() {
        searchController.isActive = false
    }

    /// Re-focus the search bar without changing isActive (avoids delegate re-fire).
    /// Used when keyboard focus returns from another search bar.
    func refocusSearchBar() {
        searchController.searchBar.becomeFirstResponder()
    }

    // MARK: - UI Updates

    private func updateEmptyState() {
        // In tutorial mode, never show empty state — the mock session drives content
        if isTutorialMode {
            emptyStateView.isHidden = true
            tableView.isHidden = false
            return
        }

        switch displayState {
        case .idle:
            let context = searchSession?.currentContext ?? .none
            if case .none = context {
                // No context selected — prompt user to pick a source
                configureEmptyState(
                    icon: "text.book.closed",
                    title: L10n.WordList.selectDictionaryOrGroup,
                    message: nil,
                    buttonTitle: nil
                )
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else if historyGroups.isEmpty {
                // Context selected but no history in this source
                configureEmptyState(
                    icon: "clock",
                    title: L10n.WordList.noHistoryInSource(contextDisplayName(for: context)),
                    message: L10n.WordList.noHistoryInContextMessage,
                    buttonTitle: L10n.WordList.viewAllHistory
                )
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else {
                emptyStateView.isHidden = true
                tableView.isHidden = false
            }

        case .activeEmpty:
            if sections.isEmpty {
                // No clipboard and no history — show placeholder
                let context = searchSession?.currentContext ?? .none
                configureEmptyState(
                    icon: "clock",
                    title: L10n.WordList.noHistoryInSource(contextDisplayName(for: context)),
                    message: L10n.WordList.noHistoryInContextMessage,
                    buttonTitle: L10n.WordList.viewAllHistory
                )
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else {
                emptyStateView.isHidden = true
                tableView.isHidden = false
            }

        case .activeWithQuery:
            let context = searchSession?.currentContext ?? .none
            if case .none = context {
                configureEmptyState(
                    icon: "text.book.closed",
                    title: L10n.WordList.selectDictionaryOrGroup,
                    message: nil,
                    buttonTitle: nil
                )
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else if displayedWords.isEmpty && lemmaWords.isEmpty && suggestedWords.isEmpty {
                if !isSearchSettled {
                    // Pipeline still running — show searching indicator with
                    // an animated spinner so the placeholder doesn't look frozen
                    // during the multi-second first semantic preload (or any
                    // slower spelling pipeline phase).
                    configureSearchingState(title: L10n.WordList.searching)
                } else {
                    // All pipelines settled with no results
                    let noResultsIcon: String
                    if #available(iOS 16.0, *) {
                        noResultsIcon = "info.bubble"
                    } else {
                        noResultsIcon = "info.circle"
                    }
                    configureEmptyState(
                        icon: noResultsIcon,
                        title: L10n.WordList.noResults(
                            query: searchController.searchBar.text ?? ""),
                        message: nil,
                        buttonTitle: nil
                    )
                }
                emptyStateView.isHidden = false
                tableView.isHidden = true
            } else {
                emptyStateView.isHidden = true
                tableView.isHidden = false
            }
        }
    }

    /// Configure the empty state view with the given content.
    /// Pass `nil` for `message` or `buttonTitle` to hide those elements.
    /// Stops the loading spinner (if running) and restores the symbol icon —
    /// the spinner-mode counterpart is `configureSearchingState()`.
    private func configureEmptyState(
        icon: String,
        title: String,
        message: String?,
        buttonTitle: String?
    ) {
        loadingSpinner.stopAnimating()       // no-op if not running
        emptyStateIcon.isHidden = false
        emptyStateIcon.image = UIImage(systemName: icon)
        emptyStateTitle.text = title
        emptyStateMessage.text = message
        emptyStateMessage.isHidden = (message == nil)
        emptyStateButton.setTitle(buttonTitle, for: .normal)
        emptyStateButton.isHidden = (buttonTitle == nil)
    }

    /// Configure the empty state view as a "searching" indicator: spinner in
    /// place of the icon + searching title, no message or button. Used in
    /// both spelling and semantic scopes whenever the pipeline isn't settled
    /// — the rest of the empty-state cases route through `configureEmpty
    /// State` which will stop the spinner and put the icon back.
    private func configureSearchingState(title: String) {
        loadingSpinner.startAnimating()
        emptyStateIcon.isHidden = true
        emptyStateTitle.text = title
        emptyStateMessage.text = nil
        emptyStateMessage.isHidden = true
        emptyStateButton.setTitle(nil, for: .normal)
        emptyStateButton.isHidden = true
    }

    /// Human-readable name for the current search context (group or dictionary).
    private func contextDisplayName(for context: SearchContext) -> String {
        switch context {
        case .group(let g):      return g.name
        case .dictionary(let d): return d.preferredTitle
        case .none:              return ""
        }
    }

    private func updateTitleView() {
        let context = searchSession?.currentContext ?? .none
        let iconName: String
        let titleText: String

        switch context {
        case .group(let group):
            iconName = group.isDefault ? "books.vertical.fill" : "folder"
            titleText = group.name
        case .dictionary(let dict):
            iconName = "book.fill"
            titleText = dict.preferredTitle
        case .none:
            title = nil
            navigationItem.title = nil
            navigationItem.titleView = nil
            // Do NOT clear leftBarButtonItem here — in compact tab mode it
            // holds the sidebar toggle button set by CompactTabBarController.
            return
        }

        // Static titleView (icon + label).
        // In compact tab mode, leftBarButtonItem is set externally by CompactTabBarController.
        let imageView = UIImageView(image: UIImage(systemName: iconName))
        imageView.tintColor = .label
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = titleText
        label.font = .systemFont(ofSize: 17, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center

        navigationItem.title = nil
        navigationItem.titleView = stack
        navigationItem.backButtonTitle = titleText
    }

}

// MARK: - UITableViewDataSource

extension WordListViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard section < sections.count else { return 0 }
        return sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section < sections.count else { return nil }
        switch sections[section].type {
        case .clipboard:       return L10n.WordList.clipboardHeader
        case .history(let t):  return t
        case .searchResults:        return L10n.WordList.searchResultsHeader
        case .relatedForms:         return L10n.WordList.relatedFormsHeader
        // Distinct headers because in semantic scope BOTH sections may
        // appear simultaneously (semantic candidates + Levenshtein-fuzzy
        // fallback when the query looks like a typo). Sharing one
        // "Suggestions" label was ambiguous to the user.
        case .spellingSuggestions:  return L10n.WordList.spellingSuggestionsHeader
        case .semanticSuggestions:  return L10n.WordList.semanticSuggestionsHeader
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var c = cell.defaultContentConfiguration()

        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else {
            cell.contentConfiguration = c
            return cell
        }

        let row = sections[indexPath.section].rows[indexPath.row]

        switch row {
        case .clipboardContent(let text):
            c.image = UIImage(systemName: "doc.on.clipboard")
            if let text {
                // iOS 15: show actual clipboard text + "Paste to search"
                c.imageProperties.tintColor = .secondaryLabel
                let truncated = text.count > 60
                    ? String(text.prefix(60)) + "\u{2026}"
                    : text
                c.text = truncated
                c.secondaryText = L10n.WordList.clipboardPasteToSearch
                c.secondaryTextProperties.color = .secondaryLabel
            } else if #available(iOS 16.0, *) {
                // iOS 16+: actionable placeholder — tapping triggers paste alert
                c.imageProperties.tintColor = .tintColor
                c.text = L10n.WordList.clipboardPasteFromClipboard
                c.textProperties.color = .tintColor
            } else {
                // iOS 15: empty clipboard — non-interactive placeholder
                c.imageProperties.tintColor = .secondaryLabel
                c.text = L10n.WordList.clipboardEmpty
                c.textProperties.color = .tertiaryLabel
            }

        case .historyRecord(let record):
            c.text = record.word
            c.image = UIImage(systemName: "clock")
            c.imageProperties.tintColor = .secondaryLabel
            // Show dict name unless the context is a single dictionary
            if case .dictionary = searchSession?.currentContext {
                // Single-dict context: all records are from the same dict, skip dictName
            } else {
                c.secondaryText = record.dictName
                c.secondaryTextProperties.color = .secondaryLabel
            }

        case .searchResult(let wordItem):
            c.text = wordItem.word
            if #available(iOS 18.0, *) {
                c.image = UIImage(systemName: "richtext.page")
            } else {
                c.image = UIImage(systemName: "menucard")
            }
            c.imageProperties.tintColor = .secondaryLabel
            // Show dictionary name as secondary text when displaying a group
            if case .group = searchSession?.currentContext {
                c.secondaryText = wordItem.dictName
                c.secondaryTextProperties.color = .secondaryLabel
            }

        case .relatedForm(let wordItem):
            c.text = wordItem.word
            if #available(iOS 18.0, *) {
                c.image = UIImage(systemName: "richtext.page")
            } else {
                c.image = UIImage(systemName: "menucard")
            }
            c.imageProperties.tintColor = .secondaryLabel
            // Show dictionary name as secondary text when displaying a group
            if case .group = searchSession?.currentContext {
                c.secondaryText = wordItem.dictName
                c.secondaryTextProperties.color = .secondaryLabel
            }

        case .suggestion(let word):
            c.text = word
            if #available(iOS 18.0, *) {
                c.image = UIImage(systemName: "questionmark.text.page")
            } else {
                c.image = UIImage(systemName: "lightbulb")
            }
            c.imageProperties.tintColor = .secondaryLabel

        case .semanticCandidate(let word):
            c.text = word
            // Mirror the `.suggestion` icon: visually unified with spelling
            // suggestions since they're presented as parallel ideas to the user.
            if #available(iOS 18.0, *) {
                c.image = UIImage(systemName: "questionmark.text.page")
            } else {
                c.image = UIImage(systemName: "lightbulb")
            }
            c.imageProperties.tintColor = .secondaryLabel
        }

        cell.contentConfiguration = c
        return cell
    }

    // Swipe-to-delete (history mode only)

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else { return false }
        if case .historyRecord = sections[indexPath.section].rows[indexPath.row] {
            return true
        }
        return false
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete,
              indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else { return }
        if case .historyRecord(let record) = sections[indexPath.section].rows[indexPath.row] {
            guard let objectID = record.objectID else { return }
            LookupHistoryService.shared.deleteRecord(objectID: objectID)
            // loadHistory() will be triggered via $revision subscription
        }
    }
}

// MARK: - UITableViewDelegate

extension WordListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else { return }

        let row = sections[indexPath.section].rows[indexPath.row]

        switch row {
        case .clipboardContent(let text):
            if let text {
                injectSearchText(text)
            } else if #available(iOS 16.0, *) {
                // Read clipboard on demand — triggers system paste alert
                if let pastedText = UIPasteboard.general.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !pastedText.isEmpty {
                    injectSearchText(pastedText)
                }
            }

        case .historyRecord(let record):
            let wordItem = WordDisplayItem(
                word: record.word,
                dictId: record.dictId,
                dictName: record.dictName
            )
            onWordSelected?(wordItem)

        case .searchResult(let wordItem):
            onWordSelected?(wordItem)

        case .relatedForm(let wordItem):
            onWordSelected?(wordItem)

        case .suggestion(let word):
            injectSearchText(word)

        case .semanticCandidate(let word):
            // Tap behavior is context-aware:
            //   - Single-dict context → open the article directly in that dict.
            //     The candidate isn't tied to a specific dict (the service
            //     produces a deduped word-only list), so we use the current
            //     context's dict for navigation.
            //   - Group context → atomically flip to spelling + seed the
            //     spelling session with the chosen word. The semantic session
            //     keeps its own (query, results) so flipping back to semantic
            //     restores the exploration state without re-running the
            //     compute. The spelling pipeline then surfaces the word's
            //     per-dict results just like a normal lookup.
            switch searchSession?.currentContext ?? .none {
            case .dictionary(let dict):
                onWordSelected?(WordDisplayItem(
                    word: word,
                    dictId: dict.id,
                    dictName: dict.preferredTitle
                ))
            case .group:
                setScope(.spelling, query: word)
            case .none:
                // No context to route against — best-effort fallback.
                injectSearchText(word)
            }
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].rows.count else { return nil }

        // Context menu for search result, related form, and history rows
        let word: WordDisplayItem
        switch sections[indexPath.section].rows[indexPath.row] {
        case .searchResult(let w): word = w
        case .relatedForm(let w):  word = w
        case .historyRecord(let record):
            word = WordDisplayItem(word: record.word, dictId: record.dictId, dictName: record.dictName)
        default: return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }

            // Create article - try to load if dictionary is ready
            let dict = DictionaryService.shared.dict(id: word.dictId)
            var article = ArticleDisplayItem(
                word: word.word,
                dictId: word.dictId,
                dictName: word.dictName,
                contentState: .pending
            )
            if let dict = dict, let entry = dict.lookup(word.word) {
                article.contentState = .loaded(html: entry.article.html, css: nil)
            }

            var actions: [UIAction] = [
                UIAction(title: L10n.Articles.open, image: UIImage(systemName: "doc.text")) { _ in
                    self.onWordSelected?(word)
                },
            ]
            if UIApplication.shared.supportsMultipleScenes {
                actions.append(UIAction(title: L10n.Articles.openInNewWindow, image: UIImage(systemName: "square.split.2x1")) { [weak self] _ in
                    let session = self?.view.window?.windowScene?.session
                    SceneDelegate.openNewWindow(for: article, sourceSession: session)
                })
            }
            return UIMenu(children: actions)
        }
    }
}

// MARK: - UISearchResultsUpdating

extension WordListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        // Just update the query - reactive pipeline handles the rest!
        searchSession?.updateQuery(query)
        updateDisplayState()
    }
}

// MARK: - UISearchControllerDelegate

extension WordListViewController: UISearchControllerDelegate {
    func willPresentSearchController(_ searchController: UISearchController) {
        refreshClipboard()
        updateDisplayState()
        onSearchActivated?()
    }

    func willDismissSearchController(_ searchController: UISearchController) {
        clipboardText = nil
        updateDisplayState()
        onSearchDeactivated?()
    }
}

// MARK: - UISearchBarDelegate (scope segmented control)

extension WordListViewController: UISearchBarDelegate {
    /// Called whenever the user taps a different scope button. We swap
    /// between the parent-injected spelling session and our internally-owned
    /// SemanticLookupSession; the publisher subscriptions rewire via
    /// `setActiveSession` → `resubscribeToSearchSession`, and we re-feed the
    /// current query into the new session so the user sees fresh results
    /// for the same text under the new scope.
    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
        guard let scope = SearchScope(rawValue: selectedScope) else { return }
        setScope(scope)
    }
}

extension WordListViewController {
    /// Programmatic scope change. Called by `selectedScopeButtonIndexDidChange`
    /// on user toggle, and by the semantic-candidate tap handler (with an
    /// explicit `query` override).
    ///
    /// Data flow: **view follows model**. We never force the active session's
    /// query to match the search bar on flip; instead we mirror the new active
    /// session's `currentQuery` into the search bar. Each session keeps its
    /// own `(query, results, …)` state independently, so flipping back and
    /// forth surfaces each scope's last state without re-running the pipeline
    /// (sessions' `updateQuery` is idempotent on same-value).
    ///
    /// `overrideQuery` is for the semantic-candidate tap path: it lets the
    /// caller atomically (a) flip to the spelling scope and (b) seed it with
    /// the chosen candidate, without going through the search-bar setter
    /// twice.
    fileprivate func setScope(_ scope: SearchScope, query overrideQuery: String? = nil) {
        guard scope != currentScope || overrideQuery != nil else { return }
        let prevActive = activeSession
        currentScope = scope
        // Keep the segmented control in sync — setting it programmatically
        // does NOT call the delegate, so no recursion risk.
        searchController.searchBar.selectedScopeButtonIndex = scope.rawValue

        switch scope {
        case .spelling:
            setActiveSession(spellingSession)
        case .semantic:
            // First-ever flip into semantic: inherit BOTH context and query
            // from the currently-active session (typically spelling). Done
            // once at creation; after this each session owns its own query
            // independently. `loadWords` keeps context in lock-step across
            // both, so we don't need to re-sync context here.
            if semanticSession == nil {
                let new = SemanticLookupSession()
                if let prev = prevActive {
                    new.setContext(prev.currentContext)
                    new.updateQuery(prev.currentQuery)
                }
                semanticSession = new
            }
            setActiveSession(semanticSession)
        }

        // Explicit query injection — used by the candidate-tap path to seed
        // the spelling session with the chosen candidate before surfacing it.
        // Idempotent on same-value (see SpellingLookupSession.updateQuery).
        if let overrideQuery {
            activeSession?.updateQuery(overrideQuery)
            // We just kicked off a re-search with the override. The snapshot
            // inside resubscribeToSearchSession already populated displayed
            // Words / lemmaWords / suggestedWords with the new active
            // session's PRE-override results (or its cached results from a
            // prior unrelated query). Clear them so the pipeline's incoming
            // emissions for the override query land on a clean canvas
            // instead of flickering through stale rows.
            displayedWords = []
            lemmaWords = []
            suggestedWords = []
            isSearchSettled = false   // pipeline is in flight
        }

        // View follows model: mirror the active session's current query into
        // the search bar. Triggers UISearchResultsUpdating → updateQuery,
        // which is a no-op when the value already matches (idempotent guard).
        searchController.searchBar.text = activeSession?.currentQuery

        updateDisplayState()
        // snapshotActiveSessionState already ran inside resubscribeToSearch
        // Session via setActiveSession, so displayedWords / lemmaWords /
        // suggestedWords already reflect the new active session. We still
        // rebuild sections here for the scope-dependent section layout.
        rebuildSections()
    }
}

// MARK: - UIDropInteractionDelegate (iPad text drag → look up)

extension WordListViewController: UIDropInteractionDelegate {

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: NSString.self)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        session.loadObjects(ofClass: NSString.self) { [weak self] items in
            guard let text = (items.first as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            self?.focusSearchBar(withInitialText: text)
        }
    }
}
