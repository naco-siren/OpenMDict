//
//  AudioService.swift
//  OpenMDict-iOS
//
//  Service for playing dictionary audio (pronunciation)
//

import AVFoundation
import OpenMDictKit

@MainActor
final class AudioService {
    
    static let shared = AudioService()
    
    private var player: AVAudioPlayer?
    
    private init() {
        // Configure audio session for playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            print("⚠️ AudioService: Failed to configure audio session: \(error)")
        }
    }
    
    // MARK: - Playback
    
    /// Play audio from a sound:// URL
    /// - Parameters:
    ///   - url: The sound:// URL from WKWebView
    ///   - dictId: Dictionary ID to load audio from
    func play(url: URL, dictId: String) {
        guard let mdictURL = MDictURL(url), mdictURL.isAudio else {
            print("⚠️ AudioService: Invalid audio URL: \(url)")
            return
        }
        
        playResource(
            path: mdictURL.resourcePath,
            pathVariations: mdictURL.pathVariations,
            dictId: dictId
        )
    }
    
    /// Stop current playback
    func stop() {
        player?.stop()
        player = nil
    }
    
    // MARK: - Private
    
    private func playResource(path: String, pathVariations: [String], dictId: String) {
        stop()
        
        guard let dict = DictionaryService.shared.dict(id: dictId) else {
            print("⚠️ AudioService: Dictionary not found: \(dictId)")
            return
        }
        
        guard let audioData = loadAudioData(pathVariations: pathVariations, dict: dict) else {
            print("⚠️ AudioService: Audio not found: \(path) in \(dictId)")
            return
        }
        
        do {
            player = try AVAudioPlayer(data: audioData)
            player?.prepareToPlay()
            player?.play()
            print("🔊 AudioService: Playing \(path)")
        } catch {
            print("⚠️ AudioService: Playback failed: \(error)")
        }
    }
    
    private func loadAudioData(pathVariations: [String], dict: MDict) -> Data? {
        // 1. Try MDD with all path variations
        for path in pathVariations {
            if let data = dict.resource(for: path) {
                return data
            }
        }
        
        guard let firstPath = pathVariations.first else { return nil }
        
        // 2. Fall back to dictionary directory
        if let dictPath = dict.metadata?.path {
            let dictDir = (dictPath as NSString).deletingLastPathComponent
            let filePath = (dictDir as NSString).appendingPathComponent(firstPath)
            
            if FileManager.default.fileExists(atPath: filePath) {
                return try? Data(contentsOf: URL(fileURLWithPath: filePath))
            }
        }
        
        // 3. Try Bundle.main (for bundled dictionaries)
        let baseName = (firstPath as NSString).deletingPathExtension
        let ext = (firstPath as NSString).pathExtension
        
        if let bundleURL = Bundle.main.url(forResource: baseName, withExtension: ext) {
            return try? Data(contentsOf: bundleURL)
        }
        
        return nil
    }
}
