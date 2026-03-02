//
//  Notifications.swift
//  OpenMDict-iOS
//
//  App-wide notification names
//

import Foundation

extension Notification.Name {
    /// Appearance mode changed (object: AppearanceMode)
    static let appearanceModeDidChange = Notification.Name("appearanceModeDidChange")

    /// Article moved to new scene via drag & drop
    /// userInfo: ["articleId": String, "sourceSessionId": String]
    static let articleMovedToNewScene = Notification.Name("articleMovedToNewScene")

    /// A passive nuclear reset completed on this device (triggered by
    /// another device's NuclearResetSignal).  Each scene should destroy
    /// extra windows and replace its rootViewController.
    static let passiveResetDidComplete = Notification.Name("passiveResetDidComplete")
}
