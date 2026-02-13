//
//  DateGroupingHelper.swift
//  OpenMDict-iOS
//
//  Generic date-grouping utility. Shared by BookmarkListVC and
//  LookupHistoryListVC to bucket items into human-readable date
//  sections (Today, Yesterday, 2 Days Ago, …).
//
//  Thread-safety: all types and the free function are `nonisolated`,
//  safe to call from any isolation context.
//

import Foundation

// MARK: - Protocol

/// Conforming types can be grouped into date-based sections.
nonisolated protocol DateGroupable {
    var groupingDate: Date? { get }
}

// MARK: - Section Type

/// A single date section produced by `groupItemsByDate`.
nonisolated struct DateSection<Item> {
    let title: String
    var items: [Item]
}

// MARK: - Grouping Function

/// Groups items into date-based sections.
///
/// Returned sections are ordered from **newest to oldest** (Today first).
/// Items within each section preserve the order they had in the input array.
///
/// - Parameters:
///   - items: The items to group. Need *not* be pre-sorted.
///   - unknownSectionTitle: Title for a trailing section that collects
///     items whose `groupingDate` is `nil`. Pass `nil` to silently drop
///     those items.
/// - Returns: An array of ``DateSection`` values.
///
/// Categories (in order):
/// - Today
/// - Yesterday
/// - 2 Days Ago … 6 Days Ago
/// - 1 Week Ago, 2 Weeks Ago
/// - Earlier This Month
/// - Last Month
/// - \<Month YYYY\> (e.g. "September 2025")
/// - Last Year
/// - \<YYYY\> (e.g. "2023")
/// - Unknown (optional, always last)
nonisolated func groupItemsByDate<T: DateGroupable>(
    _ items: [T],
    unknownSectionTitle: String? = nil
) -> [DateSection<T>] {
    guard !items.isEmpty else { return [] }

    let calendar = Calendar.current
    let now = Date()
    let startOfToday = calendar.startOfDay(for: now)

    // Pre-compute boundary dates
    let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
    let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
    let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth)!
    let startOfThisYear = calendar.date(from: calendar.dateComponents([.year], from: now))!
    let startOfLastYear = calendar.date(byAdding: .year, value: -1, to: startOfThisYear)!

    // Month-year formatter for older months
    let monthYearFormatter = DateFormatter()
    monthYearFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

    // Ordered dict preserving insertion order
    var sections: [(key: String, items: [T])] = []
    var sectionMap: [String: Int] = [:]
    var unknownItems: [T] = []

    func appendToSection(key: String, item: T) {
        if let idx = sectionMap[key] {
            sections[idx].items.append(item)
        } else {
            sectionMap[key] = sections.count
            sections.append((key: key, items: [item]))
        }
    }

    for item in items {
        guard let date = item.groupingDate else {
            unknownItems.append(item)
            continue
        }

        let key: String
        if date >= startOfToday {
            key = L10n.HistorySection.today
        } else if date >= startOfYesterday {
            key = L10n.HistorySection.yesterday
        } else {
            let daysAgo = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date), to: startOfToday
            ).day ?? 0
            if daysAgo <= 6 {
                key = L10n.HistorySection.daysAgo(daysAgo)
            } else {
                let weeksAgo = calendar.dateComponents(
                    [.weekOfYear], from: calendar.startOfDay(for: date), to: startOfToday
                ).weekOfYear ?? 0
                if weeksAgo <= 2 && date >= startOfThisMonth {
                    key = L10n.HistorySection.weeksAgo(weeksAgo)
                } else if date >= startOfThisMonth {
                    key = L10n.HistorySection.earlierThisMonth
                } else if date >= startOfLastMonth {
                    key = L10n.HistorySection.lastMonth
                } else if date >= startOfThisYear {
                    key = monthYearFormatter.string(from: date)
                } else if date >= startOfLastYear {
                    key = L10n.HistorySection.lastYear
                } else {
                    let year = calendar.component(.year, from: date)
                    key = "\(year)"
                }
            }
        }

        appendToSection(key: key, item: item)
    }

    // Append "Unknown" section if needed
    if let unknownTitle = unknownSectionTitle, !unknownItems.isEmpty {
        sectionMap[unknownTitle] = sections.count
        sections.append((key: unknownTitle, items: unknownItems))
    }

    // Sort sections by their representative date (newest section first).
    // Use the first item's groupingDate in each section; .distantPast for "Unknown".
    let sorted = sections.sorted { a, b in
        let dateA = a.items.first?.groupingDate ?? .distantPast
        let dateB = b.items.first?.groupingDate ?? .distantPast
        return dateA > dateB
    }

    return sorted.map { DateSection(title: $0.key, items: $0.items) }
}
