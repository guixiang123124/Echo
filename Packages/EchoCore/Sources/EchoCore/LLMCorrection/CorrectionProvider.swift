import Foundation

/// Protocol for LLM-based text correction providers
public protocol CorrectionProvider: Sendable {
   /// Unique identifier for this correction provider
   var id: String { get }

   /// Human-readable display name
   var displayName: String { get }

   /// Whether this provider requires network connectivity
   var requiresNetwork: Bool { get }

   /// Whether this provider is currently available
   var isAvailable: Bool { get }

   /// Correct transcribed text using LLM
   /// - Parameters:
   ///   - rawText: The raw transcription from ASR
   ///   - context: Recent conversation context for better correction
   ///   - confidence: Per-word confidence scores from ASR
   ///   - options: Which correction types are allowed
   /// - Returns: Corrected text with details of changes made
   func correct(
       rawText: String,
       context: ConversationContext,
       confidence: [WordConfidence],
       options: CorrectionOptions
   ) async throws -> CorrectionResult
}

/// Errors that can occur during LLM correction
public enum CorrectionError: Error, Sendable, Equatable {
   case providerNotAvailable(String)
   case apiKeyMissing
   case apiError(String)
   case correctionFailed(String)
   case networkUnavailable
   case timeout
   case inputTooLong(maxLength: Int)

   public var localizedDescription: String {
       switch self {
       case .providerNotAvailable(let name):
           return "Correction provider '\(name)' is not available"
       case .apiKeyMissing:
           return "API key is not configured for this correction provider"
       case .apiError(let message):
           return "API error: \(message)"
       case .correctionFailed(let message):
           return "Correction failed: \(message)"
       case .networkUnavailable:
           return "Network connection is required but unavailable"
       case .timeout:
           return "Correction request timed out"
       case .inputTooLong(let maxLength):
           return "Input text exceeds maximum length of \(maxLength) characters"
       }
   }
}
