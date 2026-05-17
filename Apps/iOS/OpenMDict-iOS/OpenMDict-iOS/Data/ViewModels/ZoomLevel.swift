//
//  ZoomLevel.swift
//  OpenMDict-iOS
//
//  Zoom level management for article content
//

import UIKit

struct ZoomLevel {
    /// Available zoom levels (percentage)
    static let levels = [50, 75, 100, 125, 150, 175, 200]
    
    /// Default zoom level
    static let defaultLevel = 100
    
    /// Current zoom level
    private(set) var current: Int
    
    init(_ level: Int = defaultLevel) {
        self.current = Self.levels.contains(level) ? level : Self.defaultLevel
    }
    
    /// Whether can zoom in further
    var canZoomIn: Bool {
        guard let index = Self.levels.firstIndex(of: current) else { return false }
        return index < Self.levels.count - 1
    }
    
    /// Whether can zoom out further
    var canZoomOut: Bool {
        guard let index = Self.levels.firstIndex(of: current) else { return false }
        return index > 0
    }
    
    /// Whether at default level
    var isDefault: Bool {
        current == Self.defaultLevel
    }
    
    /// Display string (e.g., "100%")
    var displayString: String {
        "\(current)%"
    }
    
    /// Zoom in one step
    mutating func zoomIn() {
        guard let index = Self.levels.firstIndex(of: current),
              index < Self.levels.count - 1 else { return }
        current = Self.levels[index + 1]
    }
    
    /// Zoom out one step
    mutating func zoomOut() {
        guard let index = Self.levels.firstIndex(of: current),
              index > 0 else { return }
        current = Self.levels[index - 1]
    }
    
    /// Reset to default
    mutating func reset() {
        current = Self.defaultLevel
    }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
    private static let rememberZoomLevelKey = "rememberZoomLevel"
    private static let persistedZoomLevelRegularKey = "persistedZoomLevelRegular"
    private static let persistedZoomLevelCompactKey = "persistedZoomLevelCompact"

    /// User preference: restore the last-used zoom level on app launch.
    /// Persisted via Settings.bundle.  Defaults to `true` when absent (fresh
    /// install before AppDelegate registers defaults).
    var rememberZoomLevel: Bool {
        get {
            if object(forKey: Self.rememberZoomLevelKey) == nil { return true }
            return bool(forKey: Self.rememberZoomLevelKey)
        }
        set { set(newValue, forKey: Self.rememberZoomLevelKey) }
    }

    /// Last zoom level set in the regular (multi-column) layout.
    /// Two independent keys (regular + compact) preserve the existing runtime
    /// invariant that the two DetailContainerVC instances have separate zoom
    /// state — a single shared key would have one trait clobber the other on
    /// every layout transition.
    var persistedZoomLevelRegular: Int {
        get {
            let stored = integer(forKey: Self.persistedZoomLevelRegularKey)
            return stored == 0 ? ZoomLevel.defaultLevel : stored
        }
        set { set(newValue, forKey: Self.persistedZoomLevelRegularKey) }
    }

    /// Last zoom level set in the compact (single-pane) layout — covers
    /// `CompactTabBarController.lookupDetailContainer` and the Action
    /// Extension, both of which present a narrow article view.
    var persistedZoomLevelCompact: Int {
        get {
            let stored = integer(forKey: Self.persistedZoomLevelCompactKey)
            return stored == 0 ? ZoomLevel.defaultLevel : stored
        }
        set { set(newValue, forKey: Self.persistedZoomLevelCompactKey) }
    }

    /// Zoom level to start a session with.  Returns the persisted value for
    /// the matching trait when remember is on; otherwise the default.  Snaps
    /// invalid stored values (e.g. removed from the discrete
    /// `ZoomLevel.levels` ladder) back to the default.
    func initialZoomLevel(compact: Bool) -> Int {
        guard rememberZoomLevel else { return ZoomLevel.defaultLevel }
        let stored = compact ? persistedZoomLevelCompact : persistedZoomLevelRegular
        return ZoomLevel.levels.contains(stored) ? stored : ZoomLevel.defaultLevel
    }

    /// Write the current zoom level iff the user has the remember toggle on.
    /// Callers can invoke this unconditionally after every zoom change; the
    /// guard lives here so the call sites stay one-liner.
    func persistZoomLevelIfEnabled(_ level: Int, compact: Bool) {
        guard rememberZoomLevel else { return }
        if compact {
            persistedZoomLevelCompact = level
        } else {
            persistedZoomLevelRegular = level
        }
    }
}

// MARK: - UI Factory

extension ZoomLevel {

    /// Pull-down menu with zoom-in, reset, zoom-out actions.
    /// On iOS 16+ uses `.small` preferredElementSize for inline icon buttons.
    func menu(
        onZoomIn: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onZoomOut: @escaping () -> Void
    ) -> UIMenu {
        let title = L10n.Detail.currentZoomLevel(displayString)

        let zoomInAction = UIAction(
            title: L10n.Detail.zoomIn,
            image: UIImage(systemName: "plus.magnifyingglass"),
            attributes: canZoomIn ? [] : .disabled
        ) { _ in onZoomIn() }

        let resetAction = UIAction(
            title: L10n.Detail.reset,
            image: UIImage(systemName: "1.magnifyingglass"),
            attributes: isDefault ? .disabled : []
        ) { _ in onReset() }

        let zoomOutAction = UIAction(
            title: L10n.Detail.zoomOut,
            image: UIImage(systemName: "minus.magnifyingglass"),
            attributes: canZoomOut ? [] : .disabled
        ) { _ in onZoomOut() }

        if #available(iOS 16.0, *) {
            return UIMenu(title: title, preferredElementSize: .small, children: [
                zoomOutAction, resetAction, zoomInAction
            ])
        } else {
            return UIMenu(title: title, children: [
                zoomInAction, resetAction, zoomOutAction
            ])
        }
    }
}
