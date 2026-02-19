//
//  CloudKitSyncMonitor.swift
//  OpenMDict-iOS
//
//  Monitors NSPersistentCloudKitContainer sync events to detect when
//  the initial iCloud import completes (metadata records have arrived).
//
//  Used by CloudSyncProgressViewController during first-launch setup
//  to know when it is safe to start downloading dictionary files.
//
//  Detection strategy:
//    1. Listen for `.import` events via eventChangedNotification (iOS 14+).
//    2. An import event with a non-nil `endDate` and `succeeded == true`
//       means records have been imported.
//    3. Debounce 3 seconds — if no more import events arrive, consider
//       the initial sync complete.
//    4. Safety timeout: 120 seconds — if nothing completes by then,
//       fire anyway (the user can proceed with whatever data arrived).
//

import Combine
import CoreData
import Foundation

final class CloudKitSyncMonitor {

    // MARK: - Callback

    /// Fires once when the initial CloudKit → local import appears complete.
    var onInitialImportComplete: (() -> Void)?

    // MARK: - State

    private var observer: Any?
    private var debounceTimer: Timer?
    private var timeoutTimer: Timer?
    private var hasFired = false

    /// Tracks whether we have seen at least one successful import event.
    private var sawSuccessfulImport = false

    // MARK: - Constants

    /// After the last import event, wait this long before declaring "done".
    private let debounceInterval: TimeInterval = 3

    /// Maximum time to wait for initial sync, regardless of events.
    private let timeoutInterval: TimeInterval = 120

    // MARK: - Lifecycle

    init() {}

    /// Start monitoring.  Call once, after CoreDataStack has been set up
    /// with CloudKit enabled.
    func start() {
        guard observer == nil else { return }

        // Listen for CloudKit sync events
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract the event here (Notification is not Sendable)
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }

            let type = event.type
            let startDate = event.startDate
            let endDate = event.endDate
            let succeeded = event.succeeded
            let errorDesc = event.error?.localizedDescription

            MainActor.assumeIsolated {
                self?.handleEvent(type: type, startDate: startDate,
                                  endDate: endDate, succeeded: succeeded,
                                  errorDescription: errorDesc)
            }
        }

        // Safety timeout
        let timeout = timeoutInterval
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: timeoutInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                debugLog("☁️ CloudKitSyncMonitor: timeout (\(timeout)s) — firing completion")
                self?.fireCompletion()
            }
        }

        debugLog("☁️ CloudKitSyncMonitor: started (timeout=\(timeoutInterval)s)")
    }

    /// Stop monitoring and clean up.
    func stop() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
        debounceTimer?.invalidate()
        debounceTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    // MARK: - Event Handling

    /// Process a CloudKit sync event.  Values are pre-extracted from
    /// the Notification in the observer closure to avoid Sendable issues.
    private func handleEvent(
        type: NSPersistentCloudKitContainer.EventType,
        startDate: Date,
        endDate: Date?,
        succeeded: Bool,
        errorDescription: String?
    ) {
        guard !hasFired else { return }

        let typeStr: String
        switch type {
        case .setup:  typeStr = "setup"
        case .import: typeStr = "import"
        case .export: typeStr = "export"
        @unknown default: typeStr = "unknown"
        }

        let isComplete = endDate != nil

        debugLog("☁️ CloudKitSyncMonitor: event type=\(typeStr) "
                 + "started=\(startDate) "
                 + "ended=\(endDate?.description ?? "nil") "
                 + "succeeded=\(succeeded) "
                 + "error=\(errorDescription ?? "nil")")

        // We only care about completed import events
        guard type == .import, isComplete else { return }

        if succeeded {
            sawSuccessfulImport = true
        }

        // Debounce: reset timer on each import completion event.
        // If no more events arrive within `debounceInterval`, fire.
        debounceTimer?.invalidate()
        let interval = debounceInterval
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                debugLog("☁️ CloudKitSyncMonitor: debounce expired — firing completion")
                self?.fireCompletion()
            }
        }
    }

    private func fireCompletion() {
        guard !hasFired else { return }
        hasFired = true
        stop()
        onInitialImportComplete?()
    }
}
