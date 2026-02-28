import Foundation

/// Result from LLM error correction
public struct CorrectionResult: Sendable, Equatable {
   public let originalText: String
   public let correctedText: String
   public let corrections: [Correction]
   public let wasModified: Bool

   public init(
       originalText: String,
       correctedText: String,
       corrections: [Correction] = []
   ) {
       self.originalText = originalText
       self.correctedText = correctedText
       self.corrections = corrections
       self.wasModified = originalText != correctedText
   }

   /// Create a pass-through result with no corrections
   public static func unchanged(_ text: String) -> CorrectionResult {
       CorrectionResult(originalText: text, correctedText: text)
   }
}

/// A single correction applied by the LLM
public struct Correction: Sendable, Equatable {
   public let original: String
   public let replacement: String
   public let type: CorrectionType
   public let confidence: Double

   public init(
       original: String,
       replacement: String,
       type: CorrectionType,
       confidence: Double = 1.0
   ) {
       self.original = original
       self.replacement = replacement
       self.type = type
       self.confidence = confidence
   }
}

/// Types of corrections the LLM can make
public enum CorrectionType: String, Sendable, Equatable, CaseIterable {
   case homophone       // 同音字 correction (e.g., 在/再, 的/得/地)
   case punctuation     // Missing or wrong punctuation
   case grammar         // Grammar correction
   case segmentation    // Sentence boundary / segmentation
   case spelling        // Spelling error
   case contextual      // Context-aware correction
}
