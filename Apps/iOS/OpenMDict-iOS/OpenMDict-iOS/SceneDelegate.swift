//
//  SceneDelegate.swift
//  OpenMDict-iOS
//

import CoreSpotlight
import OpenMDictKit
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var passiveResetObserver: Any?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Block new windows during first-install onboarding.
        // If sync mode is undecided or no dictionaries exist, the primary scene
        // runs the setup flow.  Any additional scene opened during that time
        // is immediately destroyed.
        let syncMode = SyncModeService.shared.currentMode
        let isFirstInstall = syncMode == .notDecided
            || !DictMetadataService.shared.hasAnyDictionaries
        let hasOtherScene = UIApplication.shared.connectedScenes
            .contains { $0.activationState != .unattached && $0 !== scene }

        if isFirstInstall && hasOtherScene {
            // Destroy this scene session on the next run loop tick
            // (can't destroy during willConnectTo: itself)
            DispatchQueue.main.async {
                UIApplication.shared.requestSceneSessionDestruction(
                    session, options: nil, errorHandler: { error in
                        debugLog("⚠️ Failed to destroy duplicate scene during setup: \(error)")
                    }
                )
            }
            return
        }

        let window = UIWindow(windowScene: windowScene)

        // Parse restoration state
        var initialArticles: [ArticleDisplayItem] = []
        var initialGroupId: String = ""
        var initialLayoutMode: Int = 0
        var sourceSessionId: String? = nil

        if let activity = connectionOptions.userActivities.first ?? session.stateRestorationActivity {
            if let sceneState = ArticleDisplayItem.parseSceneState(from: activity) {
                // Full scene restoration
                initialArticles = sceneState.articles
                initialGroupId = sceneState.groupId
                initialLayoutMode = sceneState.layoutMode
            } else if let article = ArticleDisplayItem.from(userActivity: activity) {
                // Single article (from drag & drop or handoff)
                initialArticles = [article]
                sourceSessionId = activity.userInfo?["sourceSessionId"] as? String
            }
        }

        // Create main interface
        let splitVC = MainSplitViewController(
            initialArticles: initialArticles,
            initialGroupId: initialGroupId,
            initialLayoutMode: initialLayoutMode
        )

        // Mark user-initiated scenes (open in new window, drag, handoff)
        // so compact mode keeps articles visible instead of popping to lookup screen.
        if connectionOptions.userActivities.first != nil {
            splitVC.isUserInitiatedScene = true
        }

        window.rootViewController = splitVC

        self.window = window
        window.makeKeyAndVisible()

        // Observe passive reset from another device's nuclear reset.
        // When triggered, replace rootViewController with a fresh MainSplitVC.
        passiveResetObserver = NotificationCenter.default.addObserver(
            forName: .passiveResetDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePassiveReset()
        }

        // Set window title (shown in App Switcher)
        if let firstArticle = initialArticles.first {
            windowScene.title = firstArticle.word
        } else {
            windowScene.title = "OpenMDict"
        }

        // Notify source window if this was a drag & drop
        if let sourceSessionId = sourceSessionId, let articleId = initialArticles.first?.id {
            NotificationCenter.default.post(
                name: .articleMovedToNewScene,
                object: nil,
                userInfo: [
                    "articleId": articleId,
                    "sourceSessionId": sourceSessionId
                ]
            )
        }

        // Handle Quick Action if app was cold-launched from Home Screen shortcut.
        // When the app is already running, windowScene(_:performActionFor:) is called instead.
        if let shortcutItem = connectionOptions.shortcutItem {
            DispatchQueue.main.async {
                Self.handleQuickAction(shortcutItem, in: window)
            }
        }
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let splitVC = window?.rootViewController as? MainSplitViewController else {
            return nil
        }
        return splitVC.currentStateActivity()
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let splitVC = window?.rootViewController as? MainSplitViewController else { return }

        // Handle Spotlight search result tap
        if let dictId = SpotlightIndexingService.parseDictionaryId(from: userActivity) {
            splitVC.select(dictionaryId: dictId)
            return
        }

        // Handle article handoff / drag-and-drop / Siri Suggestion (viewArticle)
        if let article = ArticleDisplayItem.from(userActivity: userActivity) {
            splitVC.showArticle(article, animated: true)
            return
        }

        // Handle lookupWord (from Siri Suggestions, Shortcuts, etc.)
        if userActivity.activityType == AppIdentifiers.Activity.lookupWord,
           let word = userActivity.userInfo?["word"] as? String {
            splitVC.focusSearchAndLookup(word: word)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let splitVC = window?.rootViewController as? MainSplitViewController else { return }

        for context in URLContexts {
            let url = context.url

            // Handle URL Scheme: openmdict://lookup?word=xxx[&dictId=yyy&dictName=zzz]
            if url.scheme == AppIdentifiers.URLScheme.scheme {
                if url.host == "lookup",
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let word = components.queryItems?.first(where: { $0.name == "word" })?.value,
                   !word.isEmpty {
                    let dictId = components.queryItems?.first(where: { $0.name == "dictId" })?.value
                    let dictName = components.queryItems?.first(where: { $0.name == "dictName" })?.value
                    if let dictId, !dictId.isEmpty {
                        // Direct article open: jump straight to the entry
                        let item = WordDisplayItem(word: word, dictId: dictId, dictName: dictName ?? dictId)
                        splitVC.select(word: item)
                    } else {
                        // Fallback: search for the word
                        splitVC.focusSearchAndLookup(word: word)
                    }
                }
                return
            }

            // Handle .mdx file open (from Files, AirDrop, etc.)
            if url.pathExtension.lowercased() == "mdx" {
                splitVC.importMDXFile(url: url)
                return
            }
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Merge appearance mode from shared (Extension) vs standard (Settings.app).
        // Compare timestamps to determine which write is newer.
        let lastSyncTime = UserDefaults.standard.appearanceModeTimestamp
        let sharedStamp  = UserDefaults.shared.appearanceModeTimestamp
        let mode: AppearanceMode
        if sharedStamp > lastSyncTime {
            // Extension wrote after our last sync → shared wins
            mode = UserDefaults.shared.appearanceMode
            UserDefaults.standard.appearanceMode = mode
            UserDefaults.standard.appearanceModeTimestamp = sharedStamp
        } else {
            // Standard wins (Settings.app changed, or both are in sync)
            mode = UserDefaults.standard.appearanceMode
            if mode != UserDefaults.shared.appearanceMode {
                UserDefaults.shared.setAppearanceModeStamped(mode)
                UserDefaults.standard.appearanceModeTimestamp = UserDefaults.shared.appearanceModeTimestamp
            }
        }
        window?.overrideUserInterfaceStyle = mode.userInterfaceStyle

        // Auto-focus search bar when returning to foreground in compact mode
        if let splitVC = window?.rootViewController as? MainSplitViewController,
           splitVC.isCollapsed {
            splitVC.compactTabBarController.focusLookupSearchBarIfVisible()
        }

        // M15: re-arm article-embedding indexing on every foreground entry.
        // Two steps that MUST be sequenced (async because step 1 has to
        // settle before step 2 reads the dispatcher's runningDictId):
        //   1. Cancel any in-flight BGTask pass and wait for it to actually
        //      exit. Without this, a sync backfillIfEnabled below would see
        //      the dict as still "running" (the BGTask's runBackgroundPass
        //      hasn't released its runningDictId yet) and the enqueue
        //      would no-op, leaving the build on the CPU encoder.
        //   2. Backfill — re-enqueues every eligible dict; once the pass is
        //      gone the dispatcher routes the new jobs through the
        //      foreground queue (GPU profile). On iPhone 11 / A13 this is
        //      counterproductive (CPU is faster than GPU for this small
        //      model), so we'll likely want a device-tier gate later. On
        //      newer ANE/M-series this is the speedup we want.
        Task { @MainActor in
            await ArticleIndexBackgroundScheduler.shared.cancelCurrentPassAndWait()
            ArticleIndexCoordinator.shared.backfillIfEnabled()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // M15: the foreground encoder runs on the GPU, which the kernel
        // forbids once we're backgrounded — an in-flight build would abort
        // with kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted.
        // Stop it now (it flushes a valid partial); the BGTask scheduled
        // just below resumes it on the CPU.
        ArticleIndexDispatcher.shared.cancelCurrentBuild()
        // Ask the system to run article-embedding indexing in the
        // background. No-op if nothing's pending or the feature is off.
        ArticleIndexBackgroundScheduler.shared.scheduleIfNeeded()

        // Proactively save state when entering background.
        // This ensures state is captured even during rapid app switcher operations,
        // since stateRestorationActivity(for:) may not be called in time.
        guard let splitVC = window?.rootViewController as? MainSplitViewController else { return }
        scene.userActivity = splitVC.currentStateActivity()

        // Update Home Screen Quick Actions with the most-used groups.
        Self.updateQuickActions()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let obs = passiveResetObserver {
            NotificationCenter.default.removeObserver(obs)
            passiveResetObserver = nil
        }
    }

    /// Another device performed a nuclear reset — this device's data has
    /// been wiped by the passive reset flow.  Replace the UI with a fresh
    /// MainSplitViewController (empty state).
    private func handlePassiveReset() {
        guard let windowScene = window?.windowScene else { return }

        // Destroy all other scenes (multi-window)
        for session in UIApplication.shared.openSessions where session.scene !== windowScene {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }

        // Replace root view controller
        let freshSplitVC = MainSplitViewController(
            initialArticles: [],
            initialGroupId: "",
            initialLayoutMode: 0
        )
        window?.rootViewController = freshSplitVC
        debugLog("🔄 SceneDelegate: UI reset after passive nuclear reset")
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let handled = Self.handleQuickAction(shortcutItem, in: window)
        completionHandler(handled)
    }
}

// MARK: - Quick Actions

extension SceneDelegate {

    /// Shortcut item type prefix for group selection.
    private static let groupShortcutPrefix = "selectGroup:"

    /// Update `UIApplication.shared.shortcutItems` with top groups by lookup count.
    static func updateQuickActions() {
        let topGroups = LookupCountService.shared.topGroups(limit: 3)
        let groups = DictionaryService.shared.groups
        debugLog("🏠 Quick Actions: topGroups = \(topGroups.map { "\($0.groupId):\($0.count)" })")

        var items: [UIApplicationShortcutItem] = []
        for entry in topGroups {
            guard let group = groups.first(where: { $0.id == entry.groupId }) else { continue }
            let icon = group.isDefault
                ? UIApplicationShortcutIcon(systemImageName: "books.vertical")
                : UIApplicationShortcutIcon(systemImageName: "folder")
            let item = UIApplicationShortcutItem(
                type: "\(groupShortcutPrefix)\(group.id)",
                localizedTitle: group.name,
                localizedSubtitle: nil,
                icon: icon,
                userInfo: nil
            )
            items.append(item)
        }

        // iOS displays Quick Actions with array[0] closest to the app icon.
        // topGroups is already sorted by count descending, so the most-used
        // group naturally appears in the top position.
        UIApplication.shared.shortcutItems = items
    }

    /// Handle a Quick Action shortcut tap. Returns `true` if handled.
    @discardableResult
    static func handleQuickAction(_ shortcutItem: UIApplicationShortcutItem, in window: UIWindow?) -> Bool {
        guard shortcutItem.type.hasPrefix(groupShortcutPrefix) else { return false }
        let groupId = String(shortcutItem.type.dropFirst(groupShortcutPrefix.count))

        guard let splitVC = window?.rootViewController as? MainSplitViewController else { return false }
        splitVC.select(groupId: groupId)
        return true
    }
}

// MARK: - Multi-Window Helper

extension SceneDelegate {

    /// Request opening a new window for the specified article
    static func openNewWindow(for article: ArticleDisplayItem, sourceSession: UISceneSession? = nil) {
        let activity = article.userActivity

        // Add source session ID for tracking
        if let sessionId = sourceSession?.persistentIdentifier {
            activity.userInfo?["sourceSessionId"] = sessionId
        }

        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: activity,
            options: nil,
            errorHandler: { error in
                debugLog("Failed to open new window: \(error)")
            }
        )
    }
}
