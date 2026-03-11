//
//  AppDelegate.swift
//  OpenMDict-iOS
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Register Settings.bundle defaults for standard (Settings.app reads/writes here)
        // and shared (Extension reads/writes here) suites.
        let defaults: [String: Any] = [
            "appearanceMode": 1,    // .system
            "searchResultVolume": 2, // .normal (Default)
            "articlesCapacity": 1,  // .normal (Default)
            "searchAutoFocus": true,
            "showLookupCount": true,
            "showEnhanceDarkMode": true,
        ]
        UserDefaults.standard.register(defaults: defaults)
        UserDefaults.shared.register(defaults: defaults)

        // Bridge Settings.bundle values from standard to shared (Action Extension reads shared).
        UserDefaults.shared.articlesCapacity = UserDefaults.standard.articlesCapacity
        UserDefaults.shared.showLookupCount = UserDefaults.standard.showLookupCount
        UserDefaults.shared.showEnhanceDarkMode = UserDefaults.standard.showEnhanceDarkMode

        // Merge appearance mode between standard (Settings.bundle) and shared (Extension).
        // Both may have changed while the app was killed:
        //   - Extension writes to shared with a timestamp via setAppearanceModeStamped()
        //   - Settings.app writes to standard without any timestamp
        //   - Main app dual-writes both and stamps shared
        //
        // On launch, compare shared's timestamp against the last time main app synced.
        // If shared is newer → Extension wrote after our last sync → shared wins.
        // Otherwise → standard wins (Settings.app change or no change).
        let lastSyncTime = UserDefaults.standard.appearanceModeTimestamp  // our last dual-write
        let sharedStamp  = UserDefaults.shared.appearanceModeTimestamp
        if sharedStamp > lastSyncTime {
            // Extension wrote after main app's last sync → shared wins
            let mode = UserDefaults.shared.appearanceMode
            UserDefaults.standard.appearanceMode = mode
            UserDefaults.standard.appearanceModeTimestamp = sharedStamp
        } else {
            // Standard wins (Settings.app changed, or both are in sync)
            let mode = UserDefaults.standard.appearanceMode
            UserDefaults.shared.setAppearanceModeStamped(mode)
            UserDefaults.standard.appearanceModeTimestamp = UserDefaults.shared.appearanceModeTimestamp
        }

        // Initialize persistent store — CloudKit enabled only when user opted in.
        let syncMode = SyncModeService.shared.currentMode
        CoreDataStack.shared.setup(enableCloudKit: syncMode == .cloudSync)

        // Install the remote-change preprocessor.
        // Checks for a nuclear reset signal (from another device) before
        // running dedup.  If a signal is found, performs a passive reset
        // and skips dedup entirely.
        iCloudResetOrchestrator.shared.installPreprocessor()

        // Register for remote notifications (CloudKit uses silent push for sync)
        application.registerForRemoteNotifications()

        // Initialize dictionary service — defer when sync mode is undecided
        // (first install).  SetupViewController will call setup() after the
        // user chooses cloud sync or offline.
        if syncMode != .notDecided {
            DictionaryService.shared.setup()
        }

        // Check for an unprocessed nuclear reset signal from another device.
        // Handles the case where this device was offline/killed when the
        // nuke happened.  The check is async and non-blocking — if a signal
        // is found, it performs a passive reset and posts a notification
        // that SceneDelegate observes to reset the UI.
        if syncMode == .cloudSync {
            Task {
                await iCloudResetOrchestrator.shared.checkAndHandlePassiveReset()
            }
        }

        // iPadOS 26+: use UIMainMenuSystem.Configuration to declaratively
        // configure the menu bar. The build handler replaces buildMenu(with:).
        if #available(iOS 26, *) {
            let config = UIMainMenuSystem.Configuration()
            config.newScenePreference = .removed   // Maybe removes system "New Window"...
            UIMainMenuSystem.shared.setBuildConfiguration(config) { [weak self] builder in
                self?.configureMenus(with: builder, isIOS26: true)
            }
        }

        return true
    }

    // MARK: - Remote Notifications (CloudKit Sync)

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // NSPersistentCloudKitContainer handles CloudKit push internally.
        // We just need to call the completion handler.
        completionHandler(.newData)
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        // Clean up resources for discarded scenes
    }

    // MARK: - Menu Builder (iPad Keyboard Shortcut HUD)

    /// iOS 15–25: the system calls this to build the keyboard shortcut HUD / menu bar.
    /// On iOS 26+ the setBuildConfiguration build handler is used instead.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        if #available(iOS 26, *) { return } // handled by setBuildConfiguration
        configureMenus(with: builder, isIOS26: false)
    }

    // MARK: - Shared Menu Configuration

    private func configureMenus(with builder: UIMenuBuilder, isIOS26: Bool) {
        // Remove unused system menus
        builder.remove(menu: .file)
        builder.remove(menu: .edit)
        builder.remove(menu: .format)

        // Move Help to the very end (after Window)
        if let helpMenu = builder.menu(for: .help) {
            builder.remove(menu: .help)
            builder.insertSibling(helpMenu, afterMenu: .window)
        }

        // Remove system "New Window" so we can provide our own ⌘N
        if isIOS26 {
            // Belt-and-suspenders: config.newScenePreference = .removed should handle it,
            // but also explicitly remove .newItem in case the system re-inserts it.
            if #available(iOS 26, *) {
                builder.remove(menu: .newItem)
            }
        }
        builder.remove(menu: .newScene)

        // Helper: create UIKeyCommand with optional image
        func cmd(_ title: String, image: String? = nil, action: Selector,
                 input: String, flags: UIKeyModifierFlags = .command) -> UIKeyCommand {
            let img = image.flatMap { UIImage(systemName: $0) }
            return UIKeyCommand(title: title, image: img,
                                action: action, input: input, modifierFlags: flags)
        }

        // ── 1. Query (custom) — core feature, listed first ───────────
        // ⌥⌘` selects "All Dictionaries" (default group)
        let selectAllCmd = cmd(L10n.Shortcuts.selectAllDictionaries, image: "books.vertical",
                               action: #selector(MainSplitViewController.selectAllDictionaries),
                               input: "`", flags: [.alternate, .command])
        // ⌥⌘1~9 selects user groups; only first item gets an icon
        let groupCommands: [UIKeyCommand] = (1...9).map { n in
            cmd(L10n.Shortcuts.group(n),
                image: n == 1 ? "folder" : nil,
                action: NSSelectorFromString("selectGroup\(n)"),
                input: "\(n)", flags: [.alternate, .command])
        }
        // ⌃⌥⌘1~9 selects dictionaries; only first item gets an icon
        let dictCommands: [UIKeyCommand] = (1...9).map { n in
            cmd(L10n.Shortcuts.dictionary(n),
                image: n == 1 ? "book.closed" : nil,
                action: NSSelectorFromString("selectDictionary\(n)"),
                input: "\(n)", flags: [.control, .alternate, .command])
        }
        let queryMenu = UIMenu(
            title: L10n.Shortcuts.categoryQuery,
            identifier: .init("com.openmdict.query"),
            children: [
                cmd(L10n.Shortcuts.focusLookup, image: "character.cursor.ibeam",
                    action: #selector(MainSplitViewController.focusLookupShortcut),
                    input: "l"),
                UIMenu(title: "", options: .displayInline, children: [selectAllCmd]),
                UIMenu(title: "", options: .displayInline, children: groupCommands),
                UIMenu(title: "", options: .displayInline, children: dictCommands),
            ]
        )
        builder.insertChild(queryMenu, atStartOfMenu: .root)

        // ── 2. View (append to system .view) ──────────────────────────
        let layoutSubgroup = UIMenu(title: "", options: .displayInline, children: [
            cmd(L10n.Shortcuts.columnsLayout, image: "rectangle.split.3x1",
                action: #selector(MainSplitViewController.switchToColumnsLayout),
                input: "1"),
            cmd(L10n.Shortcuts.gridLayout, image: "square.grid.2x2",
                action: #selector(MainSplitViewController.switchToGridLayout),
                input: "2"),
            cmd(L10n.Shortcuts.listLayout, image: "list.bullet",
                action: #selector(MainSplitViewController.switchToListLayout),
                input: "3"),
        ])
        let appearanceItem = cmd(
            L10n.Shortcuts.toggleAppearance, image: "circle.lefthalf.filled",
            action: #selector(MainSplitViewController.toggleAppearanceShortcut),
            input: "a", flags: [.shift, .command])
        let zoomSubgroup = UIMenu(title: "", options: .displayInline, children: [
            cmd(L10n.Shortcuts.zoomOut, image: "minus.magnifyingglass",
                action: #selector(MainSplitViewController.zoomOutShortcut),
                input: "-"),
            cmd(L10n.Shortcuts.actualSize, image: "1.magnifyingglass",
                action: #selector(MainSplitViewController.actualSizeShortcut),
                input: "0"),
            cmd(L10n.Shortcuts.zoomIn, image: "plus.magnifyingglass",
                action: #selector(MainSplitViewController.zoomInShortcut),
                input: "="),
        ])
        let findItem = cmd(
            L10n.Shortcuts.findInPage, image: "doc.text.magnifyingglass",
            action: #selector(DetailContainerViewController.handleFindShortcut),
            input: "f")
        let viewMenu = UIMenu(title: "", options: .displayInline,
                              children: [layoutSubgroup, appearanceItem, zoomSubgroup, findItem])
        builder.insertChild(viewMenu, atEndOfMenu: .view)

        // ── 3. Bookmarks (custom) ─────────────────────────────────────
        let bookmarksMenu = UIMenu(
            title: L10n.Shortcuts.categoryBookmarks,
            identifier: .init("com.openmdict.bookmarks"),
            children: [
                cmd(L10n.Shortcuts.showBookmarks, image: "bookmark",
                    action: #selector(MainSplitViewController.showBookmarksShortcut),
                    input: "1", flags: [.control, .command]),
            ]
        )
        builder.insertSibling(bookmarksMenu, afterMenu: .view)

        // ── 4. History (custom) ────────────────────────────────────────
        let historyMenu = UIMenu(
            title: L10n.Shortcuts.categoryHistory,
            identifier: .init("com.openmdict.history"),
            children: [
                cmd(L10n.Shortcuts.showHistory, image: "clock.arrow.circlepath",
                    action: #selector(MainSplitViewController.showHistoryShortcut),
                    input: "2", flags: [.control, .command]),
            ]
        )
        builder.insertSibling(historyMenu, afterMenu: .init("com.openmdict.bookmarks"))

        // ── 5. Window (append to system .window) ──────────────────────
        let windowExtras = UIMenu(title: "", options: .displayInline, children: [
            cmd(L10n.Shortcuts.newWindow, image: "plus.rectangle",
                action: #selector(MainSplitViewController.newWindowShortcut),
                input: "n"),
            cmd(L10n.Shortcuts.closeArticle, image: "xmark",
                action: #selector(MainSplitViewController.closeArticleShortcut),
                input: "w"),
            cmd(L10n.Shortcuts.dismiss, image: "escape",
                action: #selector(MainSplitViewController.dismissShortcut),
                input: UIKeyCommand.inputEscape, flags: []),
        ])
        let pageSubgroup = UIMenu(title: "", options: .displayInline, children: [
            cmd(L10n.Shortcuts.previousPage, image: "chevron.up",
                action: #selector(DetailContainerViewController.previousPageShortcut),
                input: "["),
            cmd(L10n.Shortcuts.nextPage, image: "chevron.down",
                action: #selector(DetailContainerViewController.nextPageShortcut),
                input: "]"),
        ])
        let sourceSubgroup = UIMenu(title: "", options: .displayInline, children: [
            cmd(L10n.Shortcuts.previousSource, image: "arrow.left.circle",
                action: #selector(MainSplitViewController.previousContextShortcut),
                input: "[", flags: [.alternate, .command]),
            cmd(L10n.Shortcuts.nextSource, image: "arrow.right.circle",
                action: #selector(MainSplitViewController.nextContextShortcut),
                input: "]", flags: [.alternate, .command]),
        ])
        let windowMenu = UIMenu(title: "", options: .displayInline,
                                children: [windowExtras, pageSubgroup, sourceSubgroup])
        builder.insertChild(windowMenu, atEndOfMenu: .window)

        // ── 6. App-level utilities ───────────────────────────────────
        // On iOS 26+ the system auto-provides ⌘, for Settings.app; skip our own.
        var appItems: [UIKeyCommand] = [
            cmd(L10n.Shortcuts.downloadPresets, image: "icloud.and.arrow.down",
                action: #selector(MainSplitViewController.importPresetsShortcut),
                input: "i", flags: [.shift, .command]),
        ]
        if !isIOS26 {
            appItems.append(
                cmd(L10n.Shortcuts.openSettings, image: "gearshape",
                    action: #selector(MainSplitViewController.openSettingsShortcut),
                    input: ",")
            )
        }
        let appUtilitiesMenu = UIMenu(title: "", options: .displayInline, children: appItems)
        builder.insertChild(appUtilitiesMenu, atEndOfMenu: .application)
    }
}
