//
//  QuizModels.swift
//  OpenMDict-iOS
//
//  M14 MVP: Value types for the Word Relationship Quiz.
//  All types are nonisolated + Sendable for DiffableDataSource compatibility
//  under the project's `-default-isolation=MainActor` setting.
//

import Foundation

/// The ground-truth relationship between a candidate word and the target.
nonisolated enum WordRelationship: String, Hashable, Sendable {
    case synonym
    case antonym
    case similarSpelling
    case noise           // injected from user's other bookmarks, not from AI
}

/// One candidate word in a quiz, with its verified definition and correct answer.
nonisolated struct QuizCandidate: Hashable, Sendable {
    let word: String
    let correctRelationship: WordRelationship
    /// Authoritative definition from the user's installed dictionary.
    /// nil only if the word wasn't found in any loaded dict (shouldn't
    /// happen after verification, but defensive).
    let definition: String?
    /// Which dictionary the definition came from.
    let dictName: String?
}

/// A fully assembled quiz ready for UI presentation.
nonisolated struct WordRelationshipQuiz: Sendable {
    let targetWord: String
    /// Definition of the target word, for display at the top of the quiz.
    let targetDefinition: String
    let targetDictName: String
    /// Shuffled candidate words. Each has a `correctRelationship` answer key.
    let candidates: [QuizCandidate]
}

/// User's answer for a single candidate row.
nonisolated enum UserAnswer: Hashable, Sendable {
    case synonym
    case antonym
    case unrelated       // covers both similarSpelling and noise from user's POV
    case notAnswered
}

/// Result of grading one candidate row.
nonisolated struct GradedCandidate: Sendable {
    let candidate: QuizCandidate
    let userAnswer: UserAnswer
    let isCorrect: Bool
}
