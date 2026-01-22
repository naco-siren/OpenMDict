//
//  ZoomLevel.swift
//  OpenMDict-iOS
//
//  Zoom level management for article content
//

import Foundation

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
