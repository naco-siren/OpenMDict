//
//  ArticleLayoutMode.swift
//  OpenMDict-iOS
//

import UIKit

// MARK: - Layout Mode

enum ArticleLayoutMode: Int, CaseIterable {
    case columns = 0
    case grid = 1
    case list = 2
    
    var title: String {
        switch self {
        case .columns: return "Columns"
        case .grid: return "Grid"
        case .list: return "List"
        }
    }
    
    var icon: UIImage {
        switch self {
        case .columns: return UIImage(systemName: "rectangle.split.3x1")!
        case .grid: return UIImage(systemName: "square.grid.2x2")!
        case .list: return UIImage(systemName: "list.bullet")!
        }
    }
}
