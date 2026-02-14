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
        // Register Settings.bundle defaults
        UserDefaults.standard.register(defaults: [
            "appearanceMode": 1,    // .system
            "searchResultVolume": 2 // .normal (Default)
        ])
        // Initialize persistent store (Core Data)
        CoreDataStack.shared.setup()
        // Initialize dictionary service (loads Library dictionaries)
        DictionaryService.shared.setup()
        // Index dictionaries for Spotlight search
        SpotlightIndexingService.shared.indexAllDictionaries()
        return true
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
}
