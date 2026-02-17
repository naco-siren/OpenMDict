//
//  SceneDelegate.swift
//  OpenMDict-iOS
//

import CoreSpotlight
import OpenMDictKit
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Block new windows during first-install onboarding.
        // If no dictionaries are imported, the primary scene runs the setup flow.
        // Any additional scene opened during that time is immediately destroyed.
        let isFirstInstall = !DictMetadataService.shared.hasAnyDictionaries
        let hasOtherScene = UIApplication.shared.connectedScenes
            .contains { $0.activationState != .unattached && $0 !== scene }

        if isFirstInstall && hasOtherScene {
            // Destroy this scene session on the next run loop tick
            // (can't destroy during willConnectTo: itself)
            DispatchQueue.main.async {
                UIApplication.shared.requestSceneSessionDestruction(
                    session, options: nil, errorHandler: { error in
                        print("⚠️ Failed to destroy duplicate scene during setup: \(error)")
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
        window.rootViewController = splitVC

        self.window = window
        window.makeKeyAndVisible()

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

            // Handle URL Scheme: openmdict://lookup?word=xxx
            if url.scheme == AppIdentifiers.URLScheme.scheme {
                if url.host == "lookup",
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let word = components.queryItems?.first(where: { $0.name == "word" })?.value,
                   !word.isEmpty {
                    splitVC.focusSearchAndLookup(word: word)
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
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Proactively save state when entering background.
        // This ensures state is captured even during rapid app switcher operations,
        // since stateRestorationActivity(for:) may not be called in time.
        guard let splitVC = window?.rootViewController as? MainSplitViewController else { return }
        scene.userActivity = splitVC.currentStateActivity()

        // Update Home Screen Quick Actions with the most-used groups.
        Self.updateQuickActions()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Scene released by system. Resources cleaned up automatically.
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
        print("🏠 Quick Actions: topGroups = \(topGroups.map { "\($0.groupId):\($0.count)" })")

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
                print("Failed to open new window: \(error)")
            }
        )
    }
}
