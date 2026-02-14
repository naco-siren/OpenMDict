//
//  SceneDelegate.swift
//  OpenMDict-iOS
//

import UIKit
import CoreSpotlight

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Block new windows during first-install onboarding.
        // If manifest.json doesn't exist, the primary scene runs the setup flow.
        // Any additional scene opened during that time is immediately destroyed.
        let manifestURL = DictionaryStorageService.shared.manifestURL
        let isFirstInstall = !FileManager.default.fileExists(atPath: manifestURL.path)
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

        // Handle article handoff / drag-and-drop
        if let article = ArticleDisplayItem.from(userActivity: userActivity) {
            splitVC.showArticle(article, animated: true)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Reapply appearance from UserDefaults when returning from background.
        // On iOS 15 iPhone, view.window may be nil when UserDefaults.didChangeNotification
        // fires during the background→foreground transition, so DetailContainerVC's handler
        // silently fails. SceneDelegate.window is a strong reference that remains valid
        // throughout the scene lifecycle, making this a reliable fallback for all devices.
        let mode = UserDefaults.standard.appearanceMode
        window?.overrideUserInterfaceStyle = mode.userInterfaceStyle
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Proactively save state when entering background.
        // This ensures state is captured even during rapid app switcher operations,
        // since stateRestorationActivity(for:) may not be called in time.
        guard let splitVC = window?.rootViewController as? MainSplitViewController else { return }
        scene.userActivity = splitVC.currentStateActivity()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Scene released by system. Resources cleaned up automatically.
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
