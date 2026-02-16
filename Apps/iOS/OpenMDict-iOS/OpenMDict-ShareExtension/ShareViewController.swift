//
//  ShareViewController.swift
//  OpenMDict-ShareExtension
//
//  Receives shared text from other apps and opens the main app to look it up
//  via the openmdict://lookup?word=xxx URL scheme.
//

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let itemProvider = extensionItem.attachments?.first,
              itemProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        else {
            completeRequest()
            return
        }

        itemProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
            // Extract text on the callback queue (Sendable-safe: String is Sendable)
            let text = (item as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if !text.isEmpty,
                   let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "openmdict://lookup?word=\(encoded)") {
                    self?.openContainingApp(url)
                }
                self?.completeRequest()
            }
        }
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Open containing app via responder chain

    /// Traverses the responder chain to find UIApplication and open the URL.
    /// This is a well-known workaround used by Bluesky, Inkdrop, and other
    /// App Store apps. Apple's official NSExtensionContext.open(_:) only works
    /// for Today widgets, not Share Extensions.
    @discardableResult
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}
