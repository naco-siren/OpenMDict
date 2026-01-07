//
//  SceneDelegate.swift
//  OpenMDict-iOS
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        
        let window = UIWindow(windowScene: windowScene)
        
        // Check if there's a userActivity specifying an article to open
        let initialArticle: ArticleItem?
        if let activity = connectionOptions.userActivities.first ?? session.stateRestorationActivity {
            initialArticle = ArticleItem.from(userActivity: activity)
        } else {
            initialArticle = nil
        }
        
        // Create main interface
        let splitVC = MainSplitViewController(initialArticle: initialArticle)
        window.rootViewController = splitVC
        
        self.window = window
        window.makeKeyAndVisible()
        
        // Set window title (shown in App Switcher)
        if let article = initialArticle {
            windowScene.title = article.title
        } else {
            windowScene.title = "OpenMDict"
        }
    }
    
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let splitVC = window?.rootViewController as? MainSplitViewController else {
            return nil
        }
        return splitVC.currentStateActivity()
    }
    
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let splitVC = window?.rootViewController as? MainSplitViewController,
              let article = ArticleItem.from(userActivity: userActivity) else {
            return
        }
        splitVC.showArticle(article, animated: true)
    }
}

// MARK: - Multi-Window Helper

extension SceneDelegate {
    
    /// Request opening a new window for the specified article
    static func openNewWindow(for article: ArticleItem) {
        let activity = article.userActivity
        
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
