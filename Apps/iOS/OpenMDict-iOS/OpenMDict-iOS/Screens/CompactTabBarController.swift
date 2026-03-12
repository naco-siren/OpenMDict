//
//  CompactTabBarController.swift
//  OpenMDict-iOS
//
//  UITabBarController for compact (iPhone) layout.
//  Replaces the collapsed UISplitViewController with a bottom tab bar.
//
//  4 tabs: Lookup, Bookmarks, History, Management
//
//  Each tab owns independent VC instances.  State is transferred to/from
//  MainSplitViewController on collapse/expand via explicit transfer methods.
//
//  Dictionary/group selection in compact mode is handled by a left-sliding
//  sidebar overlay (DictionaryListViewController), toggled via a button on
//  the Lookup tab's navigation bar.
//

import UIKit
import Combine
import OpenMDictKit

extension UserDefaults {
    private static let searchAutoFocusKey = "searchAutoFocus"

    var searchAutoFocus: Bool {
        bool(forKey: Self.searchAutoFocusKey)
    }
}

class CompactTabBarController: UITabBarController {

    // MARK: - Tab VCs

    /// Tab 0: Lookup — word search + article display
    let lookupWordListVC = WordListViewController()
    let lookupDetailContainer = DetailContainerViewController()
    private(set) lazy var lookupNav: UINavigationController = {
        let nav = UINavigationController(rootViewController: lookupWordListVC)
        nav.tabBarItem = UITabBarItem(
            title: L10n.TabBar.lookup,
            image: UIImage(systemName: "character.book.closed"),
            selectedImage: UIImage(systemName: "character.book.closed.fill")
        )
        return nav
    }()

    /// Tab 1: Bookmarks
    let bookmarkListVC = BookmarkListViewController()
    private(set) lazy var bookmarksNav: UINavigationController = {
        let nav = UINavigationController(rootViewController: bookmarkListVC)
        nav.navigationBar.prefersLargeTitles = true
        nav.tabBarItem = UITabBarItem(
            title: L10n.TabBar.bookmarks,
            image: UIImage(systemName: "bookmark"),
            selectedImage: UIImage(systemName: "bookmark.fill")
        )
        return nav
    }()

    /// Tab 2: History
    let historyListVC = LookupHistoryListViewController()
    private(set) lazy var historyNav: UINavigationController = {
        let nav = UINavigationController(rootViewController: historyListVC)
        nav.navigationBar.prefersLargeTitles = true
        nav.tabBarItem = UITabBarItem(
            title: L10n.TabBar.history,
            image: UIImage(systemName: "clock.arrow.circlepath"),
            selectedImage: UIImage(systemName: "clock.arrow.circlepath.fill")
        )
        return nav
    }()

    /// Tab 3: Management
    let managementVC = CompactManagementViewController()
    private(set) lazy var managementNav: UINavigationController = {
        let nav = UINavigationController(rootViewController: managementVC)
        nav.navigationBar.prefersLargeTitles = true
        nav.tabBarItem = UITabBarItem(
            title: L10n.TabBar.management,
            image: UIImage(systemName: "gearshape.2"),
            selectedImage: UIImage(systemName: "gearshape.2.fill")
        )
        return nav
    }()

    // MARK: - Sidebar Overlay

    /// Sidebar VC — reuses the same DictionaryListViewController class as the regular split view.
    /// Shown as a left-sliding overlay when the user taps the sidebar toggle button.
    private lazy var sidebarVC: DictionaryListViewController = {
        let vc = DictionaryListViewController()
        // In compact tab mode the management section is covered by Tab 3,
        // and the sidebar is a child VC overlay that needs safe-area fixes.
        vc.isCompactSidebarMode = true
        return vc
    }()

    /// Navigation wrapper for the sidebar.
    /// NOT a child VC — UITabBarController.addChild() silently adds to the
    /// tab bar, so we manage the view hierarchy directly instead.
    private var sidebarNavController: UINavigationController?

    /// Fills the status bar area above the sidebar nav with a matching
    /// background colour.  Its leading is tied to the nav view so it
    /// slides in/out together with the sidebar panel.
    private var sidebarStatusBarBackdrop: UIView?

    /// Semi-transparent backdrop shown behind the sidebar; tap to dismiss.
    private let sidebarDimmingView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        v.alpha = 0
        v.isHidden = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// Horizontal position constraint — animates between `-sidebarWidth` (hidden) and `0` (visible).
    private var sidebarLeadingConstraint: NSLayoutConstraint!

    /// Fixed width of the sidebar panel.
    private let sidebarWidth: CGFloat = 320

    /// Whether the sidebar overlay is currently visible.
    private var isSidebarVisible = false

    // MARK: - State

    /// Currently selected group (for lookup context transfer)
    var currentGroup: MDicts?

    /// Currently selected dictionary (for lookup context transfer)
    var currentDict: MDict?

    /// Per-scene search session (injected by MainSplitVC on transfer)
    private var searchSession: LookupSession?

    /// Deferred tab selection from `transferStateIn` when called before `viewDidLoad`.
    /// Applied once `viewControllers` is set.
    private var pendingColumnTarget: MainSplitViewController.ColumnTargetSnapshot?

    private var cancellables = Set<AnyCancellable>()

    /// Loading modal for long-running operations (import)
    private weak var loadingVC: LoadingViewController?

    // MARK: - Management VCs (lazily created, pushed onto managementNav)

    private(set) lazy var dictInfoVC = DictInfoViewController()
    private lazy var dictResourceEditorVC = DictResourceEditorViewController()
    private lazy var groupInfoVC = GroupInfoViewController()
    private lazy var groupDictEditorVC = GroupDictionaryEditorViewController()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // On iPhone the app starts directly in compact mode — splitViewControllerWillCollapse
        // is never called, so transferStateIn() never runs.  Create a local LookupSession
        // so the Lookup tab's reactive search pipeline works from the start.
        if searchSession == nil {
            let session = DictionaryService.shared.createLookupSession()
            searchSession = session
            lookupWordListVC.searchSession = session
        }

        viewControllers = [lookupNav, bookmarksNav, historyNav, managementNav]

        setupSidebarToggleButton()
        setupSidebarOverlay()
        setupLookupCallbacks()
        setupBookmarkCallbacks()
        setupHistoryCallbacks()
        setupSidebarCallbacks()
        setupManagementCallbacks()

        // Apply deferred tab selection from transferStateIn (called before viewDidLoad
        // on iPad's first collapse, where compactTabBarController's view wasn't loaded).
        if let target = pendingColumnTarget {
            applyTabSelection(for: target)
            pendingColumnTarget = nil
        }

        // If no group/dict was provided via transferStateIn(), load the default group
        // so the word list shows a title and is ready for searching.
        // Groups may not yet be populated (async CoreData / CloudKit), so also
        // subscribe reactively to pick up the default group once it appears.
        if currentGroup == nil && currentDict == nil {
            if let defaultGroup = DictionaryService.shared.defaultGroup {
                currentGroup = defaultGroup
                lookupWordListVC.loadWords(for: defaultGroup)
            } else {
                subscribeToDefaultGroupAvailable()
            }
        }
    }

    /// One-shot subscription: when DictionaryService.groups becomes non-empty
    /// and no group/dict has been selected yet, auto-select the default group.
    private func subscribeToDefaultGroupAvailable() {
        DictionaryService.shared.$groups
            .compactMap { $0.first { $0.isDefault } }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] defaultGroup in
                guard let self,
                      self.currentGroup == nil,
                      self.currentDict == nil else { return }
                self.currentGroup = defaultGroup
                self.lookupWordListVC.loadWords(for: defaultGroup)
            }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Async to ensure view hierarchy is fully stabilized
        DispatchQueue.main.async { [weak self] in
            self?.focusLookupSearchBarIfVisible()
        }
    }

    // MARK: - Auto-Focus Search Bar

    /// Activate the search bar keyboard when the Lookup tab is visible.
    /// Guards: Tab 0 selected AND WordListVC is topViewController (not pushed to Detail).
    func focusLookupSearchBarIfVisible() {
        guard UserDefaults.standard.searchAutoFocus,
              selectedIndex == 0,
              lookupNav.topViewController === lookupWordListVC else { return }
        lookupWordListVC.focusSearchBar()
    }

    // MARK: - Sidebar Toggle Button

    private func setupSidebarToggleButton() {
        let sidebarButton = UIBarButtonItem(
            image: UIImage(systemName: "sidebar.left"),
            style: .plain,
            target: self,
            action: #selector(sidebarToggleTapped)
        )
        lookupWordListVC.navigationItem.leftBarButtonItem = sidebarButton
    }

    @objc private func sidebarToggleTapped() {
        if isSidebarVisible {
            hideSidebar()
        } else {
            showSidebar()
        }
    }

    // MARK: - Sidebar Overlay Setup

    private func setupSidebarOverlay() {
        // 1. Dimming backdrop — covers the full view, tap to dismiss.
        view.addSubview(sidebarDimmingView)
        NSLayoutConstraint.activate([
            sidebarDimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarDimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarDimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sidebarDimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dimmingViewTapped))
        sidebarDimmingView.addGestureRecognizer(tap)

        // 2. Sidebar navigation controller.
        //
        //    IMPORTANT: do NOT call addChild(nav) / didMove(toParent:).
        //    UITabBarController.addChild() silently appends the VC to the
        //    tab bar, creating an unwanted fifth tab.  Instead we manage
        //    the nav view in the view hierarchy directly.
        //
        //    The nav view is pinned to safeAreaLayoutGuide.topAnchor so
        //    the nav bar sits below the status bar without relying on
        //    safe-area propagation from the tab bar controller.  A small
        //    backdrop view fills the status bar area with a matching colour.
        let nav = UINavigationController(rootViewController: sidebarVC)

        nav.view.backgroundColor = .systemGroupedBackground
        nav.view.translatesAutoresizingMaskIntoConstraints = false
        nav.view.layer.shadowColor = UIColor.black.cgColor
        nav.view.layer.shadowOpacity = 0.25
        nav.view.layer.shadowRadius = 10
        nav.view.layer.shadowOffset = CGSize(width: 2, height: 0)
        view.addSubview(nav.view)

        // 3. Status-bar backdrop — fills the area above the nav view with
        //    the same background colour.  Its leading is tied to the nav
        //    view so it slides in/out together with the sidebar panel.
        let backdrop = UIView()
        backdrop.backgroundColor = .systemGroupedBackground
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, belowSubview: nav.view)
        sidebarStatusBarBackdrop = backdrop

        sidebarLeadingConstraint = nav.view.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: -sidebarWidth
        )
        NSLayoutConstraint.activate([
            nav.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            nav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            nav.view.widthAnchor.constraint(equalToConstant: sidebarWidth),
            sidebarLeadingConstraint,

            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: nav.view.leadingAnchor),
            backdrop.widthAnchor.constraint(equalTo: nav.view.widthAnchor),
        ])

        sidebarNavController = nav
    }

    // MARK: - Show / Hide Sidebar

    private func showSidebar() {
        guard !isSidebarVisible else { return }
        isSidebarVisible = true

        // Update sidebar to reflect current selection
        if let group = currentGroup {
            sidebarVC.setActiveGroup(group)
        } else if let dict = currentDict {
            sidebarVC.setActiveDictionary(dict)
        }

        sidebarDimmingView.isHidden = false
        view.layoutIfNeeded()

        sidebarLeadingConstraint.constant = 0
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
            self.sidebarDimmingView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    private func hideSidebar(completion: (() -> Void)? = nil) {
        guard isSidebarVisible else { completion?(); return }
        isSidebarVisible = false

        // Exit editing mode if the sidebar was being edited
        if sidebarVC.isEditing {
            sidebarVC.setEditing(false, animated: false)
        }

        sidebarLeadingConstraint.constant = -sidebarWidth
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            self.sidebarDimmingView.alpha = 0
            self.view.layoutIfNeeded()
        } completion: { _ in
            self.sidebarDimmingView.isHidden = true
            completion?()
        }
    }

    @objc private func dimmingViewTapped() {
        hideSidebar()
    }

    // MARK: - Callback Setup

    private func setupLookupCallbacks() {
        lookupWordListVC.onWordSelected = { [weak self] word in
            self?.handleWordSelected(word)
        }

        lookupWordListVC.onViewAllHistory = { [weak self] in
            guard let self else { return }
            selectedIndex = 2
            historyListVC.reload()
        }

        lookupDetailContainer.onArticlesEmptied = { [weak self] in
            guard let self else { return }
            // Pop back to word list when all articles are closed
            lookupNav.popToRootViewController(animated: true)
        }

        lookupDetailContainer.onJumpSearchFallback = { [weak self] word in
            guard let self else { return }
            // Pop to word list and search for the word
            lookupNav.popToRootViewController(animated: false)
            lookupWordListVC.focusSearchBar(withInitialText: word)
        }
    }

    private func setupBookmarkCallbacks() {
        bookmarkListVC.onBookmarkSelected = { [weak self] bookmark in
            guard let self else { return }
            guard bookmark.isDictAvailable else { return }
            handleBookmarkSelected(bookmark)
        }
    }

    private func setupHistoryCallbacks() {
        historyListVC.onHistorySelected = { [weak self] historyItem in
            guard let self else { return }
            guard historyItem.isDictAvailable else { return }
            handleHistorySelected(historyItem)
        }
    }

    // MARK: - Sidebar Callbacks (dict/group selection + management actions)

    private func setupSidebarCallbacks() {
        sidebarVC.onGroupSelected = { [weak self] group in
            guard let self else { return }
            hideSidebar()
            currentGroup = group
            currentDict = nil
            selectedIndex = 0
            lookupNav.popToRootViewController(animated: false)
            lookupWordListVC.loadWords(for: group)
        }

        sidebarVC.onDictionarySelected = { [weak self] dict in
            guard let self else { return }
            hideSidebar()
            currentGroup = nil
            currentDict = dict
            selectedIndex = 0
            lookupNav.popToRootViewController(animated: false)
            lookupWordListVC.loadWords(for: dict)
        }

        sidebarVC.onBookmarksSelected = { [weak self] in
            guard let self else { return }
            hideSidebar()
            selectedIndex = 1
            bookmarkListVC.reload()
        }

        sidebarVC.onLookupHistorySelected = { [weak self] in
            guard let self else { return }
            hideSidebar()
            selectedIndex = 2
            historyListVC.reload()
        }

        sidebarVC.onImportDictionarySelected = { [weak self] in
            guard let self else { return }
            hideSidebar()
            selectedIndex = 3
            managementNav.popToRootViewController(animated: false)
            dictInfoVC.showImportMode()
            dictResourceEditorVC.showEmptyState()
            managementNav.pushViewController(dictInfoVC, animated: true)
        }

        sidebarVC.onAddGroupSelected = { [weak self] in
            guard let self else { return }
            hideSidebar()
            selectedIndex = 3
            managementNav.popToRootViewController(animated: false)
            let session = DictionaryService.shared.groupSession
            session.beginCreate()
            groupInfoVC.showCreatingMode(pendingName: session.pendingName ?? L10n.GroupInfo.newGroup)
            groupDictEditorVC.showCreatingEditor()
            managementNav.pushViewController(groupInfoVC, animated: true)
        }

        sidebarVC.onDictionaryInfoSelected = { [weak self] dictId in
            guard let self else { return }
            hideSidebar()
            selectedIndex = 3
            managementNav.popToRootViewController(animated: false)
            dictInfoVC.showEditMode(for: dictId)
            dictResourceEditorVC.showEditor(for: dictId)
            managementNav.pushViewController(dictInfoVC, animated: true)
        }

        sidebarVC.onGroupInfoSelected = { [weak self] groupId in
            guard let self else { return }
            hideSidebar()
            selectedIndex = 3
            managementNav.popToRootViewController(animated: false)
            let group = DictionaryService.shared.group(id: groupId)
            if group?.isDefault == true {
                groupInfoVC.showViewingDefaultMode(for: groupId)
                groupDictEditorVC.showReorderEditor(for: groupId)
            } else {
                let session = DictionaryService.shared.groupSession
                session.beginManaging(groupId: groupId)
                groupInfoVC.showManagingMode(for: groupId)
                groupDictEditorVC.showEditor(for: groupId)
            }
            managementNav.pushViewController(groupInfoVC, animated: true)
        }

        sidebarVC.onManagePresetsSelected = { [weak self] in
            guard let self else { return }
            hideSidebar()
            presentPresetManager()
        }

        sidebarVC.onChangeAppIconSelected = { [weak self] in
            guard let self else { return }
            hideSidebar()
            let vc = AppIconChooserViewController()
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .pageSheet
            present(nav, animated: true)
        }

        sidebarVC.onTroubleshootSelected = { [weak self] in
            guard let self else { return }
            hideSidebar()
            showTroubleshootingScreen()
        }
    }

    // MARK: - Word Selection (Lookup tab)

    func handleWordSelected(_ word: WordDisplayItem) {
        let dict = DictionaryService.shared.dict(id: word.dictId)

        var article = ArticleDisplayItem(
            word: word.word,
            dictId: word.dictId,
            dictName: word.dictName,
            contentState: .pending
        )

        if let dict, let entry = dict.lookup(word.word) {
            article.contentState = .loaded(html: entry.article.html, css: nil)
        }

        // Push detail container if not already on the nav stack
        if lookupDetailContainer.parent == nil
            || lookupNav.viewControllers.last !== lookupDetailContainer {
            lookupDetailContainer.pushArticle(article, animated: false)
            lookupNav.pushViewController(lookupDetailContainer, animated: true)
        } else {
            lookupDetailContainer.pushArticle(article, animated: true)
        }

        // Record lookup history
        let (ctxDictId, ctxGroupId): (String?, String?) = switch lookupWordListVC.searchSession?.currentContext {
        case .dictionary(let d): (d.id, nil)
        case .group(let g):      (nil, g.id)
        case .none?, nil:        (nil, "all")
        }
        lookupDetailContainer.lookupContext = (dictId: ctxDictId, groupId: ctxGroupId)
        LookupHistoryService.shared.recordLookup(
            word: word.word, dictId: word.dictId,
            lookupContextDictId: ctxDictId, lookupContextGroupId: ctxGroupId
        )
    }

    // MARK: - Bookmark Selection (Bookmarks tab)

    private func handleBookmarkSelected(_ bookmark: BookmarkItem) {
        let dict = DictionaryService.shared.dict(id: bookmark.dictId)
        var article = ArticleDisplayItem(
            word: bookmark.word,
            dictId: bookmark.dictId,
            dictName: bookmark.dictName,
            contentState: .pending
        )

        if let dict, let entry = dict.lookup(bookmark.word) {
            article.contentState = .loaded(html: entry.article.html, css: nil)
        }

        // Push a fresh detail container for single-article view
        let detailVC = DetailContainerViewController()
        detailVC.onArticlesEmptied = { [weak self] in
            self?.bookmarksNav.popViewController(animated: true)
        }
        detailVC.onJumpSearchFallback = { [weak self] word in
            guard let self else { return }
            // Switch to Lookup tab and search there
            selectedIndex = 0
            lookupNav.popToRootViewController(animated: false)
            lookupWordListVC.focusSearchBar(withInitialText: word)
        }
        detailVC.pushArticle(article, animated: false)
        bookmarksNav.pushViewController(detailVC, animated: true)

        // Record lookup history (bookmarkListVC auto-reloads via $revision)
        LookupHistoryService.shared.recordLookup(
            word: bookmark.word, dictId: bookmark.dictId,
            lookupContextDictId: nil, lookupContextGroupId: nil
        )
    }

    // MARK: - History Selection (History tab)

    private func handleHistorySelected(_ historyItem: HistoryItem) {
        let dict = DictionaryService.shared.dict(id: historyItem.dictId)
        var article = ArticleDisplayItem(
            word: historyItem.word,
            dictId: historyItem.dictId,
            dictName: historyItem.dictName ?? historyItem.dictId,
            contentState: .pending
        )

        if let dict, let entry = dict.lookup(historyItem.word) {
            article.contentState = .loaded(html: entry.article.html, css: nil)
        }

        let detailVC = DetailContainerViewController()
        detailVC.onArticlesEmptied = { [weak self] in
            self?.historyNav.popViewController(animated: true)
        }
        detailVC.onJumpSearchFallback = { [weak self] word in
            guard let self else { return }
            // Switch to Lookup tab and search there
            selectedIndex = 0
            lookupNav.popToRootViewController(animated: false)
            lookupWordListVC.focusSearchBar(withInitialText: word)
        }
        detailVC.pushArticle(article, animated: false)
        historyNav.pushViewController(detailVC, animated: true)

        // Record lookup history (lookupHistoryListVC auto-reloads via $revision)
        LookupHistoryService.shared.recordLookup(
            word: historyItem.word, dictId: historyItem.dictId,
            lookupContextDictId: nil, lookupContextGroupId: nil
        )
    }

    // MARK: - Management Callbacks

    private func setupManagementCallbacks() {
        // Management tab's 4 action items
        managementVC.onImportSelected = { [weak self] in
            guard let self else { return }
            dictInfoVC.showImportMode()
            dictResourceEditorVC.showEmptyState()
            managementNav.pushViewController(dictInfoVC, animated: true)
        }

        managementVC.onAddGroupSelected = { [weak self] in
            guard let self else { return }
            let session = DictionaryService.shared.groupSession
            session.beginCreate()
            groupInfoVC.showCreatingMode(pendingName: session.pendingName ?? L10n.GroupInfo.newGroup)
            groupDictEditorVC.showCreatingEditor()
            managementNav.pushViewController(groupInfoVC, animated: true)
        }

        managementVC.onDownloadPresetsSelected = { [weak self] in
            self?.presentPresetManager()
        }

        managementVC.onChangeAppIconSelected = { [weak self] in
            guard let self else { return }
            let vc = AppIconChooserViewController()
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .pageSheet
            present(nav, animated: true)
        }

        managementVC.onTroubleshootSelected = { [weak self] in
            self?.showTroubleshootingScreen()
        }

        managementVC.onAppSettingsSelected = {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }

        // DictInfoVC callbacks (shared by management tab and sidebar triggers)
        dictInfoVC.onDismiss = { [weak self] in
            self?.managementNav.popToRootViewController(animated: true)
        }

        dictInfoVC.onManageResources = { [weak self] dictId in
            guard let self else { return }
            dictResourceEditorVC.showEditor(for: dictId)
            managementNav.pushViewController(dictResourceEditorVC, animated: true)
        }

        dictInfoVC.onMDXSelected = { [weak self] dictId in
            self?.dictResourceEditorVC.showEditor(for: dictId)
        }

        dictInfoVC.onImportStarted = { [weak self] in
            guard let self else { return }
            loadingVC = showLoadingModal(message: L10n.Detail.importingDictionary)
        }

        dictInfoVC.onImportFailed = { [weak self] _ in
            guard let self else { return }
            hideLoadingModal(loadingVC)
            loadingVC = nil
        }

        dictInfoVC.onImportComplete = { [weak self] dictId in
            guard let self else { return }
            hideLoadingModal(loadingVC) { [weak self] in
                guard let self else { return }
                managementNav.popToRootViewController(animated: false)
                // After import, switch to lookup tab with the new dictionary
                if let dict = DictionaryService.shared.dict(id: dictId) {
                    currentDict = dict
                    currentGroup = nil
                    selectedIndex = 0
                    lookupNav.popToRootViewController(animated: false)
                    lookupWordListVC.loadWords(for: dict)
                }
            }
            loadingVC = nil
        }

        dictInfoVC.onEditComplete = { [weak self] dictId in
            guard let self else { return }
            managementNav.popToRootViewController(animated: true)
        }

        dictInfoVC.onDeleteComplete = { [weak self] dictId in
            guard let self else { return }
            managementNav.popToRootViewController(animated: true)
        }

        // GroupInfoVC callbacks
        groupInfoVC.onDismiss = { [weak self] in
            guard let self else { return }
            DictionaryService.shared.groupSession.reset()
            managementNav.popToRootViewController(animated: true)
        }

        groupInfoVC.onManageDictionaries = { [weak self] groupId in
            guard let self else { return }
            managementNav.pushViewController(groupDictEditorVC, animated: true)
        }

        groupInfoVC.onCreateComplete = { [weak self] groupId in
            guard let self else { return }
            managementNav.popToRootViewController(animated: false)

            // Select the newly created group and switch to lookup tab
            if let group = DictionaryService.shared.group(id: groupId) {
                currentGroup = group
                currentDict = nil
                selectedIndex = 0
                lookupNav.popToRootViewController(animated: false)
                lookupWordListVC.loadWords(for: group)
            }
        }

        groupInfoVC.onGroupChanged = { [weak self] groupId in
            // No-op for compact management tab (static content)
        }

        groupInfoVC.onDeleteComplete = { [weak self] groupId in
            guard let self else { return }
            managementNav.popToRootViewController(animated: true)
        }
    }

    /// Present the preset dictionary picker as a modal.
    private func presentPresetManager() {
        let setupVC = SetupViewController(mode: .management)
        setupVC.modalPresentationStyle = .pageSheet

        setupVC.onComplete = { }

        present(setupVC, animated: true)
    }

    // MARK: - iCloud Troubleshooting

    private func showTroubleshootingScreen() {
        let troubleshootVC = iCloudTroubleshootingViewController()
        troubleshootVC.onResetComplete = { [weak self] in
            self?.handlePostReset()
        }

        let nav = UINavigationController(rootViewController: troubleshootVC)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    private func handlePostReset() {
        guard let windowScene = view.window?.windowScene else { return }

        // Destroy all other scenes
        for session in UIApplication.shared.openSessions where session.scene !== windowScene {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }

        // Replace root view controller
        let freshSplitVC = MainSplitViewController(
            initialArticles: [],
            initialGroupId: "",
            initialLayoutMode: 0
        )
        view.window?.rootViewController = freshSplitVC
    }

    // MARK: - State Transfer API (called by MainSplitVC)

    /// Configure compact tabs with state from the regular split view.
    /// Called by MainSplitVC in `splitViewControllerWillCollapse` or `viewDidAppear`.
    func transferStateIn(
        group: MDicts?,
        dict: MDict?,
        searchSession: LookupSession,
        articles: [ArticleDisplayItem],
        currentArticleIndex: Int,
        columnTarget: MainSplitViewController.ColumnTargetSnapshot
    ) {
        self.currentGroup = group
        self.currentDict = dict
        self.searchSession = searchSession

        // Inject search session into lookup word list
        lookupWordListVC.searchSession = searchSession

        // ALWAYS overwrite — ensures stale articles from a previous collapse
        // are replaced, even when the regular side sends an empty array.
        lookupDetailContainer.restoreArticles(articles, currentIndex: currentArticleIndex)

        // Push/pop lookup detail based on whether articles exist.
        if !articles.isEmpty {
            if lookupNav.viewControllers.last !== lookupDetailContainer {
                lookupNav.pushViewController(lookupDetailContainer, animated: false)
            }
        } else {
            lookupNav.popToRootViewController(animated: false)
        }

        // Select the appropriate tab.  On iPad's first collapse compactTabBarController
        // may not have loaded yet (viewControllers is nil), so defer the selection
        // until viewDidLoad applies it.
        if isViewLoaded {
            applyTabSelection(for: columnTarget)
        } else {
            pendingColumnTarget = columnTarget
        }

        // Reload word list with current context
        if let group {
            lookupWordListVC.loadWords(for: group)
        } else if let dict {
            lookupWordListVC.loadWords(for: dict)
        }
    }

    /// Read current state from compact tabs for transfer back to regular split view.
    func transferStateOut() -> CompactState {
        CompactState(
            group: currentGroup,
            dict: currentDict,
            articles: lookupDetailContainer.allArticles,
            currentArticleIndex: lookupDetailContainer.currentVisibleArticleIndex,
            selectedTab: selectedIndex
        )
    }

    // MARK: - Tab Selection

    private func applyTabSelection(for target: MainSplitViewController.ColumnTargetSnapshot) {
        switch target {
        case .lookup:
            selectedIndex = 0
        case .bookmarks:
            selectedIndex = 1
            bookmarkListVC.reload()
        case .lookupHistory:
            selectedIndex = 2
            historyListVC.reload()
        case .management:
            selectedIndex = 3
        }
    }

    struct CompactState {
        let group: MDicts?
        let dict: MDict?
        let articles: [ArticleDisplayItem]
        let currentArticleIndex: Int
        let selectedTab: Int
    }
}
