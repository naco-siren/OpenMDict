//
//  MorphologyQuizModels.swift
//  OpenMDict-iOS
//
//  M14: Value types for the Among wUrdS morphology quiz.
//  All types are nonisolated + Sendable for DiffableDataSource compatibility
//  under the project's `-default-isolation=MainActor` setting.
//

import UIKit

/// A fully assembled morphology quiz ready for UI presentation.
nonisolated struct MorphologyQuiz: Sendable {
    let targetWord: String
    let targetDictId: String
    let targetDictName: String
    /// The root morpheme shared by crewmate words (e.g. "ple" from Latin plere).
    let root: String
    /// Prefix and its meaning, if any (e.g. "com- (together)").
    let prefix: String?
    /// Suffix and its meaning, if any (e.g. "-tion (noun form)").
    let suffix: String?
    /// All candidates shuffled for display. Contains both crewmates and imposters.
    let allCandidates: [MorphologyCandidate]
    /// How many imposters are hiding among the candidates.
    let imposterCount: Int

    /// Convenience: just the crewmates.
    var crewmates: [MorphologyCandidate] {
        allCandidates.filter { !$0.isImposter }
    }

    /// Convenience: just the imposters.
    var imposters: [MorphologyCandidate] {
        allCandidates.filter { $0.isImposter }
    }
}

/// One candidate word in a morphology quiz.
nonisolated struct MorphologyCandidate: Hashable, Sendable {
    let word: String
    /// Ground truth: true if this word is an imposter (false relative).
    let isImposter: Bool
    /// Definition from the user's installed dictionary.
    let definition: String?
    /// Which dictionary the definition came from.
    let dictName: String?
    /// Index into the crew color palette (0..<10).
    let crewColorIndex: Int

    /// 10 distinct crew colors inspired by Among Us.
    static let crewColorPalette: [UIColor] = [
        UIColor(red: 0.77, green: 0.12, blue: 0.15, alpha: 1),  // Red
        UIColor(red: 0.11, green: 0.28, blue: 0.80, alpha: 1),  // Blue
        UIColor(red: 0.07, green: 0.50, blue: 0.17, alpha: 1),  // Green
        UIColor(red: 0.95, green: 0.85, blue: 0.08, alpha: 1),  // Yellow
        UIColor(red: 0.22, green: 0.80, blue: 0.80, alpha: 1),  // Cyan
        UIColor(red: 0.93, green: 0.35, blue: 0.65, alpha: 1),  // Pink
        UIColor(red: 0.93, green: 0.55, blue: 0.13, alpha: 1),  // Orange
        UIColor(red: 0.55, green: 0.22, blue: 0.75, alpha: 1),  // Purple
        UIColor(red: 0.45, green: 0.80, blue: 0.10, alpha: 1),  // Lime
        UIColor(red: 0.45, green: 0.28, blue: 0.15, alpha: 1),  // Brown
    ]

    /// Resolved crew color for this candidate.
    var crewColor: UIColor {
        Self.crewColorPalette[crewColorIndex % Self.crewColorPalette.count]
    }
}

/// Result of grading one candidate in a morphology quiz.
nonisolated struct MorphologyGradedCandidate: Sendable {
    let candidate: MorphologyCandidate
    /// Whether the user marked this word as an imposter.
    let userMarkedImposter: Bool
    /// True if user's judgment matches ground truth.
    let isCorrect: Bool
}
