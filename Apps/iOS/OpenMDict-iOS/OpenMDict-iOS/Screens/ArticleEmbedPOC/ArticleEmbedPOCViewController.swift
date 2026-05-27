//
//  ArticleEmbedPOCViewController.swift
//  OpenMDict-iOS  (M15 Phase 3.0.5 POC)
//
//  Single-screen debug UI for the article-embedding hardware POC. Shows
//  a monospaced log textview that gets populated as `ArticleEmbedPOCRunner`
//  pumps data through the CoreML pipeline, plus a top toolbar with:
//    - Run button (kicks off N-article benchmark; disabled while running)
//    - Sample count stepper (50 / 100 / 250 / 500 / 1000 / 2000)
//    - Share button (export full log via UIActivityViewController so we
//      can compare iPad 6 vs iPad Air 3 runs offline)
//
//  No L10n — POC strings are English-only and not user-facing past
//  the dev team.
//

import UIKit

@MainActor
final class ArticleEmbedPOCViewController: UIViewController {

    private let logTextView: UITextView = {
        let tv = UITextView()
        tv.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.backgroundColor = .systemBackground
        tv.textColor = .label
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private lazy var runButton: UIBarButtonItem = {
        UIBarButtonItem(
            title: "Run",
            style: .done,
            target: self,
            action: #selector(runTapped)
        )
    }()

    private lazy var shareButton: UIBarButtonItem = {
        UIBarButtonItem(
            barButtonSystemItem: .action,
            target: self,
            action: #selector(shareTapped)
        )
    }()

    private lazy var sampleCountControl: UISegmentedControl = {
        let seg = UISegmentedControl(items: ["50", "100", "250", "500", "1000", "2000"])
        seg.selectedSegmentIndex = 3  // 500 — moderate, ~30s on iPad Air 3 if all goes well
        return seg
    }()

    private var isRunning = false
    /// Mirrored copy of log lines for sharing. The textview is for display;
    /// this array is what we hand to UIActivityViewController.
    private var collectedLog: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Article Embed POC"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItems = [runButton, shareButton]
        navigationItem.titleView = sampleCountControl

        view.addSubview(logTextView)
        NSLayoutConstraint.activate([
            logTextView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            logTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])

        // Initial banner so user sees the screen is alive before they
        // tap Run.
        appendLog("POC ready. Tap Run to begin.")
        appendLog("Sample count: see segmented control above.")
        appendLog("")
        appendLog("Bundle resources expected:")
        appendLog("  - all-MiniLM-L6-v2.mlmodelc   (Xcode auto-compiles from .mlpackage)")
        appendLog("  - vocab.txt")
        appendLog("  - WordNet-EN.mdx")
        if ArticleEmbedPOCAssets.resolveFromBundle() == nil {
            appendLog("")
            appendLog("⚠️ Asset(s) MISSING from app bundle.")
            appendLog("   Check POC-Resources/ in the iOS app dir.")
            runButton.isEnabled = false
        }
    }

    // MARK: - Actions

    @objc private func runTapped() {
        guard !isRunning else { return }
        guard let assets = ArticleEmbedPOCAssets.resolveFromBundle() else {
            appendLog("❌ Assets not found in bundle — can't run")
            return
        }

        let sizes = [50, 100, 250, 500, 1000, 2000]
        let sampleCount = sizes[sampleCountControl.selectedSegmentIndex]

        isRunning = true
        runButton.isEnabled = false
        sampleCountControl.isEnabled = false
        // Clear previous run.
        logTextView.text = ""
        collectedLog.removeAll(keepingCapacity: true)

        Task { [weak self] in
            guard let self else { return }
            let runner = ArticleEmbedPOCRunner(logHandler: { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.appendLog(line)
                }
            })
            await runner.run(assets: assets, sampleCount: sampleCount)
            self.isRunning = false
            self.runButton.isEnabled = true
            self.sampleCountControl.isEnabled = true
        }
    }

    @objc private func shareTapped() {
        guard !collectedLog.isEmpty else { return }
        let full = collectedLog.joined(separator: "\n")
        let device = UIDevice.current
        let filename = "article-embed-poc-\(Self.modelIdentifier())-\(device.systemVersion)-\(Int(Date().timeIntervalSince1970)).log"
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try full.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            appendLog("❌ Could not write log file: \(error)")
            return
        }
        let av = UIActivityViewController(activityItems: [tmpURL], applicationActivities: nil)
        av.popoverPresentationController?.barButtonItem = shareButton
        present(av, animated: true)
    }

    private static func modelIdentifier() -> String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    // MARK: - Logging

    private func appendLog(_ line: String) {
        collectedLog.append(line)
        // Append to textview keeping cursor scrolled to bottom.
        let prefix = logTextView.text.isEmpty ? "" : "\n"
        logTextView.text.append(prefix + line)
        // Throttle scroll-to-bottom to avoid jitter when many lines arrive
        // in quick succession (e.g. first few seconds of the loop).
        let end = NSRange(location: (logTextView.text as NSString).length, length: 0)
        logTextView.scrollRangeToVisible(end)
    }
}
